<?php

namespace App\Filament\Shared\Addresses;

use App\Models\Container;
use App\Models\Invoice;
use App\Models\Maps\BarangayFill;
use App\Models\Maps\GeoPlace;
use App\Support\Maps\Barangays;
use App\Support\Maps\TripSorter;
use App\Support\Tracking\Tracker;
use Filament\Facades\Filament;
use Filament\Notifications\Notification;
use Filament\Pages\Page;
use Illuminate\Contracts\Support\Htmlable;
use Illuminate\Database\Eloquent\Builder;
use Illuminate\Support\Facades\Auth;
use Illuminate\Support\Facades\Cache;
use Illuminate\Support\Str;
use Livewire\Attributes\Url;

/** Boxes with no barangay: what the system filled in, and the unsure ones the office checks. */
class AddressesToCheckPage extends Page
{
    protected string $view = 'filament.addresses.check';

    protected static ?string $slug = 'addresses-to-check';

    protected static string|\BackedEnum|null $navigationIcon = 'heroicon-o-map-pin';

    protected static ?string $title = 'Addresses to check';

    #[Url]
    public string $show = 'check';

    #[Url]
    public ?int $container = null;

    #[Url(as: 'box')]
    public ?int $boxId = null;

    public int $limit = 40;

    public string $chosen = '';

    public string $search = '';

    public bool $alsoSame = true;

    public static function canAccess(): bool
    {
        return Barangays::ready() && Tracker::hubFor(Auth::user(), Filament::getCurrentPanel()?->getId()) !== false;
    }

    public static function getNavigationBadge(): ?string
    {
        $panel = Filament::getCurrentPanel()?->getId();
        $user = Auth::user();
        if (! $user || ! Barangays::ready()) {
            return null;
        }
        $n = Cache::remember("menu:{$panel}:{$user->id}:addresses", 60, fn () => Barangays::scope(BarangayFill::query(), $user, $panel)->where('status', 'check')->count());

        return $n ? (string) $n : null;
    }

    public function getHeading(): string|Htmlable
    {
        return '';
    }

    protected function base(): Builder
    {
        return Barangays::scope(BarangayFill::query(), Auth::user(), Filament::getCurrentPanel()?->getId())
            ->when($this->container, fn ($q) => $q->where('container_id', $this->container));
    }

    public function mount(): void
    {
        Barangays::scan(1000);
        if ($this->boxId) {
            $this->openBox($this->boxId);
        }
    }

    public function setShow(string $s): void
    {
        $this->show = in_array($s, ['check', 'sure', 'none', 'all'], true) ? $s : 'check';
        $this->limit = 40;
    }

    public function fillNow(): void
    {
        $ids = (clone $this->base())->where('status', 'pending')->limit(40)->pluck('id');
        $r = Barangays::work(0, 20, BarangayFill::with('invoice')->whereIn('id', $ids)->get());
        Notification::make()->title($r['done'].' '.Str::plural('box', $r['done']).' done'.($r['ai'] ? ' · the AI read '.$r['ai'] : ''))->success()->send();
        $this->forgetBadge();
    }

    protected function fillRow(int $id): ?BarangayFill
    {
        return (clone $this->base())->with('invoice')->find($id);
    }

    /** ✓ OK: the AI's barangay is right. */
    public function ok(int $id): void
    {
        $f = $this->fillRow($id);
        if ($f && $f->barangay) {
            Barangays::confirm($f, $f->barangay, Auth::user(), true);
            $this->forgetBadge();
        }
    }

    public function openBox(int $id): void
    {
        $f = $this->fillRow($id);
        if (! $f) {
            $this->boxId = null;

            return;
        }
        $this->boxId = $id;
        $this->chosen = $f->barangay ?? (($f->candidates[0]['name'] ?? '') ?: '');
        $this->search = '';
    }

    public function closeBox(): void
    {
        $this->boxId = null;
    }

    public function pick(string $name): void
    {
        $this->chosen = $name;
        $this->search = '';
    }

    public function useChosen(): void
    {
        $f = $this->boxId ? $this->fillRow($this->boxId) : null;
        $name = trim($this->search) !== '' ? Str::title(Str::squish($this->search)) : $this->chosen;
        if (! $f || $name === '') {
            return;
        }
        $known = Barangays::known($f->invoice?->receiver_city);
        $name = Barangays::match($name, $known) ?? $name;
        $n = Barangays::confirm($f, $name, Auth::user(), $this->alsoSame);
        Notification::make()->title($name.' saved'.($n > 1 ? ' for '.$n.' boxes' : '').' · remembered for next time')->success()->send();
        $this->boxId = null;
        $this->forgetBadge();
    }

    protected function forgetBadge(): void
    {
        Cache::forget('menu:'.Filament::getCurrentPanel()?->getId().':'.Auth::id().':addresses');
    }

    /** "52190 · 1 of 3" */
    public static function boxLabel(Invoice $i): string
    {
        $set = $i->set_key ? Invoice::where('container_id', $i->container_id)->where('set_key', $i->set_key)->orderBy('id')->pluck('id') : collect([$i->id]);

        return $i->invoice.($set->count() > 1 ? ' · '.($set->search($i->id) + 1).' of '.$set->count() : '');
    }

    protected function getViewData(): array
    {
        $counts = (clone $this->base())->selectRaw('status, source, count(*) as n')->groupBy('status', 'source')->get();
        $by = fn ($st) => (int) $counts->whereIn('status', (array) $st)->sum('n');
        $src = fn ($s) => (int) $counts->whereIn('status', ['used', 'checked'])->where('source', $s)->sum('n');
        $q = (clone $this->base())->with('invoice');
        $q = match ($this->show) {
            'check' => $q->where('status', 'check'),
            'sure' => $q->whereIn('status', ['used', 'checked']),
            'none' => $q->where('status', 'none'),
            default => $q->where('status', '!=', 'pending'),
        };
        $rows = $q->orderByRaw("case status when 'check' then 0 when 'none' then 2 else 1 end")->orderBy('id')->limit($this->limit + 1)->get();
        $box = $this->boxId ? $this->fillRow($this->boxId) : null;
        $boxData = null;
        if ($box && $box->invoice) {
            $i = $box->invoice;
            $place = GeoPlace::where('key', GeoPlace::keyFor(Str::limit(Str::squish(TripSorter::address($i)), 590, '')))->first();
            $others = BarangayFill::where('id', '!=', $box->id)->whereHas('invoice', fn ($x) => $x->where('is_delivered', false)->where('set_key', $i->set_key))->count();
            $cands = collect($box->candidates ?? []);
            if ($box->barangay && ! $cands->contains('name', $box->barangay)) {
                $cands->prepend(['name' => $box->barangay, 'pct' => $box->confidence, 'why' => $box->clue]);
            }
            $boxData = [
                'f' => $box, 'i' => $i, 'label' => static::boxLabel($i),
                'marked' => static::marked((string) $i->receiver_address, $box->clues ?? []),
                'cands' => $cands->take(3)->values(), 'known' => Barangays::known($i->receiver_city),
                'place' => $place?->hasPin() ? $place : null, 'others' => $others,
                'first' => Str::title(Str::before(Str::squish((string) $i->receiver_name), ' ') ?: 'this receiver'),
            ];
        }

        return [
            'tiles' => [
                ['Boxes with no barangay', $by(['used', 'checked', 'check', 'none', 'pending']), $by('pending') ? $by('pending').' still waiting to be filled in' : 'in this list', false],
                ['Filled in, sure', $by(['used', 'checked']), 'same receiver '.$src('same').' · map '.$src('map').' · driver '.$src('driver').($src('office') + $src('ai') ? ' · other '.($src('office') + $src('ai')) : ''), false],
                ['AI not sure', $by('check'), 'one click each', true],
                ['No clues', $by('none'), 'stay in the city group', false],
            ],
            'chips' => ['check' => ['To check', $by('check')], 'sure' => ['Filled in', $by(['used', 'checked'])], 'none' => ['No clues', $by('none')], 'all' => ['All', $by(['used', 'checked', 'check', 'none'])]],
            'pending' => $by('pending'),
            'rows' => $rows->take($this->limit), 'more' => $rows->count() > $this->limit,
            'containers' => Container::whereIn('id', (clone $this->base())->distinct()->pluck('container_id')->filter())->latest('id')->limit(30)->get(),
            'box' => $boxData,
            'level' => Barangays::level(),
        ];
    }

    /** The address with the AI's clue words marked: [[text, kind|null], ...] */
    public static function marked(string $address, array $clues): array
    {
        $parts = [[$address, null]];
        foreach ($clues as $c) {
            $t = (string) ($c['text'] ?? '');
            if ($t === '') {
                continue;
            }
            $next = [];
            foreach ($parts as [$text, $kind]) {
                $pos = $kind === null ? stripos($text, $t) : false;
                if ($pos === false) {
                    $next[] = [$text, $kind];

                    continue;
                }
                $next[] = [substr($text, 0, $pos), null];
                $next[] = [substr($text, $pos, strlen($t)), (string) ($c['kind'] ?? 'clue')];
                $next[] = [substr($text, $pos + strlen($t)), null];
            }
            $parts = $next;
        }

        return array_values(array_filter($parts, fn ($p) => $p[0] !== ''));
    }
}
