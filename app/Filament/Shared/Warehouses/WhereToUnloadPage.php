<?php

namespace App\Filament\Shared\Warehouses;

use App\Models\Container;
use App\Models\Warehouse;
use App\Support\Warehouses\Coverage;
use Filament\Notifications\Notification;
use Filament\Pages\Page;
use Illuminate\Contracts\Support\Htmlable;
use Illuminate\Support\Facades\Auth;
use Illuminate\Support\Facades\DB;

/** Containers not unloaded yet: boxes by warehouse from the manifest, and where to unload. */
class WhereToUnloadPage extends Page
{
    protected string $view = 'filament.warehouses.where';

    protected static ?string $slug = 'where-to-unload';

    protected static ?string $title = 'Where to unload';

    protected static string|\BackedEnum|null $navigationIcon = 'heroicon-o-inbox-arrow-down';

    public static function canAccess(): bool
    {
        return Coverage::ready() && CoveragePage::isAdmin();
    }

    public function getHeading(): string|Htmlable
    {
        return '';
    }

    public function setWarehouse(int $containerId, int $warehouseId): void
    {
        $c = Container::where('is_unloaded', false)->findOrFail($containerId);
        DB::transaction(function () use ($c, $warehouseId) {
            $c->update(['warehouse_id' => $warehouseId]);
            $c->invoices()->where('is_verified', false)->update(['warehouse_id' => $warehouseId]);
        });
        Notification::make()->title($c->container_no.' → unload at '.Coverage::name($warehouseId))->success()->send();
    }

    protected function getViewData(): array
    {
        $whs = Warehouse::orderByRaw('id = ? desc', [Coverage::defaultId()])->orderBy('name')->get(['id', 'name']);
        $colors = ['#1d6fb8', '#c97a00', '#17895e', '#7a4fb0'];
        $rows = Container::where('is_unloaded', false)->whereDoesntHave('invoices', fn ($q) => $q->where('is_verified', true))
            ->latest('id')->limit(30)->get()->map(function ($c) use ($whs) {
                $split = Coverage::containerSplit($c->id);
                $total = max(1, array_sum($split));
                $best = collect($split)->except(0)->sortDesc()->keys()->first();
                $other = $total - ($split[$best] ?? 0);
                $close = $best && count(array_filter($split)) > 1 && ($split[$best] ?? 0) / $total < 0.6;

                return ['c' => $c, 'split' => $split, 'total' => $total, 'best' => $best,
                    'tip' => ! $best ? 'No boxes on the manifest yet' : ($close ? 'About even: pick the warehouse with more people' : 'Unload at '.Coverage::name($best).': only '.$other.' to transfer')];
            });

        return ['rows' => $rows, 'whs' => $whs, 'colors' => $colors, 'active' => Coverage::active()];
    }
}
