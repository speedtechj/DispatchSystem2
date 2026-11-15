<?php

namespace App\Filament\Pages;

use App\Support\CostReport;
use App\Support\Shipping\Shipments;
use BackedEnum;
use Filament\Pages\Page;
use Filament\Support\Icons\Heroicon;
use Illuminate\Support\Facades\Auth;
use Livewire\Attributes\Url;

/** Admin → Cost per box: fuel and sea shipping per hub and month, per box delivered; container vs RoRo. */
class CostPerBox extends Page
{
    protected string $view = 'filament.cost-per-box';

    protected static string|BackedEnum|null $navigationIcon = Heroicon::OutlinedCalculator;

    protected static ?string $navigationLabel = 'Cost per box';

    protected static ?string $title = 'Cost per box';

    protected static ?string $slug = 'cost-per-box';

    #[Url]
    public string $month = '';

    public static function canAccess(): bool
    {
        return (bool) Auth::user()?->hasRole('super_admin');
    }

    public function mount(): void
    {
        $this->month = preg_match('/^\d{4}-\d{2}$/', $this->month) ? $this->month : now()->format('Y-m');
    }

    protected function getViewData(): array
    {
        $r = new CostReport($this->month);
        $rows = $r->rows();

        return [
            'rows' => $rows,
            'all' => ['boxes' => $rows->sum('boxes'), 'fuel' => $rows->sum('fuel'), 'sea' => $rows->sum('sea'), 'total' => $rows->sum('total')],
            'modes' => $r->byMode(),
            'shipments' => Shipments::ready() ? $r->shipments() : collect(),
            'months' => collect(range(0, 11))->map(fn ($i) => now()->startOfMonth()->subMonths($i))->mapWithKeys(fn ($d) => [$d->format('Y-m') => $d->format('F Y')]),
        ];
    }
}
