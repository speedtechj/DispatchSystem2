<?php

namespace App\Filament\Pages;

use App\Models\Container;
use App\Models\Consolidator;
use App\Support\Connectors\ManualSend;
use App\Support\Connectors\Recorder;
use App\Support\Connectors\TheirTracking;
use BackedEnum;
use Filament\Pages\Page;
use Filament\Support\Icons\Heroicon;
use Illuminate\Support\Facades\Auth;
use Livewire\Attributes\Url;

/**
 * Part 47c · Consolidator tracking (board 83): see a box the way the consolidator's
 * tracking page shows it, without opening their website, next to what we sent.
 * Read only. A container shows their newest status for every box at once.
 */
class ConsolidatorTracking extends Page
{
    protected string $view = 'filament.pages.consolidator-tracking';

    protected static string|BackedEnum|null $navigationIcon = Heroicon::OutlinedEye;

    protected static ?string $navigationLabel = 'Consolidator tracking';

    protected static ?string $title = 'Consolidator tracking';

    protected static ?string $slug = 'consolidator-tracking';

    protected static ?int $navigationSort = 9;

    #[Url]
    public string $box = '';

    #[Url]
    public string $container = '';

    public ?array $theirs = null;

    public ?array $cont = null;

    public ?string $open = null;

    public ?string $notice = null;

    public static function canAccess(): bool
    {
        return Recorder::ready() && (bool) Auth::user() && (Auth::user()->is_admin || Auth::user()->hasRole('super_admin'));
    }

    public static function shouldRegisterNavigation(): bool
    {
        return static::canAccess() && Recorder::links() !== [];
    }

    public function getSubheading(): ?string
    {
        return 'Read from the consolidator\'s connector (read only, signed): their statuses too (ETA Manila, customs, vessel) and who updated each one, next to ours. No sender or receiver details travel.';
    }

    public function mount(): void
    {
        if ($this->box !== '') {
            $this->findBox();
        } elseif ($this->container !== '') {
            $this->findContainer();
        }
    }

    public function findBox(bool $fresh = false): void
    {
        $this->notice = null;
        $this->cont = null;
        $inv = ManualSend::findBox($this->box);
        if (! $inv) {
            $this->theirs = null;
            $this->notice = 'No box '.$this->box.'.';

            return;
        }
        $this->box = (string) $inv->invoice;
        $this->theirs = ['box' => $inv->invoice, 'consolidator' => Consolidator::nameForCode($inv->location_code) ?? $inv->location_code,
            'code' => (string) $inv->location_code, 'receiver' => \Illuminate\Support\Str::title((string) $inv->receiver_city)]
            + TheirTracking::box($inv, $fresh) + ['ours' => TheirTracking::ours($inv)];
    }

    public function refresh(): void
    {
        $this->findBox(true);
    }

    public function findContainer(): void
    {
        $this->notice = null;
        $this->theirs = null;
        $this->open = null;
        $no = preg_replace('/\s+/', '', $this->container);
        $c = Container::query()->whereRaw("REPLACE(container_no, ' ', '') = ?", [$no])->first()
            ?? Container::query()->whereRaw("REPLACE(container_no, ' ', '') like ?", ['%'.$no.'%'])->first();
        if (! $c) {
            $this->cont = null;
            $this->notice = 'No container '.$this->container.'.';

            return;
        }
        $this->container = (string) $c->container_no;
        $this->cont = ['no' => $c->container_no] + TheirTracking::container($c);
    }

    public function openGroup(string $key): void
    {
        $this->open = $this->open === $key ? null : $key;
    }

    public function showBox(string $no): void
    {
        $this->box = $no;
        $this->findBox();
    }
}
