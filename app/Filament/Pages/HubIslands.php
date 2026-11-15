<?php

namespace App\Filament\Pages;

use App\Models\Logistichub;
use App\Support\Shipping\Islands;
use BackedEnum;
use Filament\Pages\Page;
use Filament\Support\Icons\Heroicon;
use Illuminate\Support\Facades\Auth;
use UnitEnum;

/**
 * Settings → Hubs · island & sea: where each hub is, and whether boxes go there by sea.
 * Only hubs reached by sea show in Sea shipments → trip to the port.
 */
class HubIslands extends Page
{
    protected string $view = 'filament.shipping.hub-islands';

    protected static string|UnitEnum|null $navigationGroup = 'Settings';

    protected static string|BackedEnum|null $navigationIcon = Heroicon::OutlinedMap;

    protected static ?string $navigationLabel = 'Hubs · island & sea';

    protected static ?string $title = 'Hubs · island & sea';

    protected static ?string $slug = 'hub-islands';

    protected static ?int $navigationSort = 94;

    public static function canAccess(): bool
    {
        return Islands::ready() && (bool) Auth::user()?->hasRole('super_admin');
    }

    public function setIsland(int $id, string $island): void
    {
        if ($hub = Logistichub::find($id)) {
            $hub->forceFill(['island' => array_key_exists($island, Islands::ISLANDS) ? $island : null])->save();
        }
    }

    public function toggleSea(int $id): void
    {
        if ($hub = Logistichub::find($id)) {
            $hub->forceFill(['by_sea' => ! Islands::bySea($hub)])->save();
        }
    }

    public function setPort(int $id, string $port): void
    {
        if ($hub = Logistichub::find($id)) {
            $hub->forceFill(['port' => trim(mb_substr($port, 0, 80)) ?: null])->save();
        }
    }

    protected function getViewData(): array
    {
        return [
            'hubs' => Logistichub::orderByDesc('is_company')->orderBy('hub_name')->get()->map(fn ($h) => [
                'h' => $h, 'island' => Islands::islandOf($h), 'set' => (bool) $h->island, 'sea' => Islands::bySea($h),
                'seaSet' => $h->by_sea !== null, 'suggest' => Islands::suggest($h), 'port' => $h->port, 'lastPort' => Islands::port($h),
            ]),
            'islands' => Islands::ISLANDS,
        ];
    }
}
