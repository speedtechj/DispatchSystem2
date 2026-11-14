<?php

namespace App\Filament\Pages;

use App\Models\Truck;
use App\Support\Fuel\Fuel;
use BackedEnum;
use Filament\Notifications\Notification;
use Filament\Pages\Page;
use Filament\Support\Icons\Heroicon;
use Illuminate\Support\Facades\Auth;
use UnitEnum;

/** Admin → Settings → Fuel: company TIN, fuel card, the cash rule, and each truck's fuel, tank and card. */
class FuelSettings extends Page
{
    protected string $view = 'filament.fuel.settings';

    protected static string|UnitEnum|null $navigationGroup = 'Settings';

    protected static string|BackedEnum|null $navigationIcon = Heroicon::OutlinedBeaker;

    protected static ?string $navigationLabel = 'Fuel';

    protected static ?string $title = 'Settings · Fuel';

    protected static ?string $slug = 'fuel-settings';

    protected static ?int $navigationSort = 92;

    public array $values = [];

    /** truck id => [fuel_type, tank_liters, fuel_card_last4] */
    public array $trucks = [];

    public static function canAccess(): bool
    {
        return Fuel::ready() && (bool) Auth::user()?->hasRole('super_admin');
    }

    public function mount(): void
    {
        $this->values = [
            'company_name' => (string) Fuel::setting('company_name', ''),
            'company_tin' => Fuel::companyTin(),
            'card_brand' => (string) Fuel::setting('card_brand', 'petron'),
            'cash_min_km' => (string) Fuel::cashMinKm(),
            'buffer_pct' => (string) Fuel::bufferPct(),
            'default_kml' => (string) Fuel::defaultKml(),
        ];
        foreach (Truck::orderBy('plate_no')->get() as $t) {
            $this->trucks[$t->id] = ['fuel_type' => (string) $t->fuel_type, 'tank_liters' => (string) $t->tank_liters, 'fuel_card_last4' => (string) $t->fuel_card_last4];
        }
    }

    public function save(): void
    {
        $this->validate([
            'values.company_name' => 'nullable|string|max:120',
            'values.company_tin' => ['nullable', 'string', 'max:20', 'regex:/^[0-9 -]*$/'],
            'values.card_brand' => 'required|in:'.implode(',', array_keys(Fuel::PROVIDERS)),
            'values.cash_min_km' => 'required|integer|min:0|max:2000',
            'values.buffer_pct' => 'required|integer|min:0|max:50',
            'values.default_kml' => 'required|numeric|min:1|max:30',
            'trucks.*.fuel_type' => 'nullable|in:diesel,gasoline',
            'trucks.*.tank_liters' => 'nullable|integer|min:10|max:1000',
            'trucks.*.fuel_card_last4' => ['nullable', 'regex:/^\d{4}$/'],
        ], [
            'values.company_tin.regex' => 'Numbers only, like 123-456-789-000.',
            'trucks.*.fuel_card_last4.regex' => 'The last 4 digits of the card.',
        ]);
        Fuel::put('company_name', trim($this->values['company_name']));
        Fuel::put('company_tin', trim($this->values['company_tin']));
        Fuel::put('card_brand', $this->values['card_brand']);
        Fuel::put('cash_min_km', (int) $this->values['cash_min_km']);
        Fuel::put('buffer_pct', (int) $this->values['buffer_pct']);
        Fuel::put('default_kml', round((float) $this->values['default_kml'], 1));
        foreach ($this->trucks as $id => $v) {
            Truck::whereKey((int) $id)->update([
                'fuel_type' => $v['fuel_type'] ?: null,
                'tank_liters' => $v['tank_liters'] !== '' ? (int) $v['tank_liters'] : null,
                'fuel_card_last4' => $v['fuel_card_last4'] ?: null,
            ]);
        }
        Notification::make()->title('Fuel settings saved')->success()->send();
    }

    protected function getViewData(): array
    {
        return [
            'list' => Truck::orderBy('plate_no')->get(['id', 'plate_no', 'description', 'category']),
            'aiOn' => \App\Support\Fuel\FuelReader::on(),
        ];
    }
}
