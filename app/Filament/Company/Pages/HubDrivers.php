<?php

namespace App\Filament\Company\Pages;

use App\Support\HubDesk;
use BackedEnum;
use Filament\Pages\Page;
use Filament\Support\Icons\Heroicon;
use Illuminate\Support\Facades\Auth;
use Livewire\Attributes\Url;

/** Drivers leaderboard: delivered, first-try success, failed, most common reason. */
class HubDrivers extends Page
{
    protected string $view = 'filament.company.pages.hub-drivers';

    protected static string|BackedEnum|null $navigationIcon = Heroicon::OutlinedTrophy;

    protected static ?string $navigationLabel = 'Drivers';

    protected static ?string $title = 'Drivers';

    protected static ?string $slug = 'driver-leaderboard'; // /company/drivers is the Company Crew list

    protected static ?int $navigationSort = 4;

    public const PERIODS = [7 => 'This week', 30 => '30 days', 365 => 'This year'];

    #[Url]
    public int $days = 30;

    public function getSubheading(): ?string
    {
        return 'Who delivered what in the last '.($this->days === 365 ? 'year' : $this->days.' days').'.';
    }

    protected function getViewData(): array
    {
        $days = array_key_exists($this->days, self::PERIODS) ? $this->days : 30;
        $desk = new HubDesk((int) Auth::user()->logistichub_id);
        $drivers = $desk->drivers($days);
        $delivered = $drivers->sum('delivered');
        $withRate = $drivers->filter(fn ($d) => $d['firstTry'] !== null);
        $best = $drivers->first(fn ($d) => $d['delivered'] > 0);

        return [
            'drivers' => $drivers,
            'cards' => [
                ['Drivers', $drivers->count(), $drivers->whereNotNull('truck')->count().' with a truck'],
                ['Delivered', number_format($delivered), 'by your drivers'],
                ['First-try success', $withRate->isEmpty() ? '—' : round($withRate->avg('firstTry')).'%', 'Delivered on the first visit'],
                ['Best', $best ? strtok($best['name'], ' ') : '—', $best ? number_format($best['delivered']).' '.str('box')->plural($best['delivered']).($best['firstTry'] !== null ? ", {$best['firstTry']}% first try" : '') : 'No deliveries yet'],
            ],
            'periods' => self::PERIODS,
        ];
    }
}
