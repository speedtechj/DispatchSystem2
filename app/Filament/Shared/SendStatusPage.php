<?php

namespace App\Filament\Shared;

use App\Models\Invoice;
use App\Models\Connectors\ConnectorMapping;
use App\Support\Connectors\Codes;
use App\Support\Connectors\ManualSend;
use App\Support\Connectors\Recorder;
use BackedEnum;
use Filament\Facades\Filament;
use Filament\Notifications\Notification;
use Filament\Pages\Page;
use Filament\Support\Icons\Heroicon;
use Illuminate\Support\Carbon;
use Illuminate\Support\Facades\Auth;

/**
 * Part 47b · Send status manually (board 80). The same page in Admin, Warehouse and
 * the partner hub (Company); each only sees its own boxes. It goes through the
 * Outbox and its 10-minute hold, so it can still be cancelled there.
 */
abstract class SendStatusPage extends Page
{
    protected string $view = 'filament.shared.send-status';

    protected static string|BackedEnum|null $navigationIcon = Heroicon::OutlinedPaperAirplane;

    protected static ?string $navigationLabel = 'Send status manually';

    protected static ?string $title = 'Send status manually';

    protected static ?string $slug = 'send-status';

    /** @var list<int> invoice ids */
    public array $boxes = [];

    public string $scan = '';

    public string $from = '';

    public string $fromKind = 'trip';

    public ?string $notice = null;

    public string $code = 'ds.delivered';

    public string $place = '';

    public string $at = '';

    public string $note = '';

    public string $reason = '';

    public ?string $done = null;

    public static function canAccess(): bool
    {
        return ManualSend::allowed(Auth::user());
    }

    public function getSubheading(): ?string
    {
        return 'For a missed scan (broken phone, no signal, forgot). The status list comes from each consolidator\'s mapping, so it matches their CMS. It goes through the Outbox and its 10-minute hold, so it can still be cancelled.';
    }

    public function mount(): void
    {
        $this->at = now()->format('Y-m-d\TH:i');
    }

    protected function panel(): string
    {
        return Filament::getCurrentPanel()?->getId() ?? 'admin';
    }

    protected function scopeOf(): ?array
    {
        return ManualSend::scope(Auth::user(), $this->panel());
    }

    public function addScan(): void
    {
        $this->notice = null;
        $this->done = null;
        foreach (preg_split('/[\s,;]+/', trim($this->scan)) as $no) {
            if ($no === '') {
                continue;
            }
            $inv = ManualSend::findBox($no);
            if (! $inv) {
                $this->notice = "$no not added: no such box.";

                continue;
            }
            if (ManualSend::allowedIds([$inv->id], $this->scopeOf())->isEmpty()) {
                $this->notice = "$no not added: it is not in ".ManualSend::scopeName($this->scopeOf())."'s boxes.";

                continue;
            }
            $this->boxes = array_values(array_unique([...$this->boxes, (int) $inv->id]));
        }
        $this->boxes = array_slice($this->boxes, 0, ManualSend::MAX_BOXES);
        $this->scan = '';
    }

    public function addFrom(): void
    {
        $this->notice = null;
        $no = trim($this->from);
        if ($no === '') {
            return;
        }
        $ids = $this->fromKind === 'container' ? ManualSend::containerBoxes($no) : ManualSend::tripBoxes($no);
        $ok = ManualSend::allowedIds($ids, $this->scopeOf());
        if ($ids->isEmpty()) {
            $this->notice = ($this->fromKind === 'container' ? 'Container ' : 'Trip ').$no.' not found.';

            return;
        }
        $this->boxes = array_slice(array_values(array_unique([...$this->boxes, ...$ok->all()])), 0, ManualSend::MAX_BOXES);
        $this->notice = $ok->count().' boxes added'.($ids->count() > $ok->count() ? ' ('.($ids->count() - $ok->count()).' are not yours and were left out)' : '').'.';
        $this->from = '';
    }

    public function removeBox(int $id): void
    {
        $this->boxes = array_values(array_diff($this->boxes, [$id]));
    }

    public function clearBoxes(): void
    {
        $this->boxes = [];
        $this->done = null;
    }

    public function pickCode(string $code): void
    {
        if (isset(Codes::ALL[$code]) && $code !== 'ds.correction') {
            $this->code = $code;
            $this->place = '';
        }
    }

    public function send(): void
    {
        $this->validate([
            'boxes' => ['required', 'array', 'min:1'],
            'code' => ['required', 'string'],
            'at' => ['required', 'date', 'before_or_equal:'.now()->addMinutes(5)->format('Y-m-d H:i')],
            'note' => ['nullable', 'string', 'max:300'],
            'reason' => ['required', 'string', 'min:4', 'max:200'],
        ], ['at.before_or_equal' => 'It cannot be in the future.'], ['reason' => 'why manual', 'at' => 'when it really happened']);
        if (! isset(Codes::ALL[$this->code]) || $this->code === 'ds.correction') {
            return;
        }
        $ids = ManualSend::allowedIds($this->boxes, $this->scopeOf())->all();
        $r = ManualSend::send($ids, $this->code, $this->place ?: null, Carbon::parse($this->at), $this->note ?: null, trim($this->reason), Auth::user());
        $this->done = $r['made'] ? "{$r['made']} statuses put in the Outbox"
            .($r['until'] ? ' · 10-minute hold (until '.$r['until']->format('g:i A').') · cancel there if it was wrong' : ' · they go now')
            .($r['skipped'] ? " · {$r['skipped']} left out (their consolidator has no connector)" : '').'.' : null;
        $r['made']
            ? Notification::make()->title($this->done)->success()->send()
            : Notification::make()->title('Nothing sent: none of these boxes has a connected consolidator')->warning()->send();
        if ($r['made']) {
            $this->boxes = [];
            $this->note = '';
            $this->reason = '';
        }
    }

    protected function getViewData(): array
    {
        $scope = $this->scopeOf();
        $rows = Invoice::query()->whereIn('id', $this->boxes)->get(['id', 'invoice', 'location_code', 'receiver_name', 'receiver_city'])->keyBy('id');
        $last = ManualSend::lastSent($this->boxes);
        $groups = ManualSend::groups($this->boxes);
        // their status for the chosen event, per consolidator (from the mapping)
        $links = Recorder::links();
        $key = Codes::key($this->code, $this->place ?: null);
        $maps = ConnectorMapping::query()->whereIn('connector_link_id', array_values($links))->whereIn('key', array_unique([$key, $this->code]))->get()
            ->groupBy('connector_link_id');
        $theirFor = function (string $loc) use ($links, $maps, $key) {
            $m = $maps->get($links[$loc] ?? 0);
            $row = $m?->firstWhere('key', $key) ?? $m?->firstWhere('key', $this->code);

            return $row ? ($row->skip ? 'not sent (Don\'t send)' : '#'.$row->trackstatus_id.' '.$row->status_name) : 'needs mapping (waits at the connector)';
        };
        $kind = Codes::ALL[$this->code][2] ?? null;

        return [
            'scopeName' => ManualSend::scopeName($scope),
            'panelName' => match ($this->panel()) { 'warehouse' => 'Warehouse', 'company' => 'Partner hub', default => 'Admin' },
            'list' => collect($this->boxes)->map(fn ($id) => $rows->get($id))->filter()->map(fn ($i) => [
                'id' => $i->id, 'no' => $i->invoice, 'loc' => (string) $i->location_code,
                'who' => \Illuminate\Support\Str::title(trim($i->receiver_name.' · '.$i->receiver_city, ' ·')), 'last' => $last[$i->id] ?? 'nothing sent yet',
            ])->groupBy('loc'),
            'groups' => collect($groups)->map(fn ($g, $loc) => $g + ['their' => $g['connected'] ? $theirFor($loc) : null]),
            'codes' => collect(Codes::ALL)->except('ds.correction')->map(fn ($c, $k) => ['k' => $k, 't' => $c[0], 'g' => $c[1]])->groupBy('g'),
            'places' => Codes::places($kind),
            'total' => collect($groups)->where('connected', true)->sum('n'),
            'confirm' => count($this->boxes) > ManualSend::CONFIRM_OVER,
        ];
    }
}
