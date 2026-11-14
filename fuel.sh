#!/usr/bin/env bash
#
# Dispatch System — Fuel
# Only the files changed in this step; the rest of your project is left as it is.
#
#   cd ~/Desktop/Project/DispatchSystem
#   bash ~/Desktop/Project/fuel.sh

set -euo pipefail
[ -f artisan ] || { echo "Run this from inside your DispatchSystem project folder (the one with 'artisan')."; exit 1; }

STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="../DispatchSystem-backup-$STAMP.tar.gz"
echo "▶ Backing up the project to $BACKUP"
tar -czf "$BACKUP" --exclude=vendor --exclude=node_modules --exclude=storage/logs .

echo "▶ Writing 33 files"

# ---------------------------------------------------------------- app/Filament/Company/Pages/Fuel.php
mkdir -p 'app/Filament/Company/Pages'
cat > 'app/Filament/Company/Pages/Fuel.php' <<'DISPATCH_FILE_END_0'
<?php

namespace App\Filament\Company\Pages;

use App\Filament\Shared\Fuel\FuelPage;

class Fuel extends FuelPage {}
DISPATCH_FILE_END_0

# ---------------------------------------------------------------- app/Filament/Company/Pages/TripFuel.php
mkdir -p 'app/Filament/Company/Pages'
cat > 'app/Filament/Company/Pages/TripFuel.php' <<'DISPATCH_FILE_END_1'
<?php

namespace App\Filament\Company\Pages;

use App\Filament\Shared\Fuel\TripFuelPage;

class TripFuel extends TripFuelPage {}
DISPATCH_FILE_END_1

# ---------------------------------------------------------------- app/Filament/Company/Resources/Deliverylogs/Tables/DeliverylogsTable.php
mkdir -p 'app/Filament/Company/Resources/Deliverylogs/Tables'
cat > 'app/Filament/Company/Resources/Deliverylogs/Tables/DeliverylogsTable.php' <<'DISPATCH_FILE_END_2'
<?php

namespace App\Filament\Company\Resources\Deliverylogs\Tables;

use App\Filament\Company\Pages\TripStops;
use App\Filament\Company\Pages\TripFuel;
use App\Filament\Tables\TripBoardColumns;
use App\Models\Deliverylog;
use App\Models\Tripinvoice;
use Filament\Actions\Action;
use Filament\Actions\BulkActionGroup;
use Filament\Actions\DeleteBulkAction;
use Filament\Actions\EditAction;
use Filament\Notifications\Notification;
use Filament\Support\Icons\Heroicon;
use Filament\Tables\Columns\TextColumn;
use Filament\Tables\Table;
use Illuminate\Database\Eloquent\Builder;
use Illuminate\Support\Facades\Auth;

class DeliverylogsTable
{
    public static function configure(Table $table): Table
    {
        return $table
            ->query(Deliverylog::query()->where('logistichub_id', '=', Auth::user()->logistichub_id))
            ->modifyQueryUsing(fn (Builder $query) => TripBoardColumns::withProgress($query, 'hub'))
            ->columns([
                TextColumn::make('trip_number')
                    ->searchable(),
                TripBoardColumns::status('hub'),
                TripBoardColumns::progress('hub'),
                TextColumn::make('truck.plate_no')
                    ->sortable(),
                TextColumn::make('trip_day')
                    ->numeric()
                    ->toggleable(isToggledHiddenByDefault: true)
                    ->sortable(),
                TextColumn::make('Total Invoices')
                    ->badge()
                    ->color('success')
                    ->label('Total Invoices')
                    ->getStateUsing(function ($record) {

                        return Tripinvoice::where('deliveryloghub_id', $record->id)->count();
                    }),
                TextColumn::make('Total Loaded')
                    ->badge()
                    ->color('success')
                    ->label('Total Loaded')
                    ->getStateUsing(function ($record) {

                        return Tripinvoice::where('deliveryloghub_id', $record->id)->where('is_loaded_hub', 1)->count();
                    }),

                TextColumn::make('eta')
                    ->toggleable(isToggledHiddenByDefault: true)
                    ->date()
                    ->sortable(),
                TextColumn::make('departure_date')
                    ->toggleable(isToggledHiddenByDefault: true)
                    ->date()
                    ->sortable(),
                TextColumn::make('delivery_date')
                    ->toggleable(isToggledHiddenByDefault: true)
                    ->date()
                    ->sortable(),
                TextColumn::make('waybill_number')
                    ->searchable()
                    ->toggleable(isToggledHiddenByDefault: true),
                TextColumn::make('user.full_name')
                    ->label('Created By')
                    ->toggleable(isToggledHiddenByDefault: true)
                    ->sortable(),
                TextColumn::make('created_at')
                    ->dateTime()
                    ->sortable()
                    ->toggleable(isToggledHiddenByDefault: true),
                TextColumn::make('updated_at')
                    ->dateTime()
                    ->sortable()
                    ->toggleable(isToggledHiddenByDefault: true),
            ])
            ->filters([
                TripBoardColumns::filter('hub'),
                //
            ])
            ->recordActions([
                Action::make('stops')
                    ->label('Stops & loading')
                    ->icon('heroicon-o-map')
                    ->button()
                    ->color('gray')
                    ->url(fn ($record): string => TripStops::getUrl(['trip' => $record->id])),
                Action::make('fuel')
                    ->label('Fuel')
                    ->icon('heroicon-o-beaker')
                    ->button()
                    ->color('gray')
                    ->visible(fn (): bool => \App\Support\Fuel\Fuel::ready())
                    ->url(fn ($record): string => TripFuel::getUrl(['trip' => $record->id])),
                Action::make('releasetruct')
                    ->requiresConfirmation()
                    ->label('Released Truck')
                    ->color('info')
                    ->icon(Heroicon::Truck)
                    ->hidden(function ($record) {

                        return ! $record->is_current;
                    })
                    ->action(function ($record) {

                        $record->truck->update([
                            'is_assigned' => 0,
                        ]);
                        $record->update([
                            'is_current' => 0,
                            'is_active' => 0,
                        ]);

                        Notification::make()
                            ->title('Truck Released Successfully')
                            ->success()
                            ->send();
                    }),
                EditAction::make(),
            ])
            ->toolbarActions([
                BulkActionGroup::make([
                    DeleteBulkAction::make(),
                ]),
            ]);
    }
}
DISPATCH_FILE_END_2

# ---------------------------------------------------------------- app/Filament/Delivery/Pages/Fuel.php
mkdir -p 'app/Filament/Delivery/Pages'
cat > 'app/Filament/Delivery/Pages/Fuel.php' <<'DISPATCH_FILE_END_3'
<?php

namespace App\Filament\Delivery\Pages;

use App\Support\DriverTrip;
use App\Support\Fuel\Fuel as FuelData;
use App\Support\Fuel\FuelReader;
use App\Support\Photos\PhotoShrinker;
use Filament\Notifications\Notification;
use Filament\Pages\Page;
use Illuminate\Contracts\Support\Htmlable;
use Illuminate\Support\Facades\Auth;
use Illuminate\Support\Facades\Storage;
use Livewire\Attributes\Locked;
use Livewire\WithFileUploads;

/**
 * Driver app › ⛽ Add fuel: photo of the receipt (read by AI when on), check the numbers,
 * card or cash, photo of the odometer, save. The office sees it on the Fuel page.
 */
class Fuel extends Page
{
    use WithFileUploads;

    protected string $view = 'filament.delivery.pages.fuel';

    protected static bool $shouldRegisterNavigation = false;

    protected static ?string $slug = 'fuel';

    /** receipt, check, odometer, done */
    #[Locked]
    public string $step = 'receipt';

    public $upload = null;

    #[Locked]
    public ?string $receiptPath = null;

    #[Locked]
    public ?string $odometerPath = null;

    public array $f = [];

    #[Locked]
    public bool $aiRead = false;

    #[Locked]
    public array $aiData = [];

    #[Locked]
    public ?float $lat = null;

    #[Locked]
    public ?float $lng = null;

    #[Locked]
    public ?int $savedId = null;

    public static function canAccess(): bool
    {
        return FuelData::ready() && Auth::check();
    }

    public function mount(): void
    {
        $this->f = $this->blank();
    }

    protected function blank(): array
    {
        return ['station' => '', 'product' => '', 'fuel_type' => '', 'liters' => '', 'price_per_liter' => '', 'total' => '',
            'vatable' => '', 'vat' => '', 'station_tin' => '', 'invoice_no' => '', 'buyer_tin_ok' => '', 'paid_with' => 'card',
            'card_last4' => '', 'odometer' => '', 'filled_at' => now()->format('Y-m-d\TH:i')];
    }

    public function getTitle(): string|Htmlable
    {
        return 'Add fuel';
    }

    public function getHeading(): string|Htmlable
    {
        return '';
    }

    /** Phone location when the fill is added: compared with the truck GPS. */
    public function setPlace(mixed $lat, mixed $lng): void
    {
        $this->lat = is_numeric($lat) && abs((float) $lat) <= 90 ? (float) $lat : null;
        $this->lng = is_numeric($lng) && abs((float) $lng) <= 180 ? (float) $lng : null;
    }

    /** Called by the browser after a (shrunk) photo is uploaded. */
    public function savePhoto(): void
    {
        $this->validate(['upload' => 'required|image|max:12288'], ['upload.image' => 'That file is not a photo.']);
        $path = $this->upload->store('fuel/'.now()->format('Y-m'), 'public');
        PhotoShrinker::file('public', $path);
        $this->reset('upload');

        if ($this->step === 'odometer') {
            if ($this->odometerPath) {
                Storage::disk('public')->delete($this->odometerPath);
            }
            $this->odometerPath = $path;
            if ($this->f['odometer'] === '' && ($km = FuelReader::odometer($path))) {
                $this->f['odometer'] = (string) $km;
            }

            return;
        }

        if ($this->receiptPath) {
            Storage::disk('public')->delete($this->receiptPath);
        }
        $this->receiptPath = $path;
        $read = FuelReader::receipt($path);
        $this->aiRead = $read !== [];
        $this->aiData = $read;
        foreach ($read as $k => $v) {
            if (array_key_exists($k, $this->f)) {
                $this->f[$k] = (string) $v;
            }
        }
        if (isset($read['buyer_tin'])) {
            $this->f['buyer_tin_ok'] = FuelData::buyerTinOk($read['buyer_tin'], (float) ($read['total'] ?? 0)) === false ? '0' : '1';
        }
        if (isset($read['filled_at'])) {
            $this->f['filled_at'] = str_replace(' ', 'T', $read['filled_at']);
        }
        $this->step = 'check';
    }

    public function noReceiptPhoto(): void
    {
        $this->step = 'check';
    }

    public function toOdometer(): void
    {
        $this->validateFill();
        $this->step = 'odometer';
    }

    public function back(): void
    {
        $this->step = match ($this->step) { 'odometer' => 'check', default => 'receipt' };
    }

    protected function validateFill(): void
    {
        foreach (['liters', 'total', 'price_per_liter', 'vat', 'vatable'] as $k) {
            $this->f[$k] = str_replace([',', '₱', ' '], '', (string) $this->f[$k]);
        }
        $this->validate([
            'f.liters' => 'required|numeric|min:1|max:1000',
            'f.total' => 'required|numeric|min:1|max:200000',
            'f.price_per_liter' => 'nullable|numeric|min:10|max:300',
            'f.vat' => 'nullable|numeric|min:0',
            'f.vatable' => 'nullable|numeric|min:0',
            'f.fuel_type' => 'required|in:diesel,gasoline',
            'f.paid_with' => 'required|in:card,cash',
            'f.station' => 'nullable|string|max:120',
            'f.product' => 'nullable|string|max:80',
            'f.filled_at' => 'required|date',
        ], [
            'f.liters.required' => 'Type the liters on the receipt.',
            'f.total.required' => 'Type the total amount.',
            'f.fuel_type.required' => 'Diesel or gasoline?',
        ]);
    }

    public function save(): void
    {
        $this->validateFill();
        $this->validate(['f.odometer' => 'nullable|integer|min:1|max:9999999']);
        $driver = Auth::user();
        $trip = DriverTrip::currentTrip($driver);
        $truck = FuelData::truckFor($driver, $trip);
        if (! $truck) {
            Notification::make()->title('No truck for you yet')->body('Ask the office to put you on a truck, then add the fill again.')->danger()->send();

            return;
        }
        $at = \Illuminate\Support\Carbon::parse($this->f['filled_at']);
        $fill = FuelData::save([
            ...$this->f,
            'filled_at' => $at->gt(now()) ? now() : $at,
            'buyer_tin_ok' => $this->f['buyer_tin_ok'] === '' ? null : $this->f['buyer_tin_ok'] === '1',
            'receipt_path' => $this->receiptPath, 'odometer_path' => $this->odometerPath,
            'lat' => $this->lat, 'lng' => $this->lng, 'ai_read' => $this->aiRead, 'ai_data' => $this->aiData ?: null,
        ], $truck, $driver, $trip);
        $this->savedId = $fill->id;
        $this->step = 'done';
    }

    public function another(): void
    {
        $this->reset(['receiptPath', 'odometerPath', 'aiRead', 'aiData', 'savedId']);
        $this->f = $this->blank();
        $this->step = 'receipt';
    }

    protected function getViewData(): array
    {
        $driver = Auth::user();
        $trip = DriverTrip::currentTrip($driver);
        $truck = FuelData::truckFor($driver, $trip);
        $cash = FuelData::cashFor($trip);
        $prev = $truck ? \App\Models\Fuel\FuelFill::where('truck_id', $truck->id)->whereNotNull('odometer')->latest('filled_at')->first() : null;
        $odo = (int) $this->f['odometer'];
        $kmSince = $prev && $odo > $prev->odometer && $odo - $prev->odometer < 5000 ? $odo - $prev->odometer : null;
        $liters = (float) $this->f['liters'];

        return [
            'trip' => $trip, 'truck' => $truck, 'cash' => $cash,
            'aiOn' => FuelReader::on(),
            'wrongFuel' => $truck?->fuel_type && $this->f['fuel_type'] && $truck->fuel_type !== $this->f['fuel_type'],
            'problems' => $this->step === 'check' ? FuelReader::problems($this->f) : [],
            'receiptUrl' => $this->receiptPath ? Storage::disk('public')->url($this->receiptPath) : null,
            'odometerUrl' => $this->odometerPath ? Storage::disk('public')->url($this->odometerPath) : null,
            'prevOdo' => $prev?->odometer, 'kmSince' => $kmSince, 'kml' => $kmSince && $liters > 0 ? round($kmSince / $liters, 1) : null,
            'needTin' => (float) $this->f['total'] >= 1000 && FuelData::companyTin() !== '',
            'companyTin' => FuelData::companyTin(), 'companyName' => (string) FuelData::setting('company_name', ''),
            'saved' => $this->savedId ? \App\Models\Fuel\FuelFill::find($this->savedId) : null,
        ];
    }
}
DISPATCH_FILE_END_3

# ---------------------------------------------------------------- app/Filament/Pages/Fuel.php
mkdir -p 'app/Filament/Pages'
cat > 'app/Filament/Pages/Fuel.php' <<'DISPATCH_FILE_END_4'
<?php

namespace App\Filament\Pages;

use App\Filament\Shared\Fuel\FuelPage;

class Fuel extends FuelPage {}
DISPATCH_FILE_END_4

# ---------------------------------------------------------------- app/Filament/Pages/FuelSettings.php
mkdir -p 'app/Filament/Pages'
cat > 'app/Filament/Pages/FuelSettings.php' <<'DISPATCH_FILE_END_5'
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
DISPATCH_FILE_END_5

# ---------------------------------------------------------------- app/Filament/Pages/TripFuel.php
mkdir -p 'app/Filament/Pages'
cat > 'app/Filament/Pages/TripFuel.php' <<'DISPATCH_FILE_END_6'
<?php

namespace App\Filament\Pages;

use App\Filament\Shared\Fuel\TripFuelPage;

class TripFuel extends TripFuelPage {}
DISPATCH_FILE_END_6

# ---------------------------------------------------------------- app/Filament/Resources/Deliverylogs/Tables/DeliverylogsTable.php
mkdir -p 'app/Filament/Resources/Deliverylogs/Tables'
cat > 'app/Filament/Resources/Deliverylogs/Tables/DeliverylogsTable.php' <<'DISPATCH_FILE_END_7'
<?php

namespace App\Filament\Resources\Deliverylogs\Tables;

use App\Filament\Pages\TripStops;
use App\Filament\Pages\TripFuel;
use App\Filament\Tables\TripBoardColumns;
use App\Models\Deliverylog;
use App\Models\Logistichub;
use Filament\Actions\Action;
use Filament\Actions\ActionGroup;
use Filament\Actions\BulkActionGroup;
use Filament\Actions\DeleteBulkAction;
use Filament\Actions\EditAction;
use Filament\Notifications\Notification;
use Filament\Support\Icons\Heroicon;
use Filament\Tables\Columns\IconColumn;
use Filament\Tables\Columns\TextColumn;
use Filament\Tables\Columns\ToggleColumn;
use Filament\Tables\Enums\RecordActionsPosition;
use Filament\Tables\Filters\SelectFilter;
use Filament\Tables\Table;
use Illuminate\Database\Eloquent\Builder;
use Illuminate\Support\Facades\Auth;
use Illuminate\Support\Facades\DB;

class DeliverylogsTable
{
    public static function configure(Table $table): Table
    {
        return $table
            ->recordUrl(null)
            ->query(Deliverylog::query()->where('logistichub_id', '=', Auth::user()->logistichub_id))
            ->modifyQueryUsing(fn (Builder $query) => TripBoardColumns::withProgress($query, 'delivery'))
            ->columns([
                TextColumn::make('trip_number')
                    ->searchable(),

                TripBoardColumns::status('delivery'),

                TripBoardColumns::progress('delivery'),

                TextColumn::make('truck_id')
                    ->label('Truck')
                    ->searchable(query: function ($query, $search) {
                        return $query->whereHas('truck', function ($q) use ($search) {
                            $q->where('plate_no', 'like', "%{$search}%");
                        });
                    })
                    ->sortable()
                    ->getStateUsing(function ($record) {
                        return $record->truck ? $record->truck->plate_no : 'Truck not assigned';
                    }),
                TextColumn::make('vicheletype')
                    ->label('Vichele Type/Size')
                    ->getStateUsing(function ($record) {
                        return $record->truck ? $record->truck->category : ' ';
                    }),
                TextColumn::make('trip_day')
                    ->toggleable(isToggledHiddenByDefault: true)
                    ->numeric()
                    ->sortable(),
                TextColumn::make('logistichub.hub_name')
                    ->toggleable(isToggledHiddenByDefault: true)
                    ->label('Logistic Hub/Location'),
                TextColumn::make('Total Invoices')
                    ->label('Total Invoices')
                    ->badge()
                    ->color('danger')
                    ->getStateUsing(function ($record) {
                        return $record->tripinvoices()->count();
                    }),
                TextColumn::make('Total Loaded')
                    ->badge()
                    ->color('success')
                    ->label('Total Loaded')
                    ->getStateUsing(function ($record) {
                        return $record->tripinvoices()->whereHas('invoice', function ($query) {
                            $query->where('is_loaded', 1);
                        })->count();
                    }),
                TextColumn::make('Verified Invoices')
                    ->label('Invoices Verified')
                    ->badge()
                    ->toggleable(isToggledHiddenByDefault: true)
                    ->color('info')
                    ->getStateUsing(function ($record) {
                        return $record->tripinvoices()->whereHas('invoice', function ($query) {
                            $query->where('is_verified', 1);
                        })->count();
                        // return $record->tripinvoices->invoices->where('is_verified', 1)->count();
                    }),
                TextColumn::make('City')
                    ->label('City')
                    ->separator(',')
                    ->color('primary')
                    ->listWithLineBreaks()
                    ->limitList(3)
                    ->expandableLimitedList()
                    ->getStateUsing(function ($record) {
                        // only the distinct places, straight from the database (a trip can hold thousands of boxes)
                        return DB::table('tripinvoices')
                            ->join('invoices', 'invoices.id', '=', 'tripinvoices.invoice_id')
                            ->where('tripinvoices.deliverylog_id', $record->id)
                            ->whereNotNull('invoices.receiver_city')->where('invoices.receiver_city', '!=', '')
                            ->distinct()->orderBy('invoices.receiver_city')->pluck('invoices.receiver_city');
                        //   ->implode(" , ");
                    }),
                TextColumn::make('Province')
                    ->label('Province')
                    ->separator(',')
                    ->color('primary')
                    ->listWithLineBreaks()
                    ->limitList(3)
                    ->expandableLimitedList()
                    ->getStateUsing(function ($record) {
                        // only the distinct places, straight from the database (a trip can hold thousands of boxes)
                        return DB::table('tripinvoices')
                            ->join('invoices', 'invoices.id', '=', 'tripinvoices.invoice_id')
                            ->where('tripinvoices.deliverylog_id', $record->id)
                            ->whereNotNull('invoices.receiver_province')->where('invoices.receiver_province', '!=', '')
                            ->distinct()->orderBy('invoices.receiver_province')->pluck('invoices.receiver_province');
                        //   ->implode(" , ");
                    }),
                IconColumn::make('is_lock')
                    ->label('Lock Status')
                    ->boolean()
                    ->trueIcon(Heroicon::LockClosed)
                    ->falseIcon(Heroicon::LockOpen)
                    ->sortable()
                    ->color(function ($state) {
                        return $state ? 'danger' : 'success';
                    }),

                TextColumn::make('waybill_number')
                    ->label('Waybill No. / Container No.')
                    ->searchable()
                    ->sortable()
                    ->toggleable(isToggledHiddenByDefault: true)
                    ->sortable(),
                TextColumn::make('eta')
                    ->toggleable(isToggledHiddenByDefault: true)
                    ->label('ETA')
                    ->date()
                    ->sortable(),
                TextColumn::make('departure_date')
                    ->toggleable(isToggledHiddenByDefault: true)
                    ->date()
                    ->sortable(),
                TextColumn::make('assigned_to')
                    ->sortable()
                    ->getStateUsing(function ($record) {
                        return Logistichub::where('id', $record->assigned_to)->first()->hub_name;
                    }),
                TextColumn::make('user.full_name')
                    ->label('Created By')
                    ->toggleable(isToggledHiddenByDefault: true)
                    ->sortable(),

                ToggleColumn::make('is_active')
                    ->label('Is Active')
                    ->sortable()
                    ->toggleable(isToggledHiddenByDefault: true),
                TextColumn::make('created_at')
                    ->dateTime()
                    ->sortable()
                    ->toggleable(isToggledHiddenByDefault: true),
                TextColumn::make('updated_at')
                    ->dateTime()
                    ->sortable()
                    ->toggleable(isToggledHiddenByDefault: true),
            ])
            ->filters([
                TripBoardColumns::filter('delivery'),
                SelectFilter::make('is_lock')
                    ->label('Is Locked')
                    ->options([
                        1 => 'Yes',
                        0 => 'No',
                    ]),
                SelectFilter::make('is_active')
                    ->label('Is Active')
                    ->options([
                        1 => 'Yes',
                        0 => 'No',
                    ])->default(1),
                SelectFilter::make('assigned_to')
                    ->label('Going To')
                    ->options(Logistichub::query()->pluck('hub_name', 'id'))
                    ->searchable()
                    ->preload(),
            ])->deferFilters(false)
            ->recordActions([
                Action::make('stops')
                    ->label('Stops & loading')
                    ->icon('heroicon-o-map')
                    ->button()
                    ->color('gray')
                    ->url(fn ($record): string => TripStops::getUrl(['trip' => $record->id])),
                Action::make('fuel')
                    ->label('Fuel')
                    ->icon('heroicon-o-beaker')
                    ->button()
                    ->color('gray')
                    ->visible(fn (): bool => \App\Support\Fuel\Fuel::ready())
                    ->url(fn ($record): string => TripFuel::getUrl(['trip' => $record->id])),
                ActionGroup::make([
                    Action::make('locktrip')
                        ->requiresConfirmation()
                        ->label(function ($record) {
                            return $record->is_lock ? 'Unlock Trip' : 'Lock Trip';
                        })
                        ->color('info')
                        ->icon(function ($record) {
                            return $record->is_lock ? Heroicon::LockOpen : Heroicon::LockClosed;
                        })
                        ->hidden(function ($record) {
                            //  dd(Auth::user()->hasRole('super_admin'));
                            return Auth::user()->hasRole('super_admin') ? false : true;
                        })
                        ->action(function ($record) {
                            $record->update([
                                'is_lock' => ! $record->is_lock,
                            ]);

                            Notification::make()
                                ->title($record->is_lock ? 'Trip Locked Successfully' : 'Trip Unlocked Successfully')
                                ->success()
                                ->send();
                        }),
                    Action::make('releasetruct')
                        ->requiresConfirmation()
                        ->label('Released Truck')
                        ->color('info')
                        ->icon(Heroicon::Truck)
                        ->hidden(function ($record) {

                            return ! $record->is_current;
                        })
                        ->action(function ($record) {

                            $record->truck->update([
                                'is_assigned' => 0,
                            ]);
                            $record->update([
                                'is_current' => 0,
                                'is_active' => 0,
                            ]);

                            Notification::make()
                                ->title('Truck Released Successfully')
                                ->success()
                                ->send();
                        }),
                    EditAction::make()
                        ->label('Edit')
                        ->icon(Heroicon::PencilSquare)
                        ->hidden(function ($record) {
                            return $record->is_lock;
                        }),

                ]),
            ], position: RecordActionsPosition::BeforeColumns)
            ->toolbarActions([
                BulkActionGroup::make([
                    //    DeleteBulkAction::make(),

                ]),
            ]);
    }
}
DISPATCH_FILE_END_7

# ---------------------------------------------------------------- app/Filament/Shared/Fuel/FuelPage.php
mkdir -p 'app/Filament/Shared/Fuel'
cat > 'app/Filament/Shared/Fuel/FuelPage.php' <<'DISPATCH_FILE_END_8'
<?php

namespace App\Filament\Shared\Fuel;

use App\Models\Fuel\FuelFill;
use App\Models\Fuel\FuelStatement;
use App\Models\Fuel\FuelStatementLine;
use App\Support\Fuel\Fuel;
use App\Support\Fuel\FuelReport;
use App\Support\Fuel\FuelStatements;
use App\Support\Tracking\Tracker;
use BackedEnum;
use Filament\Facades\Filament;
use Filament\Notifications\Notification;
use Filament\Pages\Page;
use Filament\Support\Icons\Heroicon;
use Illuminate\Support\Facades\Auth;
use Livewire\Attributes\Url;
use Livewire\WithFileUploads;

/**
 * Fuel: what each truck used and spent, alerts, fuel card statements, this week's price
 * and VAT. Admin sees every hub; Warehouse and Partner hub see their own trucks.
 */
abstract class FuelPage extends Page
{
    use WithFileUploads;

    protected string $view = 'filament.fuel.page';

    protected static string|BackedEnum|null $navigationIcon = Heroicon::OutlinedBeaker;

    protected static ?string $navigationLabel = 'Fuel';

    protected static ?string $title = 'Fuel';

    protected static ?string $slug = 'fuel';

    #[Url]
    public string $tab = 'trucks';

    #[Url]
    public string $month = '';

    #[Url]
    public ?int $truck = null;

    /** statement import */
    public $statementFile = null;

    public string $provider = 'petron';

    public ?int $statementId = null;

    public string $lineStatus = '';

    public string $priceDiesel = '';

    public string $priceGasoline = '';

    public static function canAccess(): bool
    {
        return Fuel::ready() && Tracker::hubFor(Auth::user(), Filament::getCurrentPanel()?->getId()) !== false;
    }

    public function mount(): void
    {
        $this->month = preg_match('/^\d{4}-\d{2}$/', $this->month) ? $this->month : now()->format('Y-m');
        $this->provider = (string) Fuel::setting('card_brand', 'petron');
    }

    protected function hub(): int|false|null
    {
        return Tracker::hubFor(Auth::user(), Filament::getCurrentPanel()?->getId());
    }

    protected function isAdmin(): bool
    {
        return $this->hub() === null;
    }

    public function setTab(string $tab): void
    {
        $this->tab = in_array($tab, ['trucks', 'fills', 'alerts', 'cards', 'prices', 'vat'], true) ? $tab : 'trucks';
    }

    public function showTruck(?int $id): void
    {
        $this->truck = $id;
        $this->tab = 'fills';
    }

    public function importStatement(): void
    {
        $this->validate(['statementFile' => 'required|file|max:10240', 'provider' => 'required|in:'.implode(',', array_keys(Fuel::PROVIDERS))]);
        $hub = $this->hub();
        $s = FuelStatements::import($this->statementFile->getRealPath(), $this->provider, Auth::id(), $hub ?: null, $this->statementFile->getClientOriginalName());
        $this->statementFile = null;
        $this->statementId = $s->id;
        if (! $s->lines) {
            Notification::make()->title('No charges found in the file')->body('Save the statement as CSV, with the column titles (date, card or plate, liters, amount) in the first rows.')->warning()->send();

            return;
        }
        $m = $s->lines()->where('status', 'matched')->count();
        Notification::make()->title("{$s->lines} charges imported · {$m} matched")->success()->send();
    }

    public function savePrices(): void
    {
        abort_unless($this->isAdmin(), 403);
        $week = Fuel::weekStart()->toDateString();
        foreach (['diesel' => $this->priceDiesel, 'gasoline' => $this->priceGasoline] as $type => $v) {
            $v = (float) str_replace(',', '', $v);
            Fuel::put("price.{$type}", $v > 0 ? ['week' => $week, 'price' => round($v, 2)] : null);
        }
        $this->priceDiesel = $this->priceGasoline = '';
        Notification::make()->title('This week\'s price saved')->success()->send();
    }

    protected function getViewData(): array
    {
        $report = new FuelReport($this->hub(), $this->month);
        $truckIds = $report->trucks()->pluck('id');
        $statements = FuelStatement::query()->when(! $this->isAdmin(), fn ($q) => $q->where('logistichub_id', $this->hub()))->latest()->take(8)->get();
        $statement = $this->statementId ? $statements->firstWhere('id', $this->statementId) : $statements->first();

        return [
            'report' => $report,
            'totals' => $report->totals(),
            'rows' => $this->tab === 'trucks' ? $report->perTruck() : collect(),
            'alerts' => in_array($this->tab, ['alerts', 'trucks'], true) ? $report->alerts() : [],
            'fills' => $this->tab === 'fills' || $this->tab === 'vat'
                ? $report->fills()->with(['truck', 'driver', 'trip'])->when($this->truck && $this->tab === 'fills', fn ($q) => $q->where('truck_id', $this->truck))->orderByDesc('filled_at')->get()
                : collect(),
            'statements' => $statements,
            'statement' => $statement,
            'lines' => $statement ? FuelStatementLine::where('fuel_statement_id', $statement->id)
                ->where(fn ($q) => $q->whereIn('truck_id', $truckIds->all() ?: [0])->orWhereNull('truck_id'))
                ->when($this->lineStatus, fn ($q) => $q->where('status', $this->lineStatus))->with(['truck', 'fuelFill'])->orderBy('charged_at')->get() : collect(),
            'lineCounts' => $statement ? $statement->lines()->selectRaw('status, count(*) n')->groupBy('status')->pluck('n', 'status') : collect(),
            'prices' => ['diesel' => Fuel::price('diesel'), 'gasoline' => Fuel::price('gasoline')],
            'weeks' => $this->tab === 'prices' ? Fuel::priceWeeks() : [],
            'isAdmin' => $this->isAdmin(),
            'truckName' => $this->truck ? $report->trucks()->firstWhere('id', $this->truck)?->plate_no : null,
            'months' => collect(range(0, 11))->map(fn ($i) => now()->startOfMonth()->subMonths($i))->mapWithKeys(fn ($d) => [$d->format('Y-m') => $d->format('F Y')]),
            'vatUrl' => route('fuel.vat-export', ['month' => $this->month, 'panel' => Filament::getCurrentPanel()?->getId()]),
            'companyTin' => Fuel::companyTin(),
        ];
    }
}
DISPATCH_FILE_END_8

# ---------------------------------------------------------------- app/Filament/Shared/Fuel/TripFuelPage.php
mkdir -p 'app/Filament/Shared/Fuel'
cat > 'app/Filament/Shared/Fuel/TripFuelPage.php' <<'DISPATCH_FILE_END_9'
<?php

namespace App\Filament\Shared\Fuel;

use App\Models\Deliverylog;
use App\Models\Fuel\FuelCash;
use App\Models\Fuel\FuelFill;
use App\Support\Fuel\Fuel;
use App\Support\Maps\TripSorter;
use Filament\Notifications\Notification;
use Filament\Pages\Page;
use Illuminate\Contracts\Support\Htmlable;
use Illuminate\Support\Facades\Auth;
use Livewire\Attributes\Locked;
use Livewire\Attributes\Url;

/**
 * Delivery Log › trip › Fuel: the fuel cash estimate (trip km ÷ km per liter × this
 * week's price + buffer), cash given, the fills on the trip, and the change returned.
 */
abstract class TripFuelPage extends Page
{
    protected string $view = 'filament.fuel.trip';

    protected static bool $shouldRegisterNavigation = false;

    protected static ?string $slug = 'trip-fuel';

    #[Url(as: 'trip')]
    #[Locked]
    public int $tripId = 0;

    public string $give = '';

    public string $returned = '';

    public string $note = '';

    public static function canAccess(): bool
    {
        return Fuel::ready() && parent::canAccess();
    }

    public function mount(): void
    {
        $this->tripId = (int) request()->query('trip', $this->tripId);
        $trip = $this->trip();
        abort_unless($trip && TripSorter::canSee(Auth::user(), $trip), 404);
        $this->give = (string) (Fuel::estimate($trip)['amount'] ?? '');
    }

    protected function trip(): ?Deliverylog
    {
        return Deliverylog::with('truck')->find($this->tripId);
    }

    public function getTitle(): string|Htmlable
    {
        return 'Fuel for this trip';
    }

    public function getSubheading(): ?string
    {
        $trip = $this->trip();

        return $trip ? 'Trip '.$trip->trip_number.($trip->truck ? ' · '.$trip->truck->plate_no : '') : null;
    }

    public function giveCash(): void
    {
        $trip = $this->trip();
        abort_unless($trip && TripSorter::canSee(Auth::user(), $trip), 404);
        $amount = round((float) str_replace([',', '₱'], '', $this->give), 2);
        if ($amount <= 0) {
            Notification::make()->title('Type the cash you give the driver')->warning()->send();

            return;
        }
        if (Fuel::cashFor($trip)) {
            Notification::make()->title('Fuel cash was already given for this trip')->warning()->send();

            return;
        }
        $e = Fuel::estimate($trip);
        FuelCash::create([
            'deliverylog_id' => $trip->id, 'truck_id' => $trip->truck_id, 'driver_id' => \App\Models\Truckcrew::where('truck_id', $trip->truck_id)->latest('id')->value('crew'),
            'km' => $e['km'], 'km_per_liter' => $e['kml'], 'price' => $e['price'], 'buffer_pct' => $e['buffer'],
            'estimate' => $e['amount'], 'given' => $amount, 'given_at' => now(), 'given_by' => Auth::id(),
            'note' => trim($this->note) ?: null,
        ]);
        $this->note = '';
        Notification::make()->title('₱'.number_format($amount, 2).' fuel cash given')->success()->send();
    }

    public function settle(): void
    {
        $trip = $this->trip();
        abort_unless($trip && TripSorter::canSee(Auth::user(), $trip), 404);
        $cash = Fuel::cashFor($trip);
        if (! $cash || $cash->settled_at) {
            return;
        }
        $back = round((float) str_replace([',', '₱'], '', $this->returned), 2);
        $cash->update(['returned' => max(0, $back), 'settled_at' => now(), 'settled_by' => Auth::id(), 'note' => trim($this->note) ?: $cash->note]);
        $short = round($cash->given - $cash->spent() - $back, 2);
        Notification::make()->title('Fuel cash settled')
            ->body(abs($short) >= 1 ? ($short > 0 ? '₱'.number_format($short, 2).' not covered by receipts or change.' : '₱'.number_format(-$short, 2).' more than given (paid by the driver?).') : 'Receipts and change add up.')
            ->{abs($short) >= 1 ? 'warning' : 'success'}()->send();
    }

    public function undoCash(): void
    {
        $trip = $this->trip();
        abort_unless($trip && TripSorter::canSee(Auth::user(), $trip), 404);
        $cash = Fuel::cashFor($trip);
        if ($cash && ! $cash->settled_at && $cash->given_at->gt(now()->subHour())) {
            $cash->delete();
            Notification::make()->title('Fuel cash removed')->send();
        }
    }

    protected function getViewData(): array
    {
        $trip = $this->trip();
        $cash = Fuel::cashFor($trip);

        return [
            'trip' => $trip,
            'est' => Fuel::estimate($trip),
            'cash' => $cash,
            'fills' => FuelFill::where('deliverylog_id', $trip->id)->orderBy('filled_at')->get(),
            'minKm' => Fuel::cashMinKm(),
        ];
    }
}
DISPATCH_FILE_END_9

# ---------------------------------------------------------------- app/Filament/Warehouse/Pages/Fuel.php
mkdir -p 'app/Filament/Warehouse/Pages'
cat > 'app/Filament/Warehouse/Pages/Fuel.php' <<'DISPATCH_FILE_END_10'
<?php

namespace App\Filament\Warehouse\Pages;

use App\Filament\Shared\Fuel\FuelPage;

class Fuel extends FuelPage {}
DISPATCH_FILE_END_10

# ---------------------------------------------------------------- app/Filament/Warehouse/Pages/TripFuel.php
mkdir -p 'app/Filament/Warehouse/Pages'
cat > 'app/Filament/Warehouse/Pages/TripFuel.php' <<'DISPATCH_FILE_END_11'
<?php

namespace App\Filament\Warehouse\Pages;

use App\Filament\Shared\Fuel\TripFuelPage;

class TripFuel extends TripFuelPage {}
DISPATCH_FILE_END_11

# ---------------------------------------------------------------- app/Filament/Warehouse/Resources/Deliverylogs/Tables/DeliverylogsTable.php
mkdir -p 'app/Filament/Warehouse/Resources/Deliverylogs/Tables'
cat > 'app/Filament/Warehouse/Resources/Deliverylogs/Tables/DeliverylogsTable.php' <<'DISPATCH_FILE_END_12'
<?php

namespace App\Filament\Warehouse\Resources\Deliverylogs\Tables;

use App\Filament\Tables\TripBoardColumns;
use App\Filament\Warehouse\Pages\TripStops;
use App\Filament\Warehouse\Pages\TripFuel;
use App\Models\Deliverylog;
use App\Models\Logistichub;
use Filament\Actions\Action;
use Filament\Actions\ActionGroup;
use Filament\Actions\BulkActionGroup;
use Filament\Actions\DeleteBulkAction;
use Filament\Actions\EditAction;
use Filament\Notifications\Notification;
use Filament\Support\Icons\Heroicon;
use Filament\Tables\Columns\IconColumn;
use Filament\Tables\Columns\TextColumn;
use Filament\Tables\Columns\ToggleColumn;
use Filament\Tables\Enums\RecordActionsPosition;
use Filament\Tables\Filters\SelectFilter;
use Filament\Tables\Table;
use Illuminate\Database\Eloquent\Builder;
use Illuminate\Support\Facades\Auth;
use Illuminate\Support\Facades\DB;

class DeliverylogsTable
{
    public static function configure(Table $table): Table
    {
        return $table
            ->recordUrl(null)
            ->query(Deliverylog::query()->where('logistichub_id', '=', Auth::user()->logistichub_id))
            ->modifyQueryUsing(fn (Builder $query) => TripBoardColumns::withProgress($query, 'delivery'))
            ->columns([
                TextColumn::make('trip_number')
                    ->searchable(),

                TripBoardColumns::status('delivery'),

                TripBoardColumns::progress('delivery'),

                TextColumn::make('truck_id')
                    ->label('Truck')
                    ->searchable(query: function ($query, $search) {
                        return $query->whereHas('truck', function ($q) use ($search) {
                            $q->where('plate_no', 'like', "%{$search}%");
                        });
                    })
                    ->sortable()
                    ->getStateUsing(function ($record) {
                        return $record->truck ? $record->truck->plate_no : 'Truck not assigned';
                    }),
                TextColumn::make('vicheletype')
                    ->label('Vichele Type/Size')
                    ->getStateUsing(function ($record) {
                        return $record->truck ? $record->truck->category : ' ';
                    }),
                TextColumn::make('trip_day')
                    ->toggleable(isToggledHiddenByDefault: true)
                    ->numeric()
                    ->sortable(),
                TextColumn::make('logistichub.hub_name')
                    ->toggleable(isToggledHiddenByDefault: true)
                    ->label('Logistic Hub/Location'),
                TextColumn::make('Total Invoices')
                    ->label('Total Invoices')
                    ->badge()
                    ->color('danger')
                    ->getStateUsing(function ($record) {
                        return $record->tripinvoices()->count();
                    }),
                TextColumn::make('Total Loaded')
                    ->badge()
                    ->color('success')
                    ->label('Total Loaded')
                    ->getStateUsing(function ($record) {
                        return $record->tripinvoices()->whereHas('invoice', function ($query) {
                            $query->where('is_loaded', 1);
                        })->count();
                    }),
                TextColumn::make('Verified Invoices')
                    ->label('Invoices Verified')
                    ->badge()
                    ->toggleable(isToggledHiddenByDefault: true)
                    ->color('info')
                    ->getStateUsing(function ($record) {
                        return $record->tripinvoices()->whereHas('invoice', function ($query) {
                            $query->where('is_verified', 1);
                        })->count();
                        // return $record->tripinvoices->invoices->where('is_verified', 1)->count();
                    }),
                TextColumn::make('City')
                    ->label('City')
                    ->separator(',')
                    ->color('primary')
                    ->listWithLineBreaks()
                    ->limitList(3)
                    ->expandableLimitedList()
                    ->getStateUsing(function ($record) {
                        // only the distinct places, straight from the database (a trip can hold thousands of boxes)
                        return DB::table('tripinvoices')
                            ->join('invoices', 'invoices.id', '=', 'tripinvoices.invoice_id')
                            ->where('tripinvoices.deliverylog_id', $record->id)
                            ->whereNotNull('invoices.receiver_city')->where('invoices.receiver_city', '!=', '')
                            ->distinct()->orderBy('invoices.receiver_city')->pluck('invoices.receiver_city');
                        //   ->implode(" , ");
                    }),
                TextColumn::make('Province')
                    ->label('Province')
                    ->separator(',')
                    ->color('primary')
                    ->listWithLineBreaks()
                    ->limitList(3)
                    ->expandableLimitedList()
                    ->getStateUsing(function ($record) {
                        // only the distinct places, straight from the database (a trip can hold thousands of boxes)
                        return DB::table('tripinvoices')
                            ->join('invoices', 'invoices.id', '=', 'tripinvoices.invoice_id')
                            ->where('tripinvoices.deliverylog_id', $record->id)
                            ->whereNotNull('invoices.receiver_province')->where('invoices.receiver_province', '!=', '')
                            ->distinct()->orderBy('invoices.receiver_province')->pluck('invoices.receiver_province');
                        //   ->implode(" , ");
                    }),
                IconColumn::make('is_lock')
                    ->label('Lock Status')
                    ->boolean()
                    ->trueIcon(Heroicon::LockClosed)
                    ->falseIcon(Heroicon::LockOpen)
                    ->sortable()
                    ->color(function ($state) {
                        return $state ? 'danger' : 'success';
                    }),

                TextColumn::make('waybill_number')
                    ->label('Waybill No. / Container No.')
                    ->searchable()
                    ->sortable()
                    ->toggleable(isToggledHiddenByDefault: true)
                    ->sortable(),
                TextColumn::make('eta')
                    ->toggleable(isToggledHiddenByDefault: true)
                    ->label('ETA')
                    ->date()
                    ->sortable(),
                TextColumn::make('departure_date')
                    ->toggleable(isToggledHiddenByDefault: true)
                    ->date()
                    ->sortable(),
                TextColumn::make('assigned_to')
                    ->sortable()
                    ->getStateUsing(function ($record) {
                        return Logistichub::where('id', $record->assigned_to)->first()->hub_name;
                    }),
                TextColumn::make('user.full_name')
                    ->label('Created By')
                    ->toggleable(isToggledHiddenByDefault: true)
                    ->sortable(),

                ToggleColumn::make('is_active')
                    ->label('Is Active')
                    ->sortable()
                    ->toggleable(isToggledHiddenByDefault: true),
                TextColumn::make('created_at')
                    ->dateTime()
                    ->sortable()
                    ->toggleable(isToggledHiddenByDefault: true),
                TextColumn::make('updated_at')
                    ->dateTime()
                    ->sortable()
                    ->toggleable(isToggledHiddenByDefault: true),
            ])
            ->filters([
                TripBoardColumns::filter('delivery'),
                SelectFilter::make('is_lock')
                    ->label('Is Locked')
                    ->options([
                        1 => 'Yes',
                        0 => 'No',
                    ]),
                SelectFilter::make('is_active')
                    ->label('Is Active')
                    ->options([
                        1 => 'Yes',
                        0 => 'No',
                    ])->default(1),
                SelectFilter::make('assigned_to')
                    ->label('Going To')
                    ->options(Logistichub::query()->pluck('hub_name', 'id'))
                    ->searchable()
                    ->preload(),
            ])->deferFilters(false)
            ->recordActions([
                Action::make('stops')
                    ->label('Stops & loading')
                    ->icon('heroicon-o-map')
                    ->button()
                    ->color('gray')
                    ->url(fn ($record): string => TripStops::getUrl(['trip' => $record->id])),
                Action::make('fuel')
                    ->label('Fuel')
                    ->icon('heroicon-o-beaker')
                    ->button()
                    ->color('gray')
                    ->visible(fn (): bool => \App\Support\Fuel\Fuel::ready())
                    ->url(fn ($record): string => TripFuel::getUrl(['trip' => $record->id])),
                ActionGroup::make([
                    Action::make('locktrip')
                        ->requiresConfirmation()
                        ->label(function ($record) {
                            return $record->is_lock ? 'Unlock Trip' : 'Lock Trip';
                        })
                        ->color('info')
                        ->icon(function ($record) {
                            return $record->is_lock ? Heroicon::LockOpen : Heroicon::LockClosed;
                        })
                        ->hidden(function ($record) {
                            //  dd(Auth::user()->hasRole('super_admin'));
                            //  dd(Auth::user()->is_admin);
                            return Auth::user()->is_admin ? false : true;
                        })
                        ->action(function ($record) {
                            $record->update([
                                'is_lock' => ! $record->is_lock,
                            ]);

                            Notification::make()
                                ->title($record->is_lock ? 'Trip Locked Successfully' : 'Trip Unlocked Successfully')
                                ->success()
                                ->send();
                        }),
                    Action::make('releasetruct')
                        ->requiresConfirmation()
                        ->label('Released Truck')
                        ->color('info')
                        ->icon(Heroicon::Truck)
                        ->hidden(function ($record) {

                            return ! $record->is_current;
                        })
                        ->action(function ($record) {

                            $record->truck->update([
                                'is_assigned' => 0,
                            ]);
                            $record->update([
                                'is_current' => 0,
                                'is_active' => 0,
                            ]);

                            Notification::make()
                                ->title('Truck Released Successfully')
                                ->success()
                                ->send();
                        }),
                    EditAction::make()
                        ->label('Edit')
                        ->icon(Heroicon::PencilSquare)
                        ->hidden(function ($record) {
                            return $record->is_lock;
                        }),

                ]),
            ], position: RecordActionsPosition::BeforeColumns)
            ->toolbarActions([
                BulkActionGroup::make([
                    //    DeleteBulkAction::make(),

                ]),
            ]);

    }
}
DISPATCH_FILE_END_12

# ---------------------------------------------------------------- app/Http/Controllers/FuelController.php
mkdir -p 'app/Http/Controllers'
cat > 'app/Http/Controllers/FuelController.php' <<'DISPATCH_FILE_END_13'
<?php

namespace App\Http\Controllers;

use App\Support\Fuel\Fuel;
use App\Support\Fuel\FuelReport;
use App\Support\Tracking\Tracker;
use Illuminate\Http\Request;
use Symfony\Component\HttpFoundation\StreamedResponse;

/** Fuel › VAT: the month's fuel receipts as a CSV file the accountant opens in Excel. */
class FuelController extends Controller
{
    public function vatExport(Request $request): StreamedResponse
    {
        abort_unless(Fuel::ready(), 404);
        $panel = in_array($request->query('panel'), ['admin', 'warehouse', 'company'], true) ? $request->query('panel') : 'warehouse';
        $hub = Tracker::hubFor($request->user(), $panel);
        abort_if($hub === false, 403);
        $month = preg_match('/^\d{4}-\d{2}$/', (string) $request->query('month')) ? $request->query('month') : now()->format('Y-m');
        $report = new FuelReport($hub, $month);
        $fills = $report->fills()->with(['truck', 'trip'])->orderBy('filled_at')->get();

        return response()->streamDownload(function () use ($fills) {
            $out = fopen('php://output', 'w');
            fwrite($out, "\xEF\xBB\xBF"); // so Excel reads ₱ and ñ
            fputcsv($out, ['Date', 'Station', 'Station TIN', 'Invoice no.', 'Product', 'Fuel', 'Liters', 'Price per liter', 'VATable sales', 'VAT 12%', 'Total', 'Company TIN on receipt', 'Paid with', 'Truck', 'Trip'], ',', '"', '\\');
            foreach ($fills as $f) {
                fputcsv($out, [
                    $f->filled_at->format('Y-m-d H:i'), $f->station, $f->station_tin, $f->invoice_no, $f->product, $f->fuel_type,
                    $f->liters, $f->price_per_liter, $f->vatable, $f->vat, $f->total,
                    $f->buyer_tin_ok === true ? 'yes' : ($f->buyer_tin_ok === false ? 'MISSING' : ($f->total < 1000 ? 'not needed' : '')),
                    $f->paid_with, $f->truck?->plate_no, $f->trip?->trip_number,
                ], ',', '"', '\\');
            }
            fputcsv($out, ['', 'Total', '', '', '', '', $fills->sum('liters'), '', $fills->sum('vatable'), $fills->sum('vat'), $fills->sum('total')], ',', '"', '\\');
            fclose($out);
        }, "fuel-vat-{$month}.csv", ['Content-Type' => 'text/csv; charset=UTF-8']);
    }
}
DISPATCH_FILE_END_13

# ---------------------------------------------------------------- app/Models/Fuel/FuelCash.php
mkdir -p 'app/Models/Fuel'
cat > 'app/Models/Fuel/FuelCash.php' <<'DISPATCH_FILE_END_14'
<?php

namespace App\Models\Fuel;

use App\Models\Deliverylog;
use App\Models\User;
use Illuminate\Database\Eloquent\Model;
use Illuminate\Database\Eloquent\Relations\BelongsTo;

/** Fuel cash given for a trip, and how it was settled (change returned). */
class FuelCash extends Model
{
    protected $table = 'fuel_cash';

    protected $guarded = [];

    protected function casts(): array
    {
        return [
            'km' => 'float', 'km_per_liter' => 'float', 'price' => 'float', 'estimate' => 'float', 'given' => 'float',
            'returned' => 'float', 'given_at' => 'datetime', 'settled_at' => 'datetime',
        ];
    }

    public function trip(): BelongsTo
    {
        return $this->belongsTo(Deliverylog::class, 'deliverylog_id');
    }

    public function givenBy(): BelongsTo
    {
        return $this->belongsTo(User::class, 'given_by');
    }

    public function settledBy(): BelongsTo
    {
        return $this->belongsTo(User::class, 'settled_by');
    }

    /** Cash receipts for this trip. */
    public function spent(): float
    {
        return (float) FuelFill::where('deliverylog_id', $this->deliverylog_id)->where('paid_with', 'cash')->sum('total');
    }

    public function left(): float
    {
        return round($this->given - $this->spent(), 2);
    }
}
DISPATCH_FILE_END_14

# ---------------------------------------------------------------- app/Models/Fuel/FuelFill.php
mkdir -p 'app/Models/Fuel'
cat > 'app/Models/Fuel/FuelFill.php' <<'DISPATCH_FILE_END_15'
<?php

namespace App\Models\Fuel;

use App\Models\Deliverylog;
use App\Models\Truck;
use App\Models\User;
use Illuminate\Database\Eloquent\Model;
use Illuminate\Database\Eloquent\Relations\BelongsTo;
use Illuminate\Support\Facades\Storage;

/** One fill: what the receipt says, how it was paid, the odometer, and the checks. */
class FuelFill extends Model
{
    protected $table = 'fuel_fills';

    protected $guarded = [];

    protected function casts(): array
    {
        return [
            'filled_at' => 'datetime', 'liters' => 'float', 'price_per_liter' => 'float', 'total' => 'float', 'vatable' => 'float',
            'vat' => 'float', 'km_per_liter' => 'float', 'lat' => 'float', 'lng' => 'float', 'buyer_tin_ok' => 'boolean',
            'gps_ok' => 'boolean', 'ai_read' => 'boolean', 'ai_data' => 'array',
        ];
    }

    public function truck(): BelongsTo
    {
        return $this->belongsTo(Truck::class);
    }

    public function trip(): BelongsTo
    {
        return $this->belongsTo(Deliverylog::class, 'deliverylog_id');
    }

    public function driver(): BelongsTo
    {
        return $this->belongsTo(User::class, 'driver_id');
    }

    public function receiptUrl(): ?string
    {
        return $this->receipt_path ? Storage::disk('public')->url($this->receipt_path) : null;
    }

    public function odometerUrl(): ?string
    {
        return $this->odometer_path ? Storage::disk('public')->url($this->odometer_path) : null;
    }
}
DISPATCH_FILE_END_15

# ---------------------------------------------------------------- app/Models/Fuel/FuelStatement.php
mkdir -p 'app/Models/Fuel'
cat > 'app/Models/Fuel/FuelStatement.php' <<'DISPATCH_FILE_END_16'
<?php

namespace App\Models\Fuel;

use Illuminate\Database\Eloquent\Model;
use Illuminate\Database\Eloquent\Relations\HasMany;

/** A fuel card statement file that was imported. */
class FuelStatement extends Model
{
    protected $table = 'fuel_statements';

    protected $guarded = [];

    protected function casts(): array
    {
        return ['from' => 'date', 'to' => 'date'];
    }

    public function lines(): HasMany
    {
        return $this->hasMany(FuelStatementLine::class);
    }
}
DISPATCH_FILE_END_16

# ---------------------------------------------------------------- app/Models/Fuel/FuelStatementLine.php
mkdir -p 'app/Models/Fuel'
cat > 'app/Models/Fuel/FuelStatementLine.php' <<'DISPATCH_FILE_END_17'
<?php

namespace App\Models\Fuel;

use App\Models\Truck;
use Illuminate\Database\Eloquent\Model;
use Illuminate\Database\Eloquent\Relations\BelongsTo;

/** One charge on a fuel card statement, matched to a fill from the Driver app. */
class FuelStatementLine extends Model
{
    protected $table = 'fuel_statement_lines';

    protected $guarded = [];

    protected function casts(): array
    {
        return ['charged_at' => 'datetime', 'liters' => 'float', 'amount' => 'float'];
    }

    public function statement(): BelongsTo
    {
        return $this->belongsTo(FuelStatement::class, 'fuel_statement_id');
    }

    public function truck(): BelongsTo
    {
        return $this->belongsTo(Truck::class);
    }

    public function fuelFill(): BelongsTo
    {
        return $this->belongsTo(FuelFill::class, 'fuel_fill_id');
    }
}
DISPATCH_FILE_END_17

# ---------------------------------------------------------------- app/Support/Ai/AiFeatures.php
mkdir -p 'app/Support/Ai'
cat > 'app/Support/Ai/AiFeatures.php' <<'DISPATCH_FILE_END_18'
<?php

namespace App\Support\Ai;

/** The AI helpers that can be switched on in Admin → Settings → AI. */
class AiFeatures
{
    /** key => [title, what it does, who uses it, needs the API key] */
    public const ALL = [
        'trips' => ['AI trip helper', 'Drafts trips from the ready boxes and your free trucks: grouped by province, city and barangay, priority and tried-before boxes first, the same receiver always together. You check and press Create; trip numbers are given as usual.', 'Admin · Warehouse · Partner hub', true],
        'aging' => ['Box aging', 'How long each box has waited since unload, at each stage. Late boxes in the bell, a morning summary, limits suggested from your history, and why boxes are late (AI).', 'Admin · Warehouse · Partner hub', false],
        'photo_check' => ['AI photo check', 'Looks at every box photo (scan and proof of delivery) and lists the ones that look damaged, wet, opened or blurry.', 'Admin · Warehouse · Partner hub', true],
        'ask' => ['Ask the system', 'Staff ask about boxes, containers, trips and drivers in plain words. It can only read.', 'Admin · Warehouse · Partner hub', true],
        'manifest' => ['Read a manifest', 'Reads a consolidator manifest (PDF, Excel, CSV or a photo) into a container\'s invoices, and fixes messy addresses.', 'Admin · Warehouse', true],
        'risky' => ['Risky deliveries', 'Lists boxes on trips that will likely fail, writes a text for the receiver, and warns the driver.', 'Admin · Partner hub · Driver app', true],
        'alerts' => ['Alerts', 'Checks every 15 minutes for unusual things: too-fast deliveries, boxes on two trips, boxes stuck, many failures in one barangay.', 'Admin · Warehouse · Partner hub', false],
        'issues' => ['Issue helper', 'On an Invoice Issue: sums it up, suggests the next step and writes the email to the consolidator with the photos.', 'Admin', true],
        'insights' => ['Insights', 'Forecast of boxes for the next 8 weeks and a weekly report for each partner hub.', 'Admin · Warehouse · Partner hub', true],
        'voice' => ['Driver voice note', 'In the Driver app, "Can\'t deliver": the driver says what happened and the reason and note are filled in.', 'Driver app', true],
        'sms_writer' => ['SMS writer', 'In Settings → SMS: make a text fit in 1 SMS, friendlier, or translate it to Tagalog or Bisaya. Also turns the driver\'s note ("wala tao, balik bukas") into a clear "not delivered" text.', 'Admin', true],
        'alert_explain' => ['Truck alerts explained', 'Each truck alert gets a short note: what probably happened (lunch, no signal, wrong turn), how worried to be, and what to do.', 'Admin · Warehouse · Partner hub', true],
        'day_summary' => ['End-of-day truck summary', 'After work: the day in short, and for each truck what went well and what to look at. Optional daily email.', 'Admin · Warehouse · Partner hub', true],
        'addresses' => ['AI address cleaning', 'Before a trip is put on the map, messy addresses are fixed ("purok 3 near chapel, Lapu2" → "Purok 3, Pusok, Lapu-Lapu City, Cebu") so more stops are found. Settings → Maps & routes.', 'Admin · Warehouse · Partner hub', true],
        'fuel_receipts' => ['Read fuel receipts', 'In the Driver app, reads the fuel receipt photo (station, diesel or gasoline, liters, price, total, VAT, TIN) and the odometer photo, so the driver does not type them.', 'Driver app · Fuel', true],
        'help_ask' => ['Help answers', 'In the Help guide, staff and drivers ask in their own words (English, Tagalog or Taglish) and get a short answer taken only from the guides, with the right guide to open.', 'Admin · Warehouse · Partner hub · Scan app · Driver app', true],
        'customer_chat' => ['Customer chat', 'A public page where receivers type their box number and ask questions. Answers come from tracking; anything else goes to staff.', 'Receivers · Admin · Partner hub', true],
    ];

    public static function title(string $key): string
    {
        return self::ALL[$key][0] ?? $key;
    }
}
DISPATCH_FILE_END_18

# ---------------------------------------------------------------- app/Support/Fuel/Fuel.php
mkdir -p 'app/Support/Fuel'
cat > 'app/Support/Fuel/Fuel.php' <<'DISPATCH_FILE_END_19'
<?php

namespace App\Support\Fuel;

use App\Models\AppSetting;
use App\Models\Deliverylog;
use App\Models\Fuel\FuelCash;
use App\Models\Fuel\FuelFill;
use App\Models\Maps\TripRoute;
use App\Models\Tracking\TruckPosition;
use App\Models\Truck;
use App\Models\Truckcrew;
use App\Models\User;
use App\Support\Maps\RoutePlanner;
use Illuminate\Support\Carbon;
use Illuminate\Support\Collection;
use Illuminate\Support\Facades\Schema;
use Illuminate\Support\Str;

/**
 * Fuel: settings, diesel or gasoline, this week's price from the receipts, km per liter,
 * the cash estimate for a trip, and saving a fill with its checks.
 */
class Fuel
{
    public const TYPES = ['diesel' => 'Diesel', 'gasoline' => 'Gasoline'];

    public const PROVIDERS = ['petron' => 'Petron Fleet Card', 'shell' => 'Shell Fleet Card', 'caltex' => 'Caltex StarCard', 'seaoil' => 'SEAOIL PriceLOCQ', 'other' => 'Other'];

    /** Product names on receipts. Diesel words are checked first ("V-Power Diesel" is diesel). */
    protected const DIESEL = ['diesel', 'biodiesel', 'turbo d', 'diesel max', 'techron d', 'fuelsave d', 'ado', 'gasoil', 'gas oil'];

    protected const GASOLINE = ['gasoline', 'unleaded', 'premium', 'xcs', 'blaze', 'xtra', 'v-power', 'vpower', 'silver', 'platinum', 'extreme', 'super', 'regular', 'ron', 'gas 9', '91', '95', '97', '100', 'fuelsave g', 'sprint'];

    // ------------------------------------------------------------------ settings

    public static function setting(string $key, mixed $default = null): mixed
    {
        $v = AppSetting::get('fuel.'.$key, $default);

        return is_string($v) && str_starts_with($v, '{') ? (json_decode($v, true) ?? $v) : $v;
    }

    public static function put(string $key, mixed $value): void
    {
        AppSetting::put('fuel.'.$key, is_array($value) ? json_encode($value) : $value);
    }

    public static function companyTin(): string
    {
        return (string) static::setting('company_tin', '');
    }

    public static function cashMinKm(): int
    {
        return (int) static::setting('cash_min_km', 150);
    }

    public static function bufferPct(): int
    {
        return (int) static::setting('buffer_pct', 10);
    }

    public static function defaultKml(): float
    {
        return (float) static::setting('default_kml', 7);
    }

    public static function ready(): bool
    {
        return Schema::hasTable('fuel_fills');
    }

    // ------------------------------------------------------------------ diesel or gasoline

    /** "Diesel Max" → diesel, "XCS" → gasoline, unknown → null. */
    public static function typeOf(?string $product): ?string
    {
        $p = ' '.Str::lower(Str::ascii((string) $product)).' ';
        if (trim($p) === '') {
            return null;
        }
        foreach (static::DIESEL as $w) {
            if (str_contains($p, $w)) {
                return 'diesel';
            }
        }
        foreach (static::GASOLINE as $w) {
            if (preg_match('/(^|[^a-z0-9])'.preg_quote($w, '/').'([^a-z0-9]|$)/', $p)) {
                return 'gasoline';
            }
        }

        return null;
    }

    // ------------------------------------------------------------------ price

    /** The start of the price week: prices change on Tuesday. */
    public static function weekStart(?Carbon $day = null): Carbon
    {
        $day = ($day ?? now())->copy()->startOfDay();

        return $day->isTuesday() ? $day : $day->previous(Carbon::TUESDAY);
    }

    /**
     * This week's price per liter: the admin's price for this week, else the middle price of the
     * receipts since Tuesday, else last week's receipts.
     *
     * @return array{price: ?float, from: string, count: int}
     */
    public static function price(string $type, ?Carbon $day = null): array
    {
        $week = static::weekStart($day);
        $set = static::setting("price.{$type}");
        if (is_array($set) && ($set['week'] ?? null) === $week->toDateString() && ($set['price'] ?? 0) > 0) {
            return ['price' => (float) $set['price'], 'from' => 'set by the office', 'count' => 0];
        }
        foreach ([[$week, $week->copy()->addWeek()], [$week->copy()->subWeek(), $week]] as $i => [$from, $to]) {
            $prices = FuelFill::where('fuel_type', $type)->whereNotNull('price_per_liter')
                ->where('filled_at', '>=', $from)->where('filled_at', '<', $to)->pluck('price_per_liter');
            if ($prices->isNotEmpty()) {
                return ['price' => static::median($prices), 'from' => ($i ? 'last week\'s ' : '').$prices->count().' '.Str::plural('receipt', $prices->count()), 'count' => $prices->count()];
            }
        }

        return ['price' => null, 'from' => 'no receipts yet', 'count' => 0];
    }

    /** @return list<array{week: Carbon, diesel: ?float, gasoline: ?float}> */
    public static function priceWeeks(int $weeks = 6): array
    {
        $out = [];
        $start = static::weekStart();
        for ($i = 0; $i < $weeks; $i++) {
            $w = $start->copy()->subWeeks($i);
            $row = ['week' => $w];
            foreach (array_keys(static::TYPES) as $type) {
                $p = FuelFill::where('fuel_type', $type)->whereNotNull('price_per_liter')
                    ->where('filled_at', '>=', $w)->where('filled_at', '<', $w->copy()->addWeek())->pluck('price_per_liter');
                $row[$type] = $p->isNotEmpty() ? static::median($p) : null;
            }
            $out[] = $row;
        }

        return $out;
    }

    public static function median(Collection $values): float
    {
        $v = $values->map(fn ($x) => (float) $x)->sort()->values();
        $n = $v->count();

        return round($n % 2 ? $v[intdiv($n, 2)] : ($v[$n / 2 - 1] + $v[$n / 2]) / 2, 2);
    }

    // ------------------------------------------------------------------ km per liter

    /** The truck's usual km per liter (last 5 fills with an odometer), or null. */
    public static function kml(int $truckId, int $last = 5, int $skip = 0): ?float
    {
        $fills = FuelFill::where('truck_id', $truckId)->whereNotNull('km_since')->where('km_since', '>', 0)
            ->orderByDesc('filled_at')->skip($skip)->take($last)->get(['km_since', 'liters']);
        $l = $fills->sum('liters');

        return $fills->isNotEmpty() && $l > 0 ? round($fills->sum('km_since') / $l, 1) : null;
    }

    // ------------------------------------------------------------------ cash for a trip

    /**
     * Cash for a trip: trip km ÷ the truck's km per liter × this week's price + buffer,
     * rounded up to ₱10. Pieces are null when not known yet.
     *
     * @return array{km: ?float, kml: float, kmlFrom: string, type: string, price: ?float, priceFrom: string, buffer: int, liters: ?float, amount: ?float, short: bool}
     */
    public static function estimate(Deliverylog $trip): array
    {
        $truck = $trip->truck;
        $km = TripRoute::where('deliverylog_id', $trip->id)->value('km');
        $kml = $truck ? static::kml($truck->id) : null;
        $type = $truck?->fuel_type ?: 'diesel';
        $p = static::price($type);
        $buffer = static::bufferPct();
        $liters = $km ? round($km / ($kml ?: static::defaultKml()), 1) : null;
        $amount = $liters && $p['price'] ? ceil(round($liters * $p['price'] * (1 + $buffer / 100) / 10, 4)) * 10 : null;

        return [
            'km' => $km ? (float) $km : null, 'kml' => $kml ?: static::defaultKml(), 'kmlFrom' => $kml ? 'from its last fills' : 'usual for trucks (no fills yet)',
            'type' => $type, 'price' => $p['price'], 'priceFrom' => $p['from'], 'buffer' => $buffer, 'liters' => $liters, 'amount' => $amount,
            'short' => $km !== null && $km < static::cashMinKm(),
        ];
    }

    public static function cashFor(?Deliverylog $trip): ?FuelCash
    {
        return $trip ? FuelCash::where('deliverylog_id', $trip->id)->first() : null;
    }

    // ------------------------------------------------------------------ the driver's truck

    /** The truck the driver is on: today's trip, or the truck they are crew of. */
    public static function truckFor(User $driver, ?Deliverylog $trip): ?Truck
    {
        if ($trip?->truck) {
            return $trip->truck;
        }
        $id = Truckcrew::where('crew', $driver->id)->latest('id')->value('truck_id');

        return $id ? Truck::find($id) : null;
    }

    // ------------------------------------------------------------------ saving a fill

    /**
     * Save a fill and work out the checks: km since the last fill, km per liter, price per
     * liter when missing, VAT sums, the company TIN, and the truck GPS at that time.
     */
    public static function save(array $data, Truck $truck, ?User $driver, ?Deliverylog $trip): FuelFill
    {
        $at = Carbon::parse($data['filled_at'] ?? now());
        $liters = round((float) $data['liters'], 2);
        $total = round((float) $data['total'], 2);
        $price = (float) ($data['price_per_liter'] ?? 0) ?: ($liters > 0 ? round($total / $liters, 2) : null);
        $odo = isset($data['odometer']) && $data['odometer'] !== '' ? (int) $data['odometer'] : null;

        $prev = $odo ? FuelFill::where('truck_id', $truck->id)->whereNotNull('odometer')->where('filled_at', '<', $at)->orderByDesc('filled_at')->first() : null;
        $kmSince = $prev && $odo > $prev->odometer && $odo - $prev->odometer < 5000 ? $odo - $prev->odometer : null;

        [$gpsOk, $gpsM, $lat, $lng] = static::gpsCheck($truck->id, $at, $data['lat'] ?? null, $data['lng'] ?? null);

        $vat = isset($data['vat']) && $data['vat'] !== '' ? round((float) $data['vat'], 2) : null;
        $vatable = isset($data['vatable']) && $data['vatable'] !== '' ? round((float) $data['vatable'], 2) : ($vat !== null ? round($total - $vat, 2) : null);

        return FuelFill::create([
            'truck_id' => $truck->id, 'deliverylog_id' => $trip?->id, 'driver_id' => $driver?->id,
            'logistichub_id' => $truck->logistichub_id ?: $trip?->logistichub_id, 'filled_at' => $at,
            'station' => $data['station'] ?? null, 'product' => $data['product'] ?? null,
            'fuel_type' => $data['fuel_type'] ?? static::typeOf($data['product'] ?? null),
            'liters' => $liters, 'price_per_liter' => $price, 'total' => $total, 'vatable' => $vatable, 'vat' => $vat,
            'station_tin' => $data['station_tin'] ?? null, 'invoice_no' => $data['invoice_no'] ?? null,
            'buyer_tin_ok' => static::buyerTinOk($data['buyer_tin'] ?? null, $total, $data['buyer_tin_ok'] ?? null),
            'paid_with' => ($data['paid_with'] ?? 'card') === 'cash' ? 'cash' : 'card', 'card_last4' => $data['card_last4'] ?? null,
            'odometer' => $odo, 'km_since' => $kmSince, 'km_per_liter' => $kmSince && $liters > 0 ? round($kmSince / $liters, 2) : null,
            'receipt_path' => $data['receipt_path'] ?? null, 'odometer_path' => $data['odometer_path'] ?? null,
            'lat' => $lat, 'lng' => $lng, 'gps_ok' => $gpsOk, 'gps_distance_m' => $gpsM,
            'ai_read' => (bool) ($data['ai_read'] ?? false), 'ai_data' => $data['ai_data'] ?? null,
        ]);
    }

    /**
     * Is the company's TIN on the receipt? Only asked from ₱1,000 (below that the buyer's
     * details are not needed). Null when not known (no company TIN set, or nothing read).
     */
    public static function buyerTinOk(?string $buyerTin, float $total, mixed $told = null): ?bool
    {
        if ($told !== null && $told !== '') {
            return (bool) $told;
        }
        $mine = preg_replace('/\D/', '', static::companyTin());
        if ($total < 1000 || strlen($mine) < 9) {
            return null;
        }
        $theirs = preg_replace('/\D/', '', (string) $buyerTin);

        return $theirs !== '' && str_starts_with($theirs, substr($mine, 0, 9));
    }

    /**
     * Was the phone where the truck was? Compares the phone's location (when the driver
     * allowed it) with the truck GPS within 15 minutes of the fill.
     *
     * @return array{0: ?bool, 1: ?int, 2: ?float, 3: ?float}
     */
    public static function gpsCheck(int $truckId, Carbon $at, mixed $lat, mixed $lng): array
    {
        $pos = TruckPosition::where('truck_id', $truckId)
            ->whereBetween('recorded_at', [$at->copy()->subMinutes(15), $at->copy()->addMinutes(15)])
            ->get()->sortBy(fn ($p) => abs($p->recorded_at->diffInSeconds($at)))->first();
        $lat = is_numeric($lat) ? (float) $lat : null;
        $lng = is_numeric($lng) ? (float) $lng : null;
        if (! $pos) {
            return [null, null, $lat, $lng];
        }
        if ($lat === null || $lng === null) {
            return [null, null, $pos->lat, $pos->lng];
        }
        $m = (int) round(RoutePlanner::km([$lat, $lng], [$pos->lat, $pos->lng]) * 1000);

        return [$m <= 1000, $m, $lat, $lng];
    }
}
DISPATCH_FILE_END_19

# ---------------------------------------------------------------- app/Support/Fuel/FuelReader.php
mkdir -p 'app/Support/Fuel'
cat > 'app/Support/Fuel/FuelReader.php' <<'DISPATCH_FILE_END_20'
<?php

namespace App\Support\Fuel;

use App\Support\Ai\Ai;
use Illuminate\Support\Str;

/**
 * Reads a fuel receipt photo (station, product, liters, price, total, VAT, TIN, invoice no.,
 * card) and an odometer photo with the AI. Off, or nothing read: the driver types it.
 */
class FuelReader
{
    public static function on(): bool
    {
        try {
            return Ai::enabled('fuel_receipts');
        } catch (\Throwable) {
            return false;
        }
    }

    /** @return array<string, mixed> only the fields that were read */
    public static function receipt(string $path): array
    {
        if (! static::on() || ! ($image = Ai::image('public', $path))) {
            return [];
        }
        $system = 'You read fuel station receipts (sales invoices) from the Philippines: Petron, Shell, Caltex, SEAOIL, Phoenix, Unioil, Cleanfuel and others. '
            .'Read only what is printed; use null for anything you cannot read. Numbers without commas or peso signs. '
            .'fuel_type: "diesel" or "gasoline" from the product name (Diesel Max, Turbo Diesel, V-Power Diesel, FuelSave Diesel → diesel; XCS, Blaze, Xtra Advance, V-Power, Silver, Platinum, Unleaded, Extreme 95/97 → gasoline). '
            .'vatable = "VATable sales"/"VAT sales"; vat = "VAT amount"/"12% VAT". station_tin = the seller TIN at the top. buyer_name and buyer_tin = the customer name and TIN written or printed for the buyer, if any. '
            .'card_last4 = last 4 digits of a fleet/credit card if shown. date as YYYY-MM-DD and time as HH:MM (24h) if shown. '
            .'Answer as {"station": str, "product": str, "fuel_type": str, "liters": num, "price_per_liter": num, "total": num, "vatable": num, "vat": num, '
            .'"station_tin": str, "invoice_no": str, "buyer_name": str, "buyer_tin": str, "card_last4": str, "odometer": int, "date": str, "time": str}.';
        try {
            $out = Ai::json('fuel_receipts', $system, [$image, ['type' => 'text', 'text' => 'Read this receipt.']], 'fast', 500);
        } catch (\Throwable) {
            return [];
        }

        $num = fn ($v) => is_numeric(str_replace(',', '', (string) $v)) ? round((float) str_replace(',', '', (string) $v), 2) : null;
        $str = fn ($v, $n = 120) => is_string($v) && trim($v) !== '' && strtolower(trim($v)) !== 'null' ? Str::limit(trim($v), $n, '') : null;
        $read = [
            'station' => $str($out['station'] ?? null), 'product' => $str($out['product'] ?? null, 80),
            'liters' => $num($out['liters'] ?? null), 'price_per_liter' => $num($out['price_per_liter'] ?? null), 'total' => $num($out['total'] ?? null),
            'vatable' => $num($out['vatable'] ?? null), 'vat' => $num($out['vat'] ?? null),
            'station_tin' => $str($out['station_tin'] ?? null, 30), 'invoice_no' => $str($out['invoice_no'] ?? null, 40),
            'buyer_tin' => $str($out['buyer_tin'] ?? null, 30), 'card_last4' => $str($out['card_last4'] ?? null, 8),
            'odometer' => is_numeric($out['odometer'] ?? null) ? (int) $out['odometer'] : null,
        ];
        $type = Fuel::typeOf($read['product']) ?? (in_array($out['fuel_type'] ?? null, ['diesel', 'gasoline'], true) ? $out['fuel_type'] : null);
        $read['fuel_type'] = $type;
        if (! empty($out['date']) && preg_match('/^\d{4}-\d{2}-\d{2}$/', (string) $out['date'])) {
            $when = $out['date'].' '.(preg_match('/^\d{1,2}:\d{2}$/', (string) ($out['time'] ?? '')) ? $out['time'] : '00:00');
            try {
                $at = \Illuminate\Support\Carbon::parse($when);
                if ($at->isBetween(now()->subDays(3), now()->addHour())) {
                    $read['filled_at'] = $at->format('Y-m-d H:i');
                }
            } catch (\Throwable) {
            }
        }
        // the numbers must agree: liters × price ≈ total
        if ($read['liters'] && $read['total'] && ! $read['price_per_liter']) {
            $read['price_per_liter'] = round($read['total'] / $read['liters'], 2);
        }

        return array_filter($read, fn ($v) => $v !== null);
    }

    public static function odometer(string $path): ?int
    {
        if (! static::on() || ! ($image = Ai::image('public', $path))) {
            return null;
        }
        try {
            $out = Ai::json('fuel_receipts', 'You read the odometer (total km) on a truck dashboard photo. Ignore the trip meter. Answer as {"odometer": int or null}.',
                [$image, ['type' => 'text', 'text' => 'Read the odometer.']], 'fast', 60);
        } catch (\Throwable) {
            return null;
        }

        return is_numeric($out['odometer'] ?? null) && (int) $out['odometer'] > 0 ? (int) $out['odometer'] : null;
    }

    /** Do the receipt numbers agree? liters × price ≈ total, VATable + VAT ≈ total. */
    public static function problems(array $f): array
    {
        $p = [];
        $l = (float) ($f['liters'] ?? 0);
        $pr = (float) ($f['price_per_liter'] ?? 0);
        $t = (float) ($f['total'] ?? 0);
        if ($l > 0 && $pr > 0 && $t > 0 && abs($l * $pr - $t) > max(2, $t * 0.01)) {
            $p[] = 'Liters × price is ₱'.number_format($l * $pr, 2).', not the total ₱'.number_format($t, 2).'.';
        }
        $v = $f['vat'] ?? null;
        $va = $f['vatable'] ?? null;
        if ($v !== null && $v !== '' && $va !== null && $va !== '' && $t > 0 && abs((float) $v + (float) $va - $t) > max(1, $t * 0.01)) {
            $p[] = 'VATable + VAT is not the total.';
        }

        return $p;
    }
}
DISPATCH_FILE_END_20

# ---------------------------------------------------------------- app/Support/Fuel/FuelReport.php
mkdir -p 'app/Support/Fuel'
cat > 'app/Support/Fuel/FuelReport.php' <<'DISPATCH_FILE_END_21'
<?php

namespace App\Support\Fuel;

use App\Models\Fuel\FuelCash;
use App\Models\Fuel\FuelFill;
use App\Models\Fuel\FuelStatementLine;
use App\Models\Truck;
use App\Models\Tripinvoice;
use Illuminate\Database\Eloquent\Builder;
use Illuminate\Support\Carbon;
use Illuminate\Support\Collection;

/**
 * What the Fuel page shows for a month, for the trucks a person may see:
 * totals, each truck, alerts and VAT.
 */
class FuelReport
{
    public Carbon $from;

    public Carbon $to;

    /** @param  int|false|null  $hub  null = all hubs (Admin), false = none */
    public function __construct(public int|false|null $hub, ?string $month = null)
    {
        $this->from = $month ? Carbon::parse($month.'-01')->startOfMonth() : now()->startOfMonth();
        $this->to = $this->from->copy()->endOfMonth();
    }

    /** @return Collection<int, Truck> */
    public function trucks(): Collection
    {
        if ($this->hub === false) {
            return collect();
        }

        return Truck::query()->when($this->hub !== null, fn ($q) => $q->where('logistichub_id', $this->hub))
            ->orderBy('plate_no')->get();
    }

    public function fills(): Builder
    {
        return FuelFill::query()->whereIn('truck_id', $this->trucks()->pluck('id'))
            ->whereBetween('filled_at', [$this->from, $this->to]);
    }

    public function totals(): array
    {
        $f = $this->fills()->get();
        $spent = $f->sum('total');
        $cash = $f->where('paid_with', 'cash')->sum('total');
        $vat = $f->sum('vat');
        $noTin = $f->filter(fn ($x) => $x->buyer_tin_ok === false)->sum('vat');
        $km = $f->sum('km_since');
        $kmLiters = $f->whereNotNull('km_since')->sum('liters');
        $boxes = Tripinvoice::query()->where('is_delivered', true)->whereBetween('delivered_at', [$this->from, $this->to])
            ->whereIn('deliverylog_id', \App\Models\Deliverylog::query()->whereIn('truck_id', $this->trucks()->pluck('id'))->select('id'))->count();

        return [
            'spent' => $spent, 'liters' => $f->sum('liters'), 'fills' => $f->count(),
            'diesel' => $f->where('fuel_type', 'diesel')->sum('liters'), 'gasoline' => $f->where('fuel_type', 'gasoline')->sum('liters'),
            'cash' => $cash, 'cashPct' => $spent > 0 ? (int) round($cash / $spent * 100) : 0,
            'vat' => $vat, 'vatNoTin' => $noTin, 'kml' => $kmLiters > 0 ? round($km / $kmLiters, 1) : null,
            'boxes' => $boxes, 'perBox' => $boxes > 0 ? round($spent / $boxes, 2) : null,
            'unsettled' => FuelCash::whereNull('settled_at')->whereIn('truck_id', $this->trucks()->pluck('id'))->count(),
        ];
    }

    /** One row per truck with fills this month. */
    public function perTruck(): Collection
    {
        $fills = $this->fills()->orderBy('filled_at')->get()->groupBy('truck_id');

        return $this->trucks()->map(function (Truck $t) use ($fills) {
            $f = $fills->get($t->id, collect());
            $withKm = $f->whereNotNull('km_since');
            $kml = $withKm->sum('liters') > 0 ? round($withKm->sum('km_since') / $withKm->sum('liters'), 1) : null;
            $recent = Fuel::kml($t->id, 3);
            $before = Fuel::kml($t->id, 10, 3);
            $change = $recent && $before ? (int) round(($recent - $before) / $before * 100) : null;
            $last = $f->last();

            return [
                'truck' => $t, 'liters' => $f->sum('liters'), 'spent' => $f->sum('total'), 'fills' => $f->count(), 'kml' => $kml,
                'change' => $change, 'perKm' => $withKm->sum('km_since') > 0 ? round($withKm->sum('total') / $withKm->sum('km_since'), 2) : null,
                'last' => $last ? $last->filled_at->format('M j').' · '.($last->station ?: '—') : null,
            ];
        })->filter(fn ($r) => $r['fills'] > 0 || $this->hub !== null)->values();
    }

    /**
     * What to look at, newest first.
     *
     * @return list<array{kind: string, icon: string, title: string, text: string, when: string, at: Carbon, fill: ?int}>
     */
    public function alerts(): array
    {
        $out = [];
        $trucks = $this->trucks()->keyBy('id');
        $fills = $this->fills()->with('truck')->orderBy('filled_at')->get();
        $peso = fn ($n) => '₱'.number_format((float) $n, 2);
        $add = function (string $kind, string $icon, string $title, string $text, Carbon $at, ?int $fill = null) use (&$out) {
            $out[] = ['kind' => $kind, 'icon' => $icon, 'title' => $title, 'text' => $text, 'when' => $at->format('M j · g:i A'), 'at' => $at, 'fill' => $fill];
        };
        $prices = [];

        foreach ($fills as $f) {
            $t = $f->truck;
            $plate = $t?->plate_no ?? 'Truck';
            if ($t?->fuel_type && $f->fuel_type && $t->fuel_type !== $f->fuel_type) {
                $add('red', '⛽', "{$plate} ({$t->fuel_type}) · {$f->fuel_type} on the receipt",
                    trim(($f->station ?: '').' · '.rtrim(rtrim(number_format($f->liters, 2), '0'), '.').' L '.($f->product ?: '').' · '.$peso($f->total).' · paid '.$f->paid_with, ' ·').'. Wrong fuel, or another vehicle?', $f->filled_at, $f->id);
            }
            if ($t?->tank_liters && $f->liters > $t->tank_liters * 1.02) {
                $add('red', '🛢️', "{$plate} · {$f->liters} L in one fill", "The tank holds {$t->tank_liters} L. ".($f->station ? "At {$f->station}." : ''), $f->filled_at, $f->id);
            }
            if ($f->gps_ok === false) {
                $add('red', '📍', "{$plate} · fill added away from the truck", 'The phone was '.number_format($f->gps_distance_m / 1000, 1).' km from the truck GPS when this fill was added.', $f->filled_at, $f->id);
            }
            if ($f->price_per_liter && $f->fuel_type) {
                $week = Fuel::weekStart($f->filled_at)->toDateString();
                $prices[$f->fuel_type][$week] ??= Fuel::price($f->fuel_type, $f->filled_at)['price'];
                $usual = $prices[$f->fuel_type][$week];
                if ($usual && abs($f->price_per_liter - $usual) > $usual * 0.1) {
                    $add('amber', '💵', "{$plate} · ₱".number_format($f->price_per_liter, 2)."/L on a {$f->paid_with} receipt", 'This week\'s '.$f->fuel_type.' price is ₱'.number_format($usual, 2).'/L. '.($f->station ? "At {$f->station}." : ''), $f->filled_at, $f->id);
                }
            }
            if ($f->total >= 1000 && $f->vat !== null && $f->vat == 0.0) {
                $add('amber', '🧾', "{$plate} · no VAT on the receipt", ($f->station ?: 'The station').' · '.$peso($f->total).'. A non-VAT station, or not a proper receipt.', $f->filled_at, $f->id);
            }
        }

        // two fills close together
        foreach ($fills->groupBy('truck_id') as $list) {
            $prev = null;
            foreach ($list as $f) {
                if ($prev && $prev->filled_at->diffInMinutes($f->filled_at) < 120) {
                    $add('amber', '⏱️', ($f->truck?->plate_no ?? 'Truck').' · two fills in '.(int) $prev->filled_at->diffInMinutes($f->filled_at).' minutes',
                        rtrim(rtrim(number_format($prev->liters, 2), '0'), '.').' L then '.rtrim(rtrim(number_format($f->liters, 2), '0'), '.').' L.', $f->filled_at, $f->id);
                }
                $prev = $f;
            }
        }

        // km per liter dropping
        foreach ($trucks as $t) {
            $recent = Fuel::kml($t->id, 3);
            $before = Fuel::kml($t->id, 10, 3);
            if ($recent && $before && $recent < $before * 0.85) {
                $add('amber', '📉', "{$t->plate_no} · km per liter down ".(int) round((1 - $recent / $before) * 100).'%',
                    "{$recent} km/L the last 3 fills, normally {$before}. Check tires, engine, or the fills.", now(), null);
            }
        }

        // the company TIN missing on receipts of ₱1,000 and up
        $noTin = $fills->filter(fn ($f) => $f->buyer_tin_ok === false);
        if ($noTin->isNotEmpty()) {
            $add('amber', '🧾', $noTin->count().' '.str('receipt')->plural($noTin->count()).' without your company TIN',
                'VAT of '.$peso($noTin->sum('vat')).' cannot be claimed. Ask the drivers to show the company TIN card to the cashier.', $noTin->last()->filled_at, null);
        }

        // card statement lines
        $lines = FuelStatementLine::query()->whereIn('truck_id', $trucks->keys())->whereBetween('charged_at', [$this->from, $this->to])
            ->whereIn('status', ['no_fill', 'liters_differ'])->with('truck')->get();
        $noFill = $lines->where('status', 'no_fill');
        if ($noFill->isNotEmpty()) {
            $add('amber', '💳', $noFill->count().' card '.str('charge')->plural($noFill->count()).' with no fill in the Driver app',
                $noFill->take(3)->map(fn ($l) => ($l->truck?->plate_no ?? '?').' '.($l->charged_at?->format('M j g:i A') ?? '').' '.$peso($l->amount))->join(' · '), $noFill->max('charged_at'), null);
        }
        foreach ($lines->where('status', 'liters_differ') as $l) {
            $add('amber', '⚖️', ($l->truck?->plate_no ?? 'Truck').' · liters differ from the card', 'Card: '.$l->liters.' L · Driver app: '.($l->fuelFill?->liters ?? '—').' L · '.($l->station ?: ''), $l->charged_at ?? now(), $l->fuel_fill_id);
        }

        // fuel cash not settled 2 days after it was given
        FuelCash::whereNull('settled_at')->whereIn('truck_id', $trucks->keys())->where('given_at', '<', now()->subDays(2))->with('trip')
            ->get()->each(fn ($c) => $add('amber', '💵', 'Fuel cash not settled · trip '.($c->trip?->trip_number ?? $c->deliverylog_id),
                $peso($c->given).' given '.$c->given_at->diffForHumans().'. Cash receipts so far: '.$peso($c->spent()).'.', $c->given_at, null));

        usort($out, fn ($a, $b) => [$a['kind'] === 'red' ? 0 : 1, -$a['at']->getTimestamp()] <=> [$b['kind'] === 'red' ? 0 : 1, -$b['at']->getTimestamp()]);

        return $out;
    }
}
DISPATCH_FILE_END_21

# ---------------------------------------------------------------- app/Support/Fuel/FuelStatements.php
mkdir -p 'app/Support/Fuel'
cat > 'app/Support/Fuel/FuelStatements.php' <<'DISPATCH_FILE_END_22'
<?php

namespace App\Support\Fuel;

use App\Models\Fuel\FuelFill;
use App\Models\Fuel\FuelStatement;
use App\Models\Fuel\FuelStatementLine;
use App\Models\Truck;
use Illuminate\Support\Carbon;
use Illuminate\Support\Str;

/**
 * Import a fuel card statement (CSV from Petron, Shell Fleet Hub, Caltex StarCard Online,
 * SEAOIL PriceLOCQ, or any other) and match each charge to a fill from the Driver app:
 * same truck, within 3 hours, and the same liters (3% either way).
 */
class FuelStatements
{
    /** Words in the column titles, for each thing we need. The first match wins. */
    protected const COLUMNS = [
        'datetime' => ['transaction date time', 'date/time', 'date time', 'datetime', 'txn date time', 'trans date time'],
        'date' => ['transaction date', 'trans date', 'txn date', 'date'],
        'time' => ['transaction time', 'trans time', 'txn time', 'time'],
        'card' => ['card number', 'card no', 'card #', 'pan', 'card'],
        'plate' => ['plate number', 'plate no', 'vehicle plate', 'plate', 'vehicle', 'registration'],
        'station' => ['station name', 'merchant name', 'site name', 'station', 'merchant', 'site', 'location'],
        'product' => ['product name', 'product description', 'product', 'item', 'fuel type', 'description'],
        'liters' => ['liters', 'litres', 'volume', 'quantity', 'qty', 'ltrs', 'ltr'],
        'amount' => ['net amount', 'total amount', 'amount', 'total', 'value', 'gross'],
        'odometer' => ['odometer', 'odo', 'mileage', 'km reading'],
    ];

    public const STATUS = [
        'matched' => 'Matched',
        'liters_differ' => 'Liters differ',
        'no_fill' => 'No fill in the app',
        'no_truck' => 'Card or plate not known',
    ];

    /** Read a CSV file and save the statement with each line matched. */
    public static function import(string $file, string $provider, ?int $userId, ?int $hub, string $name): FuelStatement
    {
        $rows = static::read($file);
        $statement = FuelStatement::create([
            'provider' => array_key_exists($provider, Fuel::PROVIDERS) ? $provider : 'other', 'filename' => Str::limit($name, 180, ''),
            'logistichub_id' => $hub, 'uploaded_by' => $userId, 'lines' => 0,
        ]);
        $trucks = Truck::query()->when($hub, fn ($q) => $q->where('logistichub_id', $hub))->get();
        $byCard = $trucks->filter(fn ($t) => $t->fuel_card_last4)->keyBy(fn ($t) => substr(preg_replace('/\D/', '', $t->fuel_card_last4), -4));
        $byPlate = $trucks->keyBy(fn ($t) => static::plate($t->plate_no));
        $used = [];
        $dates = [];

        foreach ($rows as $r) {
            if (! $r['amount'] && ! $r['liters']) {
                continue;
            }
            $card4 = $r['card'] ? substr(preg_replace('/\D/', '', $r['card']), -4) : null;
            $truck = ($card4 ? $byCard->get($card4) : null) ?? ($r['plate'] ? $byPlate->get(static::plate($r['plate'])) : null);
            [$status, $fillId] = $truck ? static::match($truck->id, $r['at'], $r['liters'], $used) : ['no_truck', null];
            if ($fillId) {
                $used[$fillId] = true;
            }
            FuelStatementLine::create([
                'fuel_statement_id' => $statement->id, 'truck_id' => $truck?->id, 'fuel_fill_id' => $fillId, 'charged_at' => $r['at'],
                'card' => $r['card'] ? '****'.$card4 : null, 'plate' => $r['plate'], 'station' => $r['station'], 'product' => $r['product'],
                'fuel_type' => Fuel::typeOf($r['product']), 'liters' => $r['liters'], 'amount' => $r['amount'], 'odometer' => $r['odometer'],
                'status' => $status,
            ]);
            if ($r['at']) {
                $dates[] = $r['at'];
            }
        }
        $statement->update([
            'lines' => $statement->lines()->count(),
            'from' => $dates ? min($dates)->toDateString() : null, 'to' => $dates ? max($dates)->toDateString() : null,
        ]);

        return $statement;
    }

    /** @return array{0: string, 1: ?int} */
    protected static function match(int $truckId, ?Carbon $at, ?float $liters, array $used): array
    {
        if (! $at) {
            return ['no_fill', null];
        }
        $fill = FuelFill::where('truck_id', $truckId)->whereBetween('filled_at', [$at->copy()->subHours(3), $at->copy()->addHours(3)])
            ->whereNotIn('id', array_keys($used))->get()
            ->sortBy(fn ($f) => [abs(($f->liters ?? 0) - ($liters ?? 0)) > max(1, ($liters ?? 0) * 0.03) ? 1 : 0, abs($f->filled_at->diffInSeconds($at))])
            ->first();
        if (! $fill) {
            return ['no_fill', null];
        }
        $same = $liters === null || abs($fill->liters - $liters) <= max(1, $liters * 0.03);

        return [$same ? 'matched' : 'liters_differ', $fill->id];
    }

    public static function plate(?string $p): string
    {
        return strtoupper(preg_replace('/[^A-Za-z0-9]/', '', (string) $p));
    }

    /**
     * The rows of a CSV statement, with the columns found by their titles.
     *
     * @return list<array{at: ?Carbon, card: ?string, plate: ?string, station: ?string, product: ?string, liters: ?float, amount: ?float, odometer: ?int}>
     */
    public static function read(string $file): array
    {
        $fh = fopen($file, 'r');
        if (! $fh) {
            return [];
        }
        $first = (string) fgets($fh);
        rewind($fh);
        $sep = substr_count($first, ';') > substr_count($first, ',') ? ';' : (substr_count($first, "\t") > substr_count($first, ',') ? "\t" : ',');

        $map = null;
        $rows = [];
        while (($cells = fgetcsv($fh, 0, $sep, '"', '\\')) !== false) {
            $cells = array_map(fn ($c) => trim((string) preg_replace('/^\xEF\xBB\xBF/', '', (string) $c)), $cells);
            if ($map === null) {
                $map = static::header($cells);
                if (count(array_intersect(array_keys($map), ['amount', 'liters'])) === 0) {
                    $map = null; // not the title row yet (statements often start with account details)
                }

                continue;
            }
            $get = fn ($k) => isset($map[$k]) && isset($cells[$map[$k]]) && $cells[$map[$k]] !== '' ? $cells[$map[$k]] : null;
            $num = fn ($v) => $v !== null && is_numeric($n = str_replace([',', '₱', 'PHP', ' '], '', $v)) ? (float) $n : null;
            $rows[] = [
                'at' => static::when($get('datetime') ?? trim(($get('date') ?? '').' '.($get('time') ?? ''))),
                'card' => $get('card'), 'plate' => $get('plate'), 'station' => $get('station'), 'product' => $get('product'),
                'liters' => $num($get('liters')), 'amount' => $num($get('amount')),
                'odometer' => ($o = $num($get('odometer'))) ? (int) $o : null,
            ];
        }
        fclose($fh);

        return $rows;
    }

    /** column => index */
    protected static function header(array $cells): array
    {
        $titles = array_map(fn ($c) => trim(preg_replace('/\s+/', ' ', Str::lower(str_replace(['_', '.'], ' ', $c)))), $cells);
        $map = [];
        foreach (static::COLUMNS as $key => $words) {
            foreach ($words as $w) {
                foreach ($titles as $i => $t) {
                    if (! in_array($i, $map, true) && ($t === $w || str_contains($t, $w))) {
                        $map[$key] = $i;

                        continue 3;
                    }
                }
            }
        }

        return $map;
    }

    protected static function when(?string $v): ?Carbon
    {
        $v = trim((string) $v);
        if ($v === '') {
            return null;
        }
        foreach (['m/d/Y H:i:s', 'm/d/Y H:i', 'm/d/Y g:i A', 'm/d/Y g:i:s A', 'Y-m-d H:i:s', 'Y-m-d H:i', 'd-M-Y H:i', 'd/m/Y H:i', 'm/d/Y', 'Y-m-d'] as $f) {
            try {
                $d = Carbon::createFromFormat($f, $v);
                if ($d !== false && $d->format($f) === $v) {
                    return $d;
                }
            } catch (\Throwable) {
            }
        }
        try {
            return Carbon::parse($v);
        } catch (\Throwable) {
            return null;
        }
    }
}
DISPATCH_FILE_END_22

# ---------------------------------------------------------------- app/Support/Help/DefaultGuides.php
mkdir -p 'app/Support/Help'
cat > 'app/Support/Help/DefaultGuides.php' <<'DISPATCH_FILE_END_23'
<?php

namespace App\Support\Help;

/**
 * The guides the system starts with, in English and Tagalog. They are copied into
 * the help_guides table once (missing slugs only), then Admin → Help guides can edit them.
 *
 * Apps: admin, warehouse, company (partner hub), scan (Scan app), driver (Driver app).
 * "pages" are route names without the panel part ("pages.scaninvoice", "resources.deliverylogs.*"):
 * the "?" on those pages opens this guide. "links" are where "Do it now" goes, per app.
 */
class DefaultGuides
{
    /** topic => [icon, English, Tagalog] */
    public const TOPICS = [
        'boxes' => ['📦', 'Boxes & inventory', 'Mga box at inventory'],
        'trips' => ['🚚', 'Trips & loading', 'Mga trip at pag-load'],
        'trucks' => ['📍', 'Trucks & tracking', 'Mga truck at tracking'],
        'receivers' => ['💬', 'Receivers & SMS', 'Mga receiver at SMS'],
        'apps' => ['📱', 'Phone apps', 'Mga app sa phone'],
        'settings' => ['⚙️', 'Settings & AI', 'Settings at AI'],
    ];

    public static function all(): array
    {
        $s = fn (string $te, string $xe, string $tt, string $xt, ?string $img = null) => ['title_en' => $te, 'text_en' => $xe, 'title_tl' => $tt, 'text_tl' => $xt, 'image' => $img];
        $p = fn (string $qe, string $ae, string $qt, string $at) => ['q_en' => $qe, 'a_en' => $ae, 'q_tl' => $qt, 'a_tl' => $at];
        $img = fn (string $name) => 'images/help/'.$name.'.jpg';

        return [
            // ───────────────────────────── boxes ─────────────────────────────
            [
                'slug' => 'unload-container', 'topic' => 'boxes', 'icon' => '📥', 'apps' => ['admin', 'warehouse', 'scan'],
                'title_en' => 'Unload a container', 'title_tl' => 'Mag-unload ng container',
                'summary_en' => 'Scan every box as it comes off the container. Each scanned box is checked and counted in the inventory.',
                'summary_tl' => 'I-scan ang bawat box pagbaba sa container. Ang na-scan na box ay checked at bilang na sa inventory.',
                'when_en' => 'A container arrived at the warehouse and the boxes are being taken off.',
                'when_tl' => 'Dumating ang container sa bodega at ibinababa na ang mga box.',
                'steps' => [
                    $s('Open Unload', 'In the Scan app tap Unload container. On a computer open Unload Container in the menu.', 'Buksan ang Unload', 'Sa Scan app, pindutin ang Unload container. Sa computer, buksan ang Unload Container sa menu.', $img('scan-home')),
                    $s('Choose the container', 'Pick the container number from the list. Only containers that are not finished are shown.', 'Piliin ang container', 'Piliin ang container number sa listahan. Ang lalabas lang ay mga container na hindi pa tapos.', $img('unload')),
                    $s('Scan each box', 'Scan the barcode on every box. Green means checked. Red tells you why (wrong container, already scanned, not on the list).', 'I-scan ang bawat box', 'I-scan ang barcode ng bawat box. Green ay okay. Kapag red, sasabihin kung bakit (ibang container, na-scan na, wala sa listahan).'),
                    $s('Take a photo if asked', 'If box photos are switched on, take the photo and mark damaged or wet boxes.', 'Mag-picture kung hinihingi', 'Kung naka-on ang box photos, mag-picture at markahan kung sira o basa ang box.'),
                    $s('Finish', 'When all boxes are scanned, press Finish. The boxes left over are listed as missing.', 'Tapusin', 'Kapag na-scan na lahat, pindutin ang Finish. Ang mga hindi na-scan ay ililista na missing.'),
                ],
                'result_en' => 'The boxes are now in the inventory and can be put on a trip.',
                'result_tl' => 'Nasa inventory na ang mga box at puwede nang ilagay sa trip.',
                'problems' => [
                    $p('The box is not on the list', 'It may be on another container or not on the manifest. Put it aside and tell the office; it shows in Unmanifested.', 'Wala sa listahan ang box', 'Baka nasa ibang container o wala sa manifest. Itabi muna at sabihan ang office; lalabas ito sa Unmanifested.'),
                    $p('It says already scanned', 'That box was scanned before. Nothing to do, go to the next box.', 'Sabi ay na-scan na', 'Na-scan na dati ang box. Wala nang gagawin, sunod na box na.'),
                ],
                'pages' => ['pages.scaninvoice', 'pages.unloadedcontainer', 'resources.containers.*', 'resources.unmanifesteds.*'],
                'links' => ['admin' => 'pages.scaninvoice', 'warehouse' => 'pages.unloadedcontainer'],
                'related' => ['inventory-count', 'box-photos', 'search-box'], 'sort' => 10,
            ],
            [
                'slug' => 'inventory-count', 'topic' => 'boxes', 'icon' => '🔢', 'apps' => ['admin', 'warehouse', 'company'],
                'title_en' => 'How the inventory counts', 'title_tl' => 'Paano binibilang ang inventory',
                'summary_en' => 'A box is counted when it was scanned at Unload, is not delivered, and is not on a truck.',
                'summary_tl' => 'Bilang ang box kapag na-scan sa Unload, hindi pa na-deliver, at wala sa truck.',
                'when_en' => 'The number in Inventories looks too high or too low, or one box is missing from it.',
                'when_tl' => 'Mukhang sobra o kulang ang bilang sa Inventories, o may box na wala roon.',
                'steps' => [
                    $s('It goes in at Unload', 'A box is added when it is scanned at Unload Container (or received at Warehouse unload).', 'Pumapasok sa Unload', 'Nadadagdag ang box kapag na-scan sa Unload Container (o natanggap sa Warehouse unload).'),
                    $s('It goes out at Load Truck', 'When the box is scanned onto a truck it leaves the inventory, even before it is delivered.', 'Lumalabas sa Load Truck', 'Kapag na-scan na pasakay sa truck, bawas na ito sa inventory, kahit hindi pa na-deliver.'),
                    $s('It comes back at Return Boxes', 'A box that was not delivered is counted again only after it is scanned in Return Boxes.', 'Bumabalik sa Return Boxes', 'Ang box na hindi na-deliver ay bibilang ulit lang kapag na-scan sa Return Boxes.'),
                    $s('Delivered boxes never count', 'Once delivered, a box is gone from the inventory for good.', 'Ang na-deliver ay hindi na bilang', 'Kapag na-deliver na, wala na ito sa inventory.'),
                ],
                'result_en' => 'Inventory = scanned in, minus loaded on a truck, plus returned, minus delivered.',
                'result_tl' => 'Inventory = na-scan papasok, bawas ang naka-load sa truck, dagdag ang na-return, bawas ang na-deliver.',
                'problems' => [
                    $p('A box was not delivered but is not in inventory', 'It is still "on the truck". Scan it in Return Boxes and it is counted again.', 'Hindi na-deliver pero wala sa inventory', 'Naka-"on the truck" pa ito. I-scan sa Return Boxes at bibilang na ulit.'),
                    $p('A box is in inventory but not in the warehouse', 'It was never scanned onto the truck. Search the box to see its last scan.', 'Nasa inventory pero wala sa bodega', 'Hindi ito na-scan sa Load Truck. Hanapin ang box para makita ang huling scan.'),
                ],
                'pages' => ['resources.inventories.*', 'pages.dashboard'],
                'links' => ['admin' => 'resources.inventories.index', 'warehouse' => 'resources.inventories.index'],
                'related' => ['return-boxes', 'unload-container', 'search-box'], 'sort' => 20,
            ],
            [
                'slug' => 'search-box', 'topic' => 'boxes', 'icon' => '🔍', 'apps' => ['admin', 'warehouse', 'company'],
                'title_en' => 'Find a box and see where it is', 'title_tl' => 'Hanapin ang box at kung nasaan ito',
                'summary_en' => 'Type the invoice number to see every scan of the box: unload, trip, truck, delivered or not, with photos.',
                'summary_tl' => 'I-type ang invoice number para makita ang lahat ng scan ng box: unload, trip, truck, na-deliver o hindi, may photos.',
                'when_en' => 'A receiver or a consolidator asks where a box is.',
                'when_tl' => 'May receiver o consolidator na nagtatanong kung nasaan ang box.',
                'steps' => [
                    $s('Open the search', 'Open Search Invoice (Partner hub: Track a box).', 'Buksan ang search', 'Buksan ang Search Invoice (sa Partner hub: Track a box).'),
                    $s('Type the invoice number', 'Type all or part of the number and press Enter.', 'I-type ang invoice number', 'I-type ang buo o bahagi ng number at pindutin ang Enter.'),
                    $s('Read the history', 'The newest step is on top: which trip and truck, who scanned it and when, and the delivery photos.', 'Basahin ang history', 'Nasa itaas ang pinakabago: anong trip at truck, sino ang nag-scan at kailan, at ang delivery photos.'),
                ],
                'result_en' => 'You know where the box is and who had it last.',
                'result_tl' => 'Alam mo na kung nasaan ang box at sino ang huling may hawak.',
                'problems' => [
                    $p('Nothing found', 'Check the number on the label. If it was never unloaded it is not in the system yet; check Unmanifested.', 'Walang lumabas', 'Tingnan ulit ang number sa label. Kung hindi pa na-unload, wala pa sa system; tingnan ang Unmanifested.'),
                ],
                'pages' => ['resources.searchinvs.*', 'pages.track'],
                'links' => ['admin' => 'resources.searchinvs.index', 'warehouse' => 'resources.searchinvs.index', 'company' => 'pages.track'],
                'related' => ['inventory-count', 'box-photos'], 'sort' => 30,
            ],
            [
                'slug' => 'box-photos', 'topic' => 'boxes', 'icon' => '📷', 'apps' => ['admin', 'warehouse', 'company', 'scan'],
                'title_en' => 'Box photos', 'title_tl' => 'Mga photo ng box',
                'summary_en' => 'Photos taken at unload, loading, return and delivery are kept with the box. See them all in Box Photos.',
                'summary_tl' => 'Ang photos sa unload, loading, return at delivery ay nakatabi sa box. Makikita lahat sa Box Photos.',
                'when_en' => 'You need proof a box was fine, damaged, or delivered.',
                'when_tl' => 'Kailangan mo ng patunay na okay, sira, o na-deliver ang box.',
                'steps' => [
                    $s('Choose when photos are needed', 'Admin → Settings → Box photos: switch photos on for unload, load, return, and pick "every box" or "only damaged".', 'Piliin kung kailan kailangan ng photo', 'Admin → Settings → Box photos: i-on ang photos sa unload, load, return, at piliin kung "lahat ng box" o "sira lang".'),
                    $s('Take the photo while scanning', 'After the scan, the Scan app asks for the photo and the condition (good, damaged, wet, opened).', 'Mag-picture habang nag-i-scan', 'Pagkatapos ng scan, hihingi ang Scan app ng photo at kondisyon (okay, sira, basa, bukas).'),
                    $s('Look at them later', 'Open Box Photos, search the invoice, and open a photo to see it big.', 'Tingnan mamaya', 'Buksan ang Box Photos, hanapin ang invoice, at buksan ang photo para lumaki.'),
                ],
                'result_en' => 'Every photo is kept with the box and its scan.',
                'result_tl' => 'Nakatabi ang bawat photo kasama ng box at scan nito.',
                'problems' => [
                    $p('The photo did not upload', 'Weak signal. Tap the photo button again; the scan itself is already saved.', 'Hindi na-upload ang photo', 'Mahina ang signal. Pindutin ulit ang photo; naka-save na ang scan mismo.'),
                ],
                'pages' => ['pages.box-photos', 'pages.box-photo-settings'],
                'links' => ['admin' => 'pages.box-photos', 'warehouse' => 'pages.box-photos', 'company' => 'pages.box-photos'],
                'related' => ['unload-container', 'driver-deliver'], 'sort' => 40,
            ],
            [
                'slug' => 'return-boxes', 'topic' => 'boxes', 'icon' => '↩️', 'apps' => ['admin', 'warehouse', 'company', 'scan'],
                'title_en' => 'Return a box that was not delivered', 'title_tl' => 'I-return ang box na hindi na-deliver',
                'summary_en' => 'When the truck comes back, scan the boxes that were not delivered. They go back to the inventory.',
                'summary_tl' => 'Pagbalik ng truck, i-scan ang mga box na hindi na-deliver. Babalik sila sa inventory.',
                'when_en' => 'A truck is back with boxes the driver could not deliver.',
                'when_tl' => 'Bumalik ang truck na may mga box na hindi na-deliver ng driver.',
                'steps' => [
                    $s('Open Return Boxes', 'In the Scan app tap Return boxes. On a computer open Return Boxes (Warehouse: Hub Return Boxes).', 'Buksan ang Return Boxes', 'Sa Scan app, pindutin ang Return boxes. Sa computer, buksan ang Return Boxes (Warehouse: Hub Return Boxes).'),
                    $s('Choose the trip', 'Pick the trip the box was on. The list shows how many boxes are still out.', 'Piliin ang trip', 'Piliin ang trip kung saan nakasakay ang box. Makikita kung ilan pa ang nasa labas.', $img('return')),
                    $s('Scan each box', 'Scan every box that came back. Green means it is back in the inventory.', 'I-scan ang bawat box', 'I-scan ang bawat box na bumalik. Green ay balik na sa inventory.'),
                    $s('Finish', 'Press Finish. The returned boxes can be planned on a new trip.', 'Tapusin', 'Pindutin ang Finish. Puwede nang ilagay ulit sa bagong trip ang mga box.'),
                ],
                'result_en' => 'The boxes are counted in the inventory again, marked "returned".',
                'result_tl' => 'Bilang na ulit sa inventory ang mga box, may markang "returned".',
                'problems' => [
                    $p('It says the box was delivered', 'The driver pressed Deliver. If it was a mistake, the driver can Undo within 30 minutes; after that ask the office.', 'Sabi ay na-deliver na', 'Pinindot ng driver ang Deliver. Kung mali, puwedeng mag-Undo ang driver sa loob ng 30 minuto; pagkatapos noon, sa office na.'),
                ],
                'pages' => ['pages.return-boxes', 'pages.hub-return-boxes'],
                'links' => ['admin' => 'pages.return-boxes', 'warehouse' => 'pages.hub-return-boxes', 'company' => 'pages.return-boxes'],
                'related' => ['inventory-count', 'not-delivered-list', 'driver-cant-deliver'], 'sort' => 50,
            ],

            // ───────────────────────────── trips ─────────────────────────────
            [
                'slug' => 'create-trip', 'topic' => 'trips', 'icon' => '🗓️', 'apps' => ['admin', 'warehouse', 'company'],
                'title_en' => 'Make a delivery trip', 'title_tl' => 'Gumawa ng delivery trip',
                'summary_en' => 'A trip is one truck going out on one day. Make the trip, then add the boxes by area.',
                'summary_tl' => 'Ang trip ay isang truck na lalabas sa isang araw. Gawin ang trip, tapos idagdag ang mga box ayon sa area.',
                'when_en' => 'Boxes are in the inventory and a truck is free.',
                'when_tl' => 'May mga box sa inventory at may bakanteng truck.',
                'steps' => [
                    $s('New trip', 'Open Delivery Log and press New. Choose the truck and the date it leaves.', 'Bagong trip', 'Buksan ang Delivery Log at pindutin ang New. Piliin ang truck at petsa ng alis.', $img('create-trip')),
                    $s('Add the boxes', 'Open Assign invoices, choose the trip, pick the areas (province, city, barangay) and add the boxes.', 'Idagdag ang mga box', 'Buksan ang Assign invoices, piliin ang trip, piliin ang mga area (probinsya, siyudad, barangay) at idagdag ang mga box.'),
                    $s('Check the order', 'Press Stops & loading on the trip. The system puts the stops in order and says which boxes go to the front or back.', 'Tingnan ang order', 'Pindutin ang Stops & loading sa trip. Iaayos ng system ang mga stop at sasabihin kung aling box ang sa harap o likod.'),
                    $s('Load the truck', 'Scan the boxes in Load Truck. See the guide "Load a truck".', 'I-load ang truck', 'I-scan ang mga box sa Load Truck. Tingnan ang gabay na "Mag-load ng truck".'),
                ],
                'result_en' => 'The trip has its boxes and is ready to load. Partner hubs can also use Incoming boxes → Create trip.',
                'result_tl' => 'May mga box na ang trip at handa nang i-load. Sa Partner hub, puwede rin sa Incoming boxes → Create trip.',
                'problems' => [
                    $p('The truck is not in the list', 'The truck is already on an active trip, or it is switched off. Check Trucks.', 'Wala ang truck sa listahan', 'May active trip pa ang truck, o naka-off ito. Tingnan sa Trucks.'),
                    $p('Too many boxes for one truck', 'Make a second trip, or let the AI trip helper split them.', 'Sobra ang box para sa isang truck', 'Gumawa ng ikalawang trip, o hayaan ang AI trip helper na hatiin.'),
                ],
                'pages' => ['resources.deliverylogs.*', 'resources.whdeliverylogs.*', 'pages.routeinvoice', 'pages.hubroute', 'pages.incoming-boxes'],
                'links' => ['admin' => 'resources.deliverylogs.index', 'warehouse' => 'resources.deliverylogs.index', 'company' => 'pages.incoming-boxes'],
                'related' => ['ai-trip-helper', 'stops-loading', 'load-truck'], 'sort' => 10,
            ],
            [
                'slug' => 'ai-trip-helper', 'topic' => 'trips', 'icon' => '✨', 'apps' => ['admin', 'warehouse', 'company'],
                'title_en' => 'Let the AI draft the trips', 'title_tl' => 'Hayaan ang AI na gumawa ng draft ng trips',
                'summary_en' => 'The AI groups the ready boxes by area into your free trucks. You check, change, and press Create.',
                'summary_tl' => 'Igugrupo ng AI ang mga handang box ayon sa area sa mga bakanteng truck. Ikaw ang titingin, magbabago, at pipindot ng Create.',
                'when_en' => 'Many boxes are waiting and you want a quick first plan.',
                'when_tl' => 'Maraming box ang naghihintay at gusto mo ng mabilis na unang plano.',
                'steps' => [
                    $s('Open AI trip helper', 'Open AI trip helper in the menu. It must be switched on in Settings → AI.', 'Buksan ang AI trip helper', 'Buksan ang AI trip helper sa menu. Dapat naka-on ito sa Settings → AI.'),
                    $s('Press Draft trips', 'The AI keeps the same receiver together and puts priority and tried-before boxes first.', 'Pindutin ang Draft trips', 'Pinagsasama ng AI ang parehong receiver at inuuna ang priority at mga box na sinubukan na dati.'),
                    $s('Check and create', 'Move boxes or trucks if needed, then press Create. Trip numbers are given as usual.', 'Tingnan at i-create', 'Ilipat ang box o truck kung kailangan, tapos pindutin ang Create. Bibigyan ng trip number gaya ng dati.'),
                ],
                'result_en' => 'Real trips are made from the draft. Nothing is made until you press Create.',
                'result_tl' => 'Gagawa ng totoong trip mula sa draft. Walang mangyayari hangga\'t hindi pinipindot ang Create.',
                'problems' => [
                    $p('The page says AI is off', 'An admin switches it on in Settings → AI (an API key is needed).', 'Sabi ay naka-off ang AI', 'Ang admin ang mag-o-on sa Settings → AI (kailangan ng API key).'),
                ],
                'pages' => ['pages.ai-trips'],
                'links' => ['admin' => 'pages.ai-trips', 'warehouse' => 'pages.ai-trips', 'company' => 'pages.ai-trips'],
                'related' => ['create-trip', 'ai-settings'], 'sort' => 20,
            ],
            [
                'slug' => 'stops-loading', 'topic' => 'trips', 'icon' => '🧭', 'apps' => ['admin', 'warehouse', 'company'],
                'title_en' => 'Stops in order and the loading list', 'title_tl' => 'Pagkakasunod ng stops at ang loading list',
                'summary_en' => 'Each trip gets its stops in driving order and a loading list: the last stops go in FRONT (by the cab) first, the first stops go in the BACK (at the door) last.',
                'summary_tl' => 'Ang bawat trip ay may stops na naka-ayos sa daan at loading list: ang huling stops ay unang ipapasok sa HARAP (sa may cab), ang unang stops ay huli sa LIKOD (sa may pinto).',
                'when_en' => 'Before loading, so the first stops are easy to reach at the door.',
                'when_tl' => 'Bago mag-load, para madaling abutin sa pinto ang mga unang stop.',
                'steps' => [
                    $s('Open Stops & loading', 'In Delivery Log press Stops & loading on the trip row.', 'Buksan ang Stops & loading', 'Sa Delivery Log, pindutin ang Stops & loading sa row ng trip.', $img('stops')),
                    $s('Check the map', 'The stops are numbered on the map. Drag a stop to change the order, or press Sort again.', 'Tingnan ang mapa', 'May number ang mga stop sa mapa. I-drag para baguhin ang order, o pindutin ulit ang Sort.'),
                    $s('Print the loading list', 'Press Print loading list. It is grouped FRONT → MIDDLE → BACK, in the order to put the boxes in.', 'I-print ang loading list', 'Pindutin ang Print loading list. Naka-grupo ito HARAP → GITNA → LIKOD, ayon sa pagkakasunod ng pagpasok.'),
                ],
                'result_en' => 'The crew loads in the right order and the driver sees the same stops in the Driver app.',
                'result_tl' => 'Tama ang pagkaka-load ng crew at pareho ang stops na makikita ng driver sa Driver app.',
                'problems' => [
                    $p('A stop has no pin on the map', 'The address was not found. Fix it on the stop, or switch on AI address cleaning in Settings → Maps & routes.', 'Walang pin ang stop sa mapa', 'Hindi nahanap ang address. Ayusin sa stop, o i-on ang AI address cleaning sa Settings → Maps & routes.'),
                ],
                'pages' => ['pages.trip-stops', 'pages.maps-routes'],
                'links' => ['admin' => 'resources.deliverylogs.index', 'warehouse' => 'resources.deliverylogs.index', 'company' => 'resources.deliverylogs.index'],
                'related' => ['load-truck', 'maps-routes', 'driver-navigate'], 'sort' => 30,
            ],
            [
                'slug' => 'load-truck', 'topic' => 'trips', 'icon' => '🚛', 'apps' => ['admin', 'warehouse', 'company', 'scan'],
                'title_en' => 'Load a truck', 'title_tl' => 'Mag-load ng truck',
                'summary_en' => 'Scan each box as it goes on the truck. The screen says which spot it goes in: FRONT, MIDDLE or BACK.',
                'summary_tl' => 'I-scan ang bawat box pagsakay sa truck. Sasabihin ng screen kung saan ilalagay: HARAP, GITNA o LIKOD.',
                'when_en' => 'The trip has its boxes and the truck is at the loading bay.',
                'when_tl' => 'May mga box na ang trip at nasa loading bay na ang truck.',
                'steps' => [
                    $s('Open Load truck', 'In the Scan app tap Load truck (Partner hub: Hub load). On a computer open Load Truck.', 'Buksan ang Load truck', 'Sa Scan app, pindutin ang Load truck (Partner hub: Hub load). Sa computer, buksan ang Load Truck.'),
                    $s('Choose the trip', 'Pick the trip. You see how many boxes are left to load.', 'Piliin ang trip', 'Piliin ang trip. Makikita kung ilan pa ang hindi naka-load.', $img('load')),
                    $s('Scan and place', 'Scan each box and put it where the screen says. "Load next" shows which boxes to bring now.', 'I-scan at ilagay', 'I-scan ang bawat box at ilagay kung saan sinasabi ng screen. Ang "Load next" ay nagsasabi kung aling box ang susunod.'),
                    $s('Finish', 'Press Finish when all boxes are on. The driver can start the trip.', 'Tapusin', 'Pindutin ang Finish kapag nakasakay na lahat. Puwede nang umalis ang driver.'),
                ],
                'result_en' => 'The boxes are on the truck, out of the inventory, and in the Driver app.',
                'result_tl' => 'Nasa truck na ang mga box, bawas na sa inventory, at nasa Driver app na.',
                'problems' => [
                    $p('It says the box is on another trip', 'The box belongs to a different trip. Put it aside or ask the office to move it.', 'Sabi ay nasa ibang trip ang box', 'Sa ibang trip ang box. Itabi muna o ipalipat sa office.'),
                    $p('It says too early', 'That box is for an early stop and goes near the door, so load the boxes for later stops first. Press Load it anyway if you are sure.', 'Sabi ay masyadong maaga', 'Para sa maagang stop ang box at ilalagay sa may pinto, kaya unahin ang mga box ng huling stops. Pindutin ang Load it anyway kung sigurado ka.'),
                ],
                'pages' => ['pages.scanload', 'pages.whloaded', 'pages.hubloaded', 'pages.load-truck'],
                'links' => ['admin' => 'pages.scanload', 'warehouse' => 'pages.hubloaded', 'company' => 'pages.load-truck'],
                'related' => ['stops-loading', 'create-trip', 'inventory-count'], 'sort' => 40,
            ],
            [
                'slug' => 'warehouse-transfer', 'topic' => 'trips', 'icon' => '🔁', 'apps' => ['warehouse', 'scan'],
                'title_en' => 'Move boxes to another warehouse', 'title_tl' => 'Ilipat ang mga box sa ibang bodega',
                'summary_en' => 'Load the boxes at Warehouse load here, and the other warehouse scans them at Warehouse unload.',
                'summary_tl' => 'I-load ang mga box sa Warehouse load dito, at i-scan sila ng kabilang bodega sa Warehouse unload.',
                'when_en' => 'Boxes must go to another warehouse before delivery.',
                'when_tl' => 'Kailangang dalhin muna ang mga box sa ibang bodega bago i-deliver.',
                'steps' => [
                    $s('Make the transfer trip', 'Open WH Delivery Logs and press New. Choose the truck and the warehouse it goes to.', 'Gumawa ng transfer trip', 'Buksan ang WH Delivery Logs at pindutin ang New. Piliin ang truck at ang bodegang pupuntahan.'),
                    $s('Load', 'In the Scan app tap Warehouse load, choose the trip, scan each box.', 'Mag-load', 'Sa Scan app, pindutin ang Warehouse load, piliin ang trip, i-scan ang bawat box.'),
                    $s('Receive', 'At the other warehouse tap Warehouse unload, choose the arriving trip, scan each box.', 'Tanggapin', 'Sa kabilang bodega, pindutin ang Warehouse unload, piliin ang dumarating na trip, i-scan ang bawat box.'),
                ],
                'result_en' => 'The boxes are in the other warehouse\'s inventory.',
                'result_tl' => 'Nasa inventory na ng kabilang bodega ang mga box.',
                'problems' => [
                    $p('The boxes are in neither inventory', 'They were loaded but not yet received. They count again once scanned at Warehouse unload.', 'Wala sa dalawang inventory ang box', 'Na-load pero hindi pa natatanggap. Bibilang ulit kapag na-scan sa Warehouse unload.'),
                ],
                'pages' => ['pages.whloaded', 'pages.whunloaded', 'resources.whdeliverylogs.*'],
                'links' => ['warehouse' => 'pages.whloaded'],
                'related' => ['inventory-count', 'load-truck'], 'sort' => 50,
            ],
            [
                'slug' => 'hub-boxes', 'topic' => 'trips', 'icon' => '🏬', 'apps' => ['admin', 'company'],
                'title_en' => 'Boxes at each partner hub', 'title_tl' => 'Mga box sa bawat partner hub',
                'summary_en' => 'The dashboard shows, for each hub, the boxes coming, waiting, on a truck, delivered and not delivered.',
                'summary_tl' => 'Makikita sa dashboard, bawat hub, ang mga box na paparating, naghihintay, nasa truck, na-deliver at hindi na-deliver.',
                'when_en' => 'You want to know how busy a hub is or which boxes are stuck.',
                'when_tl' => 'Gusto mong malaman kung gaano ka-busy ang hub o aling box ang naiipit.',
                'steps' => [
                    $s('Open the dashboard', 'The hub boxes are on the dashboard. The numbers refresh every minute.', 'Buksan ang dashboard', 'Nasa dashboard ang hub boxes. Nag-a-update ang bilang bawat minuto.'),
                    $s('Open a number', 'Click a number to see those boxes.', 'Buksan ang isang bilang', 'I-click ang bilang para makita ang mga box na iyon.'),
                    $s('Partner hub: Incoming boxes', 'At the hub, Incoming boxes shows what is coming and lets you make your own trip.', 'Partner hub: Incoming boxes', 'Sa hub, ang Incoming boxes ay nagpapakita ng paparating at puwede kang gumawa ng sariling trip.'),
                ],
                'result_en' => 'You see where every hub\'s boxes are.',
                'result_tl' => 'Makikita mo kung nasaan ang mga box ng bawat hub.',
                'problems' => [],
                'pages' => ['pages.dashboard', 'resources.logistichubs.*', 'pages.incoming-boxes'],
                'links' => ['admin' => 'pages.dashboard', 'company' => 'pages.incoming-boxes'],
                'related' => ['not-delivered-list', 'create-trip'], 'sort' => 60,
            ],
            [
                'slug' => 'not-delivered-list', 'topic' => 'trips', 'icon' => '⚠️', 'apps' => ['admin', 'warehouse', 'company'],
                'title_en' => 'Not delivered: what to do next', 'title_tl' => 'Hindi na-deliver: ano ang susunod',
                'summary_en' => 'Boxes the driver could not deliver are listed with the reason, the note and the photo. Call, plan again, or return.',
                'summary_tl' => 'Nakalista ang mga box na hindi na-deliver kasama ang dahilan, note at photo. Tawagan, i-plano ulit, o i-return.',
                'when_en' => 'After a trip, some boxes came back.',
                'when_tl' => 'Pagkatapos ng trip, may mga box na bumalik.',
                'steps' => [
                    $s('Open the list', 'Partner hub: Not delivered. Admin and Warehouse: the trip in Delivery Log, tab Not delivered.', 'Buksan ang listahan', 'Partner hub: Not delivered. Admin at Warehouse: ang trip sa Delivery Log, tab na Not delivered.'),
                    $s('Read the reason', 'No one home, address not found, refused… The driver\'s note and photo are there.', 'Basahin ang dahilan', 'Walang tao, hindi mahanap ang address, tinanggihan… Nandoon ang note at photo ng driver.'),
                    $s('Return the box', 'Scan it in Return Boxes when the truck is back.', 'I-return ang box', 'I-scan sa Return Boxes pagbalik ng truck.'),
                    $s('Plan it again', 'The returned box can go on the next trip. Tried-before boxes are put first.', 'I-plano ulit', 'Puwedeng isakay sa susunod na trip ang box na na-return. Inuuna ang mga box na sinubukan na.'),
                ],
                'result_en' => 'The box is back in the inventory and goes out again.',
                'result_tl' => 'Balik sa inventory ang box at lalabas ulit.',
                'problems' => [
                    $p('The receiver says it was never tried', 'Open the box history: the time, the place on the map and the photo show the try.', 'Sabi ng receiver hindi sinubukan', 'Buksan ang history ng box: ang oras, lugar sa mapa at photo ang patunay.'),
                ],
                'pages' => ['pages.not-delivered'],
                'links' => ['company' => 'pages.not-delivered', 'admin' => 'resources.deliverylogs.index', 'warehouse' => 'resources.deliverylogs.index'],
                'related' => ['return-boxes', 'driver-cant-deliver', 'sms-setup'], 'sort' => 70,
            ],

            // ───────────────────────────── trucks ─────────────────────────────
            [
                'slug' => 'truck-tracking', 'topic' => 'trucks', 'icon' => '📍', 'apps' => ['admin', 'warehouse', 'company'],
                'title_en' => 'See where the trucks are', 'title_tl' => 'Tingnan kung nasaan ang mga truck',
                'summary_en' => 'Truck tracking shows every truck on a trip on a map, its stops, speed, and alerts.',
                'summary_tl' => 'Ipinapakita ng Truck tracking ang bawat truck na nasa trip sa mapa, ang stops, bilis, at alerts.',
                'when_en' => 'You want to know if a truck is on the way, late, or stopped.',
                'when_tl' => 'Gusto mong malaman kung paparating, late, o nakatigil ang truck.',
                'steps' => [
                    $s('Open Truck tracking', 'Open Truck tracking in the menu. Trucks on a trip are listed on the left.', 'Buksan ang Truck tracking', 'Buksan ang Truck tracking sa menu. Nasa kaliwa ang mga truck na nasa trip.', $img('tracking')),
                    $s('Pick a truck', 'Click a truck to see it on the map with its stops. The map refreshes every 30 seconds.', 'Pumili ng truck', 'I-click ang truck para makita sa mapa kasama ang stops. Nag-a-update ang mapa bawat 30 segundo.'),
                    $s('Open the truck page', 'Press Open truck for the day\'s route, Replay, and the Alerts tab.', 'Buksan ang page ng truck', 'Pindutin ang Open truck para sa ruta ng araw, Replay, at tab na Alerts.'),
                ],
                'result_en' => 'You see each truck\'s last place and how its trip is going.',
                'result_tl' => 'Makikita mo ang huling lugar ng bawat truck at kung kumusta ang trip.',
                'problems' => [
                    $p('The truck has no location', 'The driver has not agreed to location yet, or the phone has no signal. See "Location in the Driver app".', 'Walang location ang truck', 'Hindi pa pumapayag sa location ang driver, o walang signal ang phone. Tingnan ang "Location sa Driver app".'),
                    $p('Using a GPS tracker instead', 'Admin → Settings → Truck tracking gives each truck a tracker link to paste in the tracker\'s settings.', 'Gamit ay GPS tracker', 'Sa Admin → Settings → Truck tracking, may tracker link ang bawat truck na ilalagay sa settings ng tracker.'),
                ],
                'pages' => ['pages.truck-tracking', 'pages.truck-tracking.truck', 'pages.tracking-settings'],
                'links' => ['admin' => 'pages.truck-tracking', 'warehouse' => 'pages.truck-tracking', 'company' => 'pages.truck-tracking'],
                'related' => ['end-of-day', 'driver-location'], 'sort' => 10,
            ],
            [
                'slug' => 'end-of-day', 'topic' => 'trucks', 'icon' => '🌙', 'apps' => ['admin', 'warehouse', 'company'],
                'title_en' => 'End-of-day truck summary', 'title_tl' => 'Buod ng mga truck sa dulo ng araw',
                'summary_en' => 'After work, the day in short: for each truck what went well and what to look at. It can also be emailed.',
                'summary_tl' => 'Pagkatapos ng trabaho, ang buod ng araw: sa bawat truck, ano ang maganda at ano ang dapat tingnan. Puwede ring i-email.',
                'when_en' => 'At the end of the day, or the next morning.',
                'when_tl' => 'Sa dulo ng araw, o kinaumagahan.',
                'steps' => [
                    $s('Open the summary', 'Truck tracking → End of day.', 'Buksan ang buod', 'Truck tracking → End of day.'),
                    $s('Choose the day', 'Pick a date to see an older day.', 'Piliin ang araw', 'Pumili ng petsa para makita ang lumang araw.'),
                    $s('Email it every day', 'Admin → Settings → Truck tracking: type the emails for the daily summary (sent 6 PM).', 'I-email araw-araw', 'Admin → Settings → Truck tracking: i-type ang mga email para sa araw-araw na buod (ipinapadala 6 PM).'),
                ],
                'result_en' => 'You know which trucks had a good day and which need a talk.',
                'result_tl' => 'Alam mo kung aling truck ang maganda ang araw at alin ang kailangang kausapin.',
                'problems' => [
                    $p('The summary has no AI notes', 'Switch on "End-of-day truck summary" in Settings → AI.', 'Walang AI notes ang buod', 'I-on ang "End-of-day truck summary" sa Settings → AI.'),
                ],
                'pages' => ['pages.truck-tracking.end-of-day'],
                'links' => ['admin' => 'pages.truck-tracking.end-of-day', 'warehouse' => 'pages.truck-tracking.end-of-day', 'company' => 'pages.truck-tracking.end-of-day'],
                'related' => ['truck-tracking', 'ai-settings'], 'sort' => 20,
            ],

            // ───────────────────────────── receivers ─────────────────────────────
            [
                'slug' => 'sms-setup', 'topic' => 'receivers', 'icon' => '💬', 'apps' => ['admin'],
                'title_en' => 'Send SMS to receivers', 'title_tl' => 'Magpadala ng SMS sa mga receiver',
                'summary_en' => 'Receivers get a text when the box is out for delivery, when the driver is next, delivered, or not delivered.',
                'summary_tl' => 'Makakatanggap ng text ang receiver kapag palabas na ang box, kapag sila na ang susunod, na-deliver, o hindi na-deliver.',
                'when_en' => 'You want receivers to know when their box comes.',
                'when_tl' => 'Gusto mong malaman ng receiver kung kailan darating ang box.',
                'steps' => [
                    $s('Get an SMS account', 'Make an account at Semaphore (semaphore.co) and copy the API key. Twilio also works.', 'Kumuha ng SMS account', 'Gumawa ng account sa Semaphore (semaphore.co) at kopyahin ang API key. Puwede rin ang Twilio.', $img('sms')),
                    $s('Paste the key', 'Settings → SMS: choose the provider, paste the key and the sender name, press Send test.', 'Ilagay ang key', 'Settings → SMS: piliin ang provider, ilagay ang key at sender name, pindutin ang Send test.'),
                    $s('Choose the messages', 'Switch on the texts you want and edit the words. Tagalog and Bisaya are used by province.', 'Piliin ang mga mensahe', 'I-on ang mga text na gusto mo at baguhin ang salita. Tagalog at Bisaya ayon sa probinsya.'),
                    $s('Watch the SMS log', 'SMS log shows every text and if it was sent, a bad number, or the receiver replied STOP.', 'Tingnan ang SMS log', 'Makikita sa SMS log ang bawat text at kung na-send, mali ang number, o nag-reply ng STOP ang receiver.'),
                ],
                'result_en' => 'One text per receiver at each step, within your monthly limit.',
                'result_tl' => 'Isang text bawat receiver sa bawat hakbang, pasok sa monthly limit mo.',
                'problems' => [
                    $p('Status says Bad number', 'The receiver\'s mobile number on the invoice is wrong or too short. Fix it on the invoice.', 'Bad number ang status', 'Mali o kulang ang mobile number ng receiver sa invoice. Ayusin sa invoice.'),
                    $p('How much does it cost?', 'Semaphore is about ₱0.50 per SMS (160 characters). Set a monthly limit in Settings → SMS.', 'Magkano ang bayad?', 'Sa Semaphore mga ₱0.50 bawat SMS (160 characters). Maglagay ng monthly limit sa Settings → SMS.'),
                ],
                'pages' => ['pages.sms-settings', 'pages.sms-log'],
                'links' => ['admin' => 'pages.sms-settings'],
                'related' => ['not-delivered-list', 'ai-settings'], 'sort' => 10,
            ],

            // ───────────────────────────── apps ─────────────────────────────
            [
                'slug' => 'install-apps', 'topic' => 'apps', 'icon' => '📲', 'apps' => ['admin', 'warehouse', 'company'],
                'title_en' => 'Put the Scan app and Driver app on a phone', 'title_tl' => 'Ilagay ang Scan app at Driver app sa phone',
                'summary_en' => 'Open the link on the phone and add it to the home screen. It works like an app.',
                'summary_tl' => 'Buksan ang link sa phone at i-add sa home screen. Gagana itong parang app.',
                'when_en' => 'A new crew member or driver starts.',
                'when_tl' => 'May bagong crew o driver.',
                'steps' => [
                    $s('Open Install apps', 'Open Install apps. Each app has a QR code.', 'Buksan ang Install apps', 'Buksan ang Install apps. May QR code ang bawat app.'),
                    $s('Scan the QR with the phone', 'The crew scans the Scan app QR; drivers scan the Driver app QR.', 'I-scan ang QR gamit ang phone', 'Ang crew ay i-scan ang QR ng Scan app; ang driver ay QR ng Driver app.'),
                    $s('Add to home screen', 'Android: tap Install. iPhone: Share → Add to Home Screen.', 'I-add sa home screen', 'Android: pindutin ang Install. iPhone: Share → Add to Home Screen.'),
                    $s('Sign in', 'Sign in with their own email and password.', 'Mag-sign in', 'Mag-sign in gamit ang sariling email at password.'),
                ],
                'result_en' => 'The app is on the phone\'s home screen.',
                'result_tl' => 'Nasa home screen na ng phone ang app.',
                'problems' => [
                    $p('The crew sees "can\'t scan here"', 'Their account type is wrong. Set it to Warehouse or Company in Users.', 'Sabi ng crew "can\'t scan here"', 'Mali ang account type. Gawing Warehouse o Company sa Users.'),
                ],
                'pages' => ['pages.install-apps', 'pages.app-icons'],
                'links' => ['warehouse' => 'pages.install-apps', 'company' => 'pages.install-apps'],
                'related' => ['driver-location'], 'sort' => 10,
            ],
            [
                'slug' => 'scan-tips', 'topic' => 'apps', 'icon' => '📷', 'apps' => ['scan'],
                'title_en' => 'Scanning tips', 'title_tl' => 'Mga tip sa pag-scan',
                'summary_en' => 'Green is good, red tells you what is wrong. Every scan is saved right away.',
                'summary_tl' => 'Green ay okay, red ay may mali at sasabihin kung ano. Naka-save agad ang bawat scan.',
                'when_en' => 'You are new to the Scan app.',
                'when_tl' => 'Bago ka sa Scan app.',
                'steps' => [
                    $s('Pick what you are doing', 'On the home screen tap Unload, Load, Return, or Hub load.', 'Piliin ang gagawin', 'Sa home screen, pindutin ang Unload, Load, Return, o Hub load.', $img('scan-home')),
                    $s('Hold the barcode flat', 'Keep the label 15–20 cm from the camera, in good light.', 'Itapat nang maayos ang barcode', 'Ilayo ang label nang 15–20 cm sa camera, sa maliwanag na lugar.'),
                    $s('Type it if it will not scan', 'Type the invoice number in the box under the camera and press →.', 'I-type kung ayaw ma-scan', 'I-type ang invoice number sa box sa ilalim ng camera at pindutin ang →.'),
                    $s('Read red messages', 'Red says why: wrong trip, already scanned, not on the list. Put the box aside and go on.', 'Basahin ang red na mensahe', 'Sinasabi ng red kung bakit: ibang trip, na-scan na, wala sa listahan. Itabi ang box at tuloy lang.'),
                ],
                'result_en' => 'Fast scanning with fewer mistakes.',
                'result_tl' => 'Mabilis na pag-scan at mas kaunting mali.',
                'problems' => [
                    $p('The camera does not open', 'Allow the camera for this app in the phone settings, then open the app again.', 'Ayaw bumukas ng camera', 'Payagan ang camera para sa app sa settings ng phone, tapos buksan ulit ang app.'),
                ],
                'pages' => [], 'links' => [],
                'related' => ['unload-container', 'load-truck', 'return-boxes'], 'sort' => 5,
            ],

            // ───────────────────────────── driver ─────────────────────────────
            [
                'slug' => 'driver-deliver', 'topic' => 'apps', 'icon' => '✅', 'apps' => ['driver', 'admin', 'company'],
                'title_en' => 'Deliver a box', 'title_tl' => 'Mag-deliver ng box',
                'summary_en' => 'Scan the box, check the name, take the proof photo, press Deliver.',
                'summary_tl' => 'I-scan ang box, tingnan ang pangalan, kunan ng proof photo, pindutin ang Deliver.',
                'when_en' => 'You are at the receiver with the box.',
                'when_tl' => 'Nasa receiver ka na dala ang box.',
                'steps' => [
                    $s('Scan the box', 'Tap Scan and point at the label.', 'I-scan ang box', 'Pindutin ang Scan at itapat sa label.', $img('driver-home')),
                    $s('Check before handing over', 'Check the receiver\'s name and the box number on the screen.', 'Tingnan bago iabot', 'Tingnan ang pangalan ng receiver at box number sa screen.'),
                    $s('Take the proof photo', 'Take a photo of the box with the receiver or at the door. You can add more than one.', 'Kunan ng proof photo', 'Kunan ng photo ang box kasama ang receiver o sa pinto. Puwedeng higit sa isa.'),
                    $s('Press Deliver', 'Press Deliver this box. The receiver gets a text if SMS is on.', 'Pindutin ang Deliver', 'Pindutin ang Deliver this box. Makakatanggap ng text ang receiver kung naka-on ang SMS.'),
                ],
                'result_en' => 'The box is delivered, with the time, place and photo.',
                'result_tl' => 'Na-deliver na ang box, may oras, lugar at photo.',
                'problems' => [
                    $p('It says not this box', 'The box is not on your trip. Keep it on the truck and tell the office.', 'Sabi ay "Not this box"', 'Wala sa trip mo ang box. Iwan sa truck at sabihan ang office.'),
                    $p('No signal', 'Deliver anyway. It is saved on the phone and sent when there is signal.', 'Walang signal', 'Mag-deliver pa rin. Naka-save sa phone at ipapadala kapag may signal na.'),
                ],
                'pages' => [], 'links' => [],
                'related' => ['driver-undo', 'driver-cant-deliver', 'driver-offline'], 'sort' => 20,
            ],
            [
                'slug' => 'driver-cant-deliver', 'topic' => 'apps', 'icon' => '🚫', 'apps' => ['driver'],
                'title_en' => 'Can\'t deliver', 'title_tl' => 'Hindi ma-deliver',
                'summary_en' => 'Choose the reason, take a photo, and keep the box on the truck.',
                'summary_tl' => 'Piliin ang dahilan, mag-picture, at iwan ang box sa truck.',
                'when_en' => 'No one is home, the address is wrong, or the receiver refused.',
                'when_tl' => 'Walang tao, mali ang address, o tinanggihan ng receiver.',
                'steps' => [
                    $s('Scan the box', 'Scan it like a delivery, then press Can\'t deliver.', 'I-scan ang box', 'I-scan gaya ng delivery, tapos pindutin ang Can\'t deliver.'),
                    $s('Choose the reason', 'No one home, address not found, phone unreachable, refused, and others.', 'Piliin ang dahilan', 'Walang tao, hindi mahanap ang address, hindi ma-contact, tinanggihan, at iba pa.'),
                    $s('Photo and note', 'Take a photo of the place and add a short note. With voice note on, just say what happened.', 'Photo at note', 'Kunan ng photo ang lugar at maglagay ng maikling note. Kung naka-on ang voice note, sabihin lang ang nangyari.'),
                    $s('Keep it on the truck', 'Bring it back. The office scans it in Return Boxes.', 'Iwan sa truck', 'Ibalik ito. I-scan ng office sa Return Boxes.'),
                ],
                'result_en' => 'The box is marked not delivered with the reason; the office plans it again.',
                'result_tl' => 'Minarkahan ang box na hindi na-deliver kasama ang dahilan; ipa-plano ulit ng office.',
                'problems' => [
                    $p('The receiver came back', 'Scan the box again and press Deliver.', 'Bumalik ang receiver', 'I-scan ulit ang box at pindutin ang Deliver.'),
                ],
                'pages' => [], 'links' => [],
                'related' => ['driver-deliver', 'return-boxes'], 'sort' => 30,
            ],
            [
                'slug' => 'driver-undo', 'topic' => 'apps', 'icon' => '↶', 'apps' => ['driver'],
                'title_en' => 'Undo a delivery', 'title_tl' => 'I-undo ang delivery',
                'summary_en' => 'Pressed Deliver by mistake? Undo it within 30 minutes.',
                'summary_tl' => 'Napindot ang Deliver nang mali? I-undo sa loob ng 30 minuto.',
                'when_en' => 'Wrong box, or the receiver did not get it.',
                'when_tl' => 'Maling box, o hindi natanggap ng receiver.',
                'steps' => [
                    $s('Right away', 'Tap Undo on the green bar that shows after Deliver.', 'Agad-agad', 'Pindutin ang Undo sa green bar na lumalabas pagkatapos ng Deliver.'),
                    $s('Later', 'Boxes → Delivered, find the box, tap Undo and choose why.', 'Mamaya', 'Boxes → Delivered, hanapin ang box, pindutin ang Undo at piliin kung bakit.'),
                ],
                'result_en' => 'The box is back in your To deliver list.',
                'result_tl' => 'Balik ang box sa listahan ng To deliver.',
                'problems' => [
                    $p('There is no Undo button', 'More than 30 minutes passed. Ask the office to undo it.', 'Walang Undo button', 'Lumampas na ng 30 minuto. Ipa-undo sa office.'),
                ],
                'pages' => [], 'links' => [],
                'related' => ['driver-deliver'], 'sort' => 40,
            ],
            [
                'slug' => 'driver-navigate', 'topic' => 'apps', 'icon' => '🗺️', 'apps' => ['driver'],
                'title_en' => 'Go to the next stop', 'title_tl' => 'Pumunta sa susunod na stop',
                'summary_en' => 'Where to go next shows the next stop. Tap Navigate and choose Waze, Google Maps or Apple Maps.',
                'summary_tl' => 'Ipinapakita ng Where to go next ang susunod na stop. Pindutin ang Navigate at piliin ang Waze, Google Maps o Apple Maps.',
                'when_en' => 'You finished a stop and want directions to the next one.',
                'when_tl' => 'Tapos ka sa isang stop at gusto mo ng direksyon sa susunod.',
                'steps' => [
                    $s('Look at the next stop', 'On Today, Where to go next shows the receiver, the address and the boxes.', 'Tingnan ang susunod na stop', 'Sa Today, ipinapakita ng Where to go next ang receiver, address at mga box.'),
                    $s('Tap Navigate', 'Choose Waze, Google Maps or Apple Maps. The app opens with the route from where you are.', 'Pindutin ang Navigate', 'Piliin ang Waze, Google Maps o Apple Maps. Bubukas ang app na may ruta mula kung nasaan ka.'),
                    $s('Call if needed', 'Tap Call to phone the receiver before you arrive.', 'Tumawag kung kailangan', 'Pindutin ang Call para tawagan ang receiver bago dumating.'),
                ],
                'result_en' => 'You drive the stops in the planned order.',
                'result_tl' => 'Sinusunod mo ang stops ayon sa plano.',
                'problems' => [
                    $p('The pin is in the wrong place', 'Call the receiver. Tell the office so the address is fixed for next time.', 'Mali ang lugar ng pin', 'Tawagan ang receiver. Sabihan ang office para maayos ang address sa susunod.'),
                ],
                'pages' => [], 'links' => [],
                'related' => ['driver-offline', 'driver-location'], 'sort' => 10,
            ],
            [
                'slug' => 'driver-location', 'topic' => 'apps', 'icon' => '📡', 'apps' => ['driver', 'admin', 'warehouse', 'company'],
                'title_en' => 'Location in the Driver app', 'title_tl' => 'Location sa Driver app',
                'summary_en' => 'During a trip the app sends the truck\'s location so the office sees it on the map. Only during trips.',
                'summary_tl' => 'Habang may trip, ipinapadala ng app ang location ng truck para makita ng office sa mapa. Habang may trip lang.',
                'when_en' => 'The app asks to use your location, or the office cannot see your truck.',
                'when_tl' => 'Humihingi ang app ng location, o hindi makita ng office ang truck mo.',
                'steps' => [
                    $s('Agree once', 'On the first trip the app asks. Tap I agree.', 'Pumayag minsan', 'Sa unang trip, magtatanong ang app. Pindutin ang I agree.'),
                    $s('Allow location on the phone', 'When the phone asks, tap Allow (Android: "While using the app"; iPhone: "Allow While Using App").', 'Payagan ang location sa phone', 'Kapag nagtanong ang phone, pindutin ang Allow (Android: "While using the app"; iPhone: "Allow While Using App").'),
                    $s('Keep the app open', 'Keep the Driver app open on the screen while driving, with the phone charging.', 'Panatilihing bukas ang app', 'Iwanang bukas ang Driver app sa screen habang nagmamaneho, naka-charge ang phone.'),
                ],
                'result_en' => 'The office sees the truck move. It stops when the trip ends.',
                'result_tl' => 'Nakikita ng office ang galaw ng truck. Titigil kapag tapos ang trip.',
                'problems' => [
                    $p('I pressed Block by mistake', 'Phone Settings → the browser or the app → Location → Allow. Then open the app again.', 'Napindot ang Block', 'Settings ng phone → browser o app → Location → Allow. Tapos buksan ulit ang app.'),
                ],
                'pages' => [], 'links' => [],
                'related' => ['truck-tracking', 'driver-navigate'], 'sort' => 50,
            ],
            [
                'slug' => 'driver-offline', 'topic' => 'apps', 'icon' => '📶', 'apps' => ['driver'],
                'title_en' => 'No signal', 'title_tl' => 'Walang signal',
                'summary_en' => 'The Driver app keeps working with no signal. Deliveries wait on the phone and are sent later.',
                'summary_tl' => 'Gumagana pa rin ang Driver app kahit walang signal. Naka-hold sa phone ang deliveries at ipapadala mamaya.',
                'when_en' => 'The top bar says No signal or waiting to send.',
                'when_tl' => 'Sabi sa itaas ay No signal o waiting to send.',
                'steps' => [
                    $s('Keep working', 'Scan, deliver and take photos as usual.', 'Tuloy lang ang trabaho', 'Mag-scan, mag-deliver at mag-picture gaya ng dati.'),
                    $s('Watch the top bar', 'It shows how many are waiting to send.', 'Tingnan ang bar sa itaas', 'Ipinapakita kung ilan ang naghihintay maipadala.'),
                    $s('Signal comes back', 'Everything is sent by itself. Do not sign out until it says all sent.', 'Bumalik ang signal', 'Kusang maipapadala lahat. Huwag mag-sign out hangga\'t hindi sinasabing all sent.'),
                ],
                'result_en' => 'Nothing is lost when there is no signal.',
                'result_tl' => 'Walang nawawala kahit walang signal.',
                'problems' => [
                    $p('It says needs attention', 'One delivery could not be saved (for example the box was moved). Tap it and follow what it says.', 'Sabi ay needs attention', 'May isang delivery na hindi ma-save (hal. nailipat ang box). Pindutin ito at sundin ang sinasabi.'),
                    $p('Maps with no signal', 'Download the area in Google Maps or Waze before the trip (offline maps).', 'Mapa kahit walang signal', 'I-download ang area sa Google Maps o Waze bago ang trip (offline maps).'),
                ],
                'pages' => [], 'links' => [],
                'related' => ['driver-deliver', 'driver-navigate'], 'sort' => 60,
            ],

            // ───────────────────────────── settings ─────────────────────────────
            [
                'slug' => 'ai-settings', 'topic' => 'settings', 'icon' => '✨', 'apps' => ['admin'],
                'title_en' => 'Switch on the AI helpers', 'title_tl' => 'I-on ang mga AI helper',
                'summary_en' => 'Each AI helper is switched on one by one in Settings → AI, with a monthly spending limit.',
                'summary_tl' => 'Isa-isang ino-on ang bawat AI helper sa Settings → AI, may monthly na limit sa gastos.',
                'when_en' => 'A page says the AI is off, or you want to try a helper.',
                'when_tl' => 'Sabi ng page ay naka-off ang AI, o gusto mong subukan ang isang helper.',
                'steps' => [
                    $s('Open Settings → AI', 'Only an admin can open it.', 'Buksan ang Settings → AI', 'Admin lang ang makakabukas.'),
                    $s('Paste the API key', 'Paste the Anthropic API key and set the monthly limit.', 'Ilagay ang API key', 'Ilagay ang Anthropic API key at itakda ang monthly limit.'),
                    $s('Switch helpers on', 'Tick each helper you want (trip helper, photo check, SMS writer, Help answers…) and Save.', 'I-on ang mga helper', 'I-check ang bawat helper na gusto mo (trip helper, photo check, SMS writer, Help answers…) at i-Save.'),
                ],
                'result_en' => 'The helpers show in their pages and menus.',
                'result_tl' => 'Lalabas ang mga helper sa kanilang mga page at menu.',
                'problems' => [],
                'pages' => ['pages.ai-settings'],
                'links' => ['admin' => 'pages.ai-settings'],
                'related' => ['ai-trip-helper', 'sms-setup', 'help-edit'], 'sort' => 10,
            ],
            [
                'slug' => 'maps-routes', 'topic' => 'settings', 'icon' => '🗺️', 'apps' => ['admin', 'warehouse', 'company'],
                'title_en' => 'Maps & routes settings', 'title_tl' => 'Settings ng Maps & routes',
                'summary_en' => 'Choose the map, where trucks start, how stops are sorted, and if messy addresses are fixed by AI.',
                'summary_tl' => 'Piliin ang mapa, kung saan nagsisimula ang truck, paano inaayos ang stops, at kung aayusin ng AI ang magulong address.',
                'when_en' => 'Setting up the system, or stops are not found on the map.',
                'when_tl' => 'Sine-set up ang system, o hindi mahanap ang stops sa mapa.',
                'steps' => [
                    $s('Open Maps & routes', 'Settings → Maps & routes.', 'Buksan ang Maps & routes', 'Settings → Maps & routes.'),
                    $s('Start point', 'Set where each hub\'s trucks leave from.', 'Simula', 'Itakda kung saan umaalis ang mga truck ng bawat hub.'),
                    $s('Address cleaning', 'Switch on AI address cleaning so more stops are found.', 'Paglilinis ng address', 'I-on ang AI address cleaning para mas maraming stop ang mahanap.'),
                ],
                'result_en' => 'New trips are sorted with these settings.',
                'result_tl' => 'Aayusin ang mga bagong trip gamit ang settings na ito.',
                'problems' => [],
                'pages' => ['pages.maps-routes'],
                'links' => ['admin' => 'pages.maps-routes', 'warehouse' => 'pages.maps-routes', 'company' => 'pages.maps-routes'],
                'related' => ['stops-loading'], 'sort' => 20,
            ],
            [
                'slug' => 'help-edit', 'topic' => 'settings', 'icon' => '📝', 'apps' => ['admin'],
                'title_en' => 'Edit the help guides', 'title_tl' => 'Baguhin ang mga gabay',
                'summary_en' => 'Admins can change any guide, add screenshots, and write new guides for your team.',
                'summary_tl' => 'Puwedeng baguhin ng admin ang kahit anong gabay, magdagdag ng screenshot, at gumawa ng bagong gabay.',
                'when_en' => 'A guide is out of date or your team does something its own way.',
                'when_tl' => 'Luma na ang gabay o may sariling paraan ang team ninyo.',
                'steps' => [
                    $s('Open Help guides', 'Settings → Help guides.', 'Buksan ang Help guides', 'Settings → Help guides.'),
                    $s('Edit or add', 'Change the words in English and Tagalog, add steps, upload a screenshot for a step.', 'Baguhin o magdagdag', 'Baguhin ang salita sa English at Tagalog, magdagdag ng hakbang, mag-upload ng screenshot.'),
                    $s('Choose who sees it', 'Tick the panels and apps it shows in, then Save.', 'Piliin kung sino ang makakakita', 'I-check ang mga panel at app kung saan lalabas, tapos i-Save.'),
                ],
                'result_en' => 'Everyone sees the new guide right away. "Was this helpful?" votes show which guides to improve.',
                'result_tl' => 'Makikita agad ng lahat ang bagong gabay. Ang mga boto sa "Nakatulong ba?" ay nagsasabi kung aling gabay ang dapat ayusin.',
                'problems' => [],
                'pages' => ['resources.help-guides.*'],
                'links' => ['admin' => 'resources.help-guides.index'],
                'related' => ['ai-settings'], 'sort' => 90,
            ],
            // ───────────────────────────── fuel ─────────────────────────────
            [
                'slug' => 'fuel-driver', 'topic' => 'apps', 'icon' => '⛽', 'apps' => ['driver'],
                'title_en' => 'Add a fuel fill', 'title_tl' => 'Mag-add ng karga ng fuel',
                'summary_en' => 'After every fill: photo of the receipt, check the numbers, card or cash, photo of the odometer.',
                'summary_tl' => 'Pagkatapos magpakarga: picture ng resibo, tingnan ang numbers, card o cash, picture ng odometer.',
                'when_en' => 'You just filled the truck at a station.',
                'when_tl' => 'Kakakarga mo lang ng truck sa gasolinahan.',
                'steps' => [
                    $s('Show the company card', 'For ₱1,000 and up, show the cashier the card with the company name and TIN so they write it on the receipt.', 'Ipakita ang company card', 'Kapag ₱1,000 pataas, ipakita sa cashier ang card na may pangalan at TIN ng kompanya para isulat sa resibo.'),
                    $s('Photo of the receipt', 'Today → ⛽ Add fuel → Take receipt photo. Lay the receipt flat, all of it in the photo.', 'Picture ng resibo', 'Today → ⛽ Add fuel → Take receipt photo. Ilapag ang resibo, buo dapat sa picture.'),
                    $s('Check and choose', 'Check diesel or gasoline, liters, price, total and VAT. Choose fuel card or cash.', 'Tingnan at piliin', 'Tingnan kung diesel o gasoline, liters, presyo, total at VAT. Piliin kung fuel card o cash.'),
                    $s('Photo of the odometer', 'Take a photo of the total km on the dashboard, check the number, press Save fill.', 'Picture ng odometer', 'Kunan ang total km sa dashboard, tingnan ang numero, pindutin ang Save fill.'),
                ],
                'result_en' => 'The office sees the fill, the km per liter and the receipt. Give the paper receipt to the office.',
                'result_tl' => 'Makikita ng office ang karga, km per liter at resibo. Ibigay ang papel na resibo sa office.',
                'problems' => [
                    $p('It says wrong fuel', 'The receipt says another fuel than the truck uses. Check the receipt and tell the office right away.', 'Sabi ay wrong fuel', 'Ibang fuel ang nasa resibo kaysa sa gamit ng truck. Tingnan ang resibo at sabihan agad ang office.'),
                    $p('The card does not work', 'Use the fuel cash from the office and choose Cash. Keep the receipt.', 'Ayaw ng card', 'Gamitin ang fuel cash galing office at piliin ang Cash. Itago ang resibo.'),
                ],
                'pages' => ['pages.fuel'], 'links' => ['driver' => 'pages.fuel'],
                'related' => ['driver-deliver'], 'sort' => 60,
            ],
            [
                'slug' => 'fuel-office', 'topic' => 'trucks', 'icon' => '⛽', 'apps' => ['admin', 'warehouse', 'company'],
                'title_en' => 'Fuel: fills, cards, cash and VAT', 'title_tl' => 'Fuel: karga, card, cash at VAT',
                'summary_en' => 'See what each truck used and spent, check alerts, match the fuel card statement, give and settle fuel cash, and export VAT.',
                'summary_tl' => 'Tingnan ang nagamit at gastos ng bawat truck, ang alerts, i-match ang fuel card statement, magbigay at mag-settle ng fuel cash, at i-export ang VAT.',
                'when_en' => 'Every week, when the fuel card statement comes, and before a long trip.',
                'when_tl' => 'Linggo-linggo, pagdating ng fuel card statement, at bago ang mahabang trip.',
                'steps' => [
                    $s('Set up once', 'Admin → Settings → Fuel: company TIN, fuel card, each truck\'s fuel, tank and card last 4. Settings → AI: switch on "Read fuel receipts".', 'I-set up minsan', 'Admin → Settings → Fuel: company TIN, fuel card, fuel, tank at card last 4 ng bawat truck. Settings → AI: i-on ang "Read fuel receipts".'),
                    $s('Check the alerts', 'Fuel → Alerts: wrong fuel, a fill bigger than the tank, filled away from the truck, km per liter dropping, odd price.', 'Tingnan ang alerts', 'Fuel → Alerts: maling fuel, kargang lampas sa tangke, nag-fill malayo sa truck, bumababang km per liter, kakaibang presyo.'),
                    $s('Match the card statement', 'Fuel → Fuel cards: import the CSV from the card website. Charges with no fill in the app are flagged.', 'I-match ang card statement', 'Fuel → Fuel cards: i-import ang CSV galing sa website ng card. Naka-flag ang charges na walang karga sa app.'),
                    $s('Fuel cash for a trip', 'Delivery Log → trip → Fuel: the estimate, give the cash, then settle the change when the truck is back.', 'Fuel cash para sa trip', 'Delivery Log → trip → Fuel: ang estimate, ibigay ang cash, tapos i-settle ang sukli pagbalik ng truck.'),
                    $s('VAT for the accountant', 'Fuel → VAT → Excel for the accountant. Keep the paper receipts.', 'VAT para sa accountant', 'Fuel → VAT → Excel for the accountant. Itago ang papel na resibo.'),
                ],
                'result_en' => 'You know what fuel costs per truck and per box, and what VAT you can claim.',
                'result_tl' => 'Alam mo ang gastos sa fuel bawat truck at bawat box, at ang VAT na puwedeng i-claim.',
                'problems' => [
                    $p('Charges say "Card or plate not known"', 'Put the card\'s last 4 digits on the truck in Settings → Fuel, then import again.', 'Sabi ay "Card or plate not known"', 'Ilagay ang last 4 digits ng card sa truck sa Settings → Fuel, tapos i-import ulit.'),
                    $p('No price this week', 'Prices come from this week\'s receipts. Until the first one, Admin can set the price in Fuel → Prices.', 'Walang presyo ngayong linggo', 'Galing sa mga resibo ngayong linggo ang presyo. Habang wala pa, puwedeng i-set ng Admin sa Fuel → Prices.'),
                ],
                'pages' => ['pages.fuel', 'pages.trip-fuel', 'pages.fuel-settings'],
                'links' => ['admin' => 'pages.fuel', 'warehouse' => 'pages.fuel', 'company' => 'pages.fuel'],
                'related' => ['truck-tracking', 'create-trip'], 'sort' => 40,
            ],
        ];
    }
}
DISPATCH_FILE_END_23

# ---------------------------------------------------------------- database/migrations/2026_11_14_000022_create_fuel_tables.php
mkdir -p 'database/migrations'
cat > 'database/migrations/2026_11_14_000022_create_fuel_tables.php' <<'DISPATCH_FILE_END_24'
<?php

use App\Support\Help\Help;
use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

/** Fuel: fills from the Driver app, fuel cash per trip, fuel card statements. */
return new class extends Migration
{
    public function up(): void
    {
        Schema::table('trucks', function (Blueprint $table) {
            if (! Schema::hasColumn('trucks', 'fuel_type')) {
                $table->string('fuel_type', 10)->nullable();          // diesel / gasoline
            }
            if (! Schema::hasColumn('trucks', 'tank_liters')) {
                $table->unsignedSmallInteger('tank_liters')->nullable();
            }
            if (! Schema::hasColumn('trucks', 'fuel_card_last4')) {
                $table->string('fuel_card_last4', 8)->nullable();
            }
        });

        if (! Schema::hasTable('fuel_fills')) {
            Schema::create('fuel_fills', function (Blueprint $table) {
                $table->id();
                $table->foreignId('truck_id')->index();
                $table->foreignId('deliverylog_id')->nullable()->index();
                $table->foreignId('driver_id')->nullable();
                $table->foreignId('logistichub_id')->nullable()->index();
                $table->timestamp('filled_at')->index();
                $table->string('station', 120)->nullable();
                $table->string('product', 80)->nullable();
                $table->string('fuel_type', 10)->nullable();
                $table->decimal('liters', 8, 2);
                $table->decimal('price_per_liter', 8, 2)->nullable();
                $table->decimal('total', 10, 2);
                $table->decimal('vatable', 10, 2)->nullable();
                $table->decimal('vat', 10, 2)->nullable();
                $table->string('station_tin', 30)->nullable();
                $table->string('invoice_no', 40)->nullable();
                $table->boolean('buyer_tin_ok')->nullable();
                $table->string('paid_with', 8)->default('card');      // card / cash
                $table->string('card_last4', 8)->nullable();
                $table->unsignedInteger('odometer')->nullable();
                $table->unsignedInteger('km_since')->nullable();
                $table->decimal('km_per_liter', 6, 2)->nullable();
                $table->string('receipt_path')->nullable();
                $table->string('odometer_path')->nullable();
                $table->decimal('lat', 10, 7)->nullable();
                $table->decimal('lng', 10, 7)->nullable();
                $table->boolean('gps_ok')->nullable();
                $table->unsignedInteger('gps_distance_m')->nullable();
                $table->boolean('ai_read')->default(false);
                $table->json('ai_data')->nullable();
                $table->timestamps();
            });
        }

        if (! Schema::hasTable('fuel_cash')) {
            Schema::create('fuel_cash', function (Blueprint $table) {
                $table->id();
                $table->foreignId('deliverylog_id')->unique();
                $table->foreignId('truck_id')->nullable();
                $table->foreignId('driver_id')->nullable();
                $table->decimal('km', 8, 1)->nullable();
                $table->decimal('km_per_liter', 6, 2)->nullable();
                $table->decimal('price', 8, 2)->nullable();
                $table->unsignedTinyInteger('buffer_pct')->default(10);
                $table->decimal('estimate', 10, 2)->nullable();
                $table->decimal('given', 10, 2);
                $table->timestamp('given_at');
                $table->foreignId('given_by')->nullable();
                $table->decimal('returned', 10, 2)->nullable();
                $table->timestamp('settled_at')->nullable();
                $table->foreignId('settled_by')->nullable();
                $table->string('note')->nullable();
                $table->timestamps();
            });
        }

        if (! Schema::hasTable('fuel_statements')) {
            Schema::create('fuel_statements', function (Blueprint $table) {
                $table->id();
                $table->string('provider', 20);
                $table->string('filename');
                $table->foreignId('logistichub_id')->nullable();
                $table->date('from')->nullable();
                $table->date('to')->nullable();
                $table->unsignedInteger('lines')->default(0);
                $table->foreignId('uploaded_by')->nullable();
                $table->timestamps();
            });
        }

        if (! Schema::hasTable('fuel_statement_lines')) {
            Schema::create('fuel_statement_lines', function (Blueprint $table) {
                $table->id();
                $table->foreignId('fuel_statement_id')->index();
                $table->foreignId('truck_id')->nullable()->index();
                $table->foreignId('fuel_fill_id')->nullable()->index();
                $table->timestamp('charged_at')->nullable();
                $table->string('card', 30)->nullable();
                $table->string('plate', 20)->nullable();
                $table->string('station', 120)->nullable();
                $table->string('product', 80)->nullable();
                $table->string('fuel_type', 10)->nullable();
                $table->decimal('liters', 8, 2)->nullable();
                $table->decimal('amount', 10, 2)->nullable();
                $table->unsignedInteger('odometer')->nullable();
                $table->string('status', 16)->index();                // matched / liters_differ / no_fill / no_truck
                $table->timestamps();
            });
        }

        Help::installDefaults();
    }

    public function down(): void
    {
        Schema::dropIfExists('fuel_statement_lines');
        Schema::dropIfExists('fuel_statements');
        Schema::dropIfExists('fuel_cash');
        Schema::dropIfExists('fuel_fills');
        Schema::table('trucks', function (Blueprint $table) {
            foreach (['fuel_type', 'tank_liters', 'fuel_card_last4'] as $c) {
                if (Schema::hasColumn('trucks', $c)) {
                    $table->dropColumn($c);
                }
            }
        });
    }
};
DISPATCH_FILE_END_24

# ---------------------------------------------------------------- resources/css/filament/admin/theme.css
mkdir -p 'resources/css/filament/admin'
cat > 'resources/css/filament/admin/theme.css' <<'DISPATCH_FILE_END_25'
@import '../../../../vendor/filament/filament/resources/css/theme.css';

/* The Archivo font comes with the app (no internet needed): pages open fast even on a slow connection. */
@import '@fontsource/archivo/latin-400.css';
@import '@fontsource/archivo/latin-500.css';
@import '@fontsource/archivo/latin-600.css';
@import '@fontsource/archivo/latin-700.css';
@import '@fontsource/archivo/latin-800.css';
@import '@fontsource/archivo/latin-900.css';

@source '../../../../app/Filament/**/*';
@source '../../../../resources/views/filament/**/*';
@source '../../../../resources/views/components/**/*';

/*
 * Dispatch theme — "manifest & signal".
 * Harbour navy for the frame, signal yellow for action, colour only where it
 * carries meaning (scan outcomes, progress). Shared by all four panels.
 */
:root {
    --ds-navy: #0e2433;
    --ds-navy-2: #16334a;
    --ds-navy-3: #24465f;
    --ds-signal: #f6be00;
    --ds-steel: #5b6b78;
    --ds-deck: #f3f5f7;
    --ds-ok: #17895e;
    --ds-warn: #e08a00;
    --ds-bad: #cf3b3b;
    --ds-radius-lg: 0.875rem;
    --ds-radius: 0.625rem;
}

body {
    font-feature-settings: 'tnum' 1, 'ss01' 1;
}

/* ------------------------------------------------------------------ frame */

.fi-body {
    background: var(--ds-deck);
}

.dark .fi-body {
    background: #0a1a26;
}

.fi-sidebar {
    background: var(--ds-navy);
    border-inline-end: 0;
}

.fi-sidebar-header {
    background: var(--ds-navy);
    box-shadow: none;
    border-bottom: 1px solid rgb(255 255 255 / 0.06);
}

.fi-sidebar .fi-sidebar-group-label,
.fi-sidebar .fi-sidebar-group-btn {
    color: rgb(255 255 255 / 0.5);
}

.fi-sidebar .fi-sidebar-item-btn {
    color: rgb(255 255 255 / 0.78);
    border-radius: var(--ds-radius);
}

.fi-sidebar .fi-sidebar-item-icon {
    color: rgb(255 255 255 / 0.45);
}

.fi-sidebar .fi-sidebar-item-label {
    color: inherit;
}

.fi-sidebar .fi-sidebar-item-btn:hover,
.fi-sidebar .fi-sidebar-item-btn:focus-visible {
    background: var(--ds-navy-2);
    color: #fff;
}

/* Active item: a signal-yellow tab on the left edge, like a door stripe. */
.fi-sidebar .fi-sidebar-item.fi-active > .fi-sidebar-item-btn {
    background: var(--ds-navy-3);
    color: #fff;
    box-shadow: inset 3px 0 0 var(--ds-signal);
}

.fi-sidebar .fi-sidebar-item.fi-active .fi-sidebar-item-icon {
    color: var(--ds-signal);
}

.fi-sidebar .fi-sidebar-item-grouped-border-part {
    background: rgb(255 255 255 / 0.18);
}

.fi-sidebar-footer,
.ds-sidebar-footer {
    color: rgb(255 255 255 / 0.4);
    font-size: 0.75rem;
    padding: 0.75rem 1.25rem 1rem;
}

.fi-topbar > nav,
.fi-topbar {
    background: rgb(255 255 255 / 0.92);
    backdrop-filter: blur(8px);
    box-shadow: 0 1px 0 rgb(14 36 51 / 0.08);
}

.dark .fi-topbar > nav,
.dark .fi-topbar {
    background: rgb(14 36 51 / 0.92);
}

/* Brand mark */
.ds-brand {
    display: inline-flex;
    align-items: center;
    gap: 0.625rem;
    line-height: 1;
}

.ds-brand__mark {
    width: 2.1rem;
    height: 2.1rem;
    flex: none;
}

.ds-brand__text {
    display: flex;
    flex-direction: column;
    gap: 0.2rem;
}

.ds-brand__name {
    font-weight: 800;
    font-size: 1.05rem;
    letter-spacing: -0.01em;
    color: var(--ds-navy);
}

.ds-brand__area {
    font-size: 0.72rem;
    font-weight: 600;
    color: var(--ds-steel);
}

.fi-sidebar .ds-brand__name,
.dark .ds-brand__name {
    color: #fff;
}

.fi-sidebar .ds-brand__area,
.dark .ds-brand__area {
    color: var(--ds-signal);
}

.fi-sidebar .ds-brand__mark rect:first-child {
    fill: #23435b;
}

/* ---------------------------------------------------------------- content */

.fi-header-heading {
    letter-spacing: -0.02em;
    font-weight: 800;
}

.fi-section,
.fi-ta-ctn,
.fi-wi-stats-overview-stat {
    border-radius: var(--ds-radius-lg);
    box-shadow: 0 1px 2px rgb(14 36 51 / 0.06);
}

.fi-ta-header-cell {
    font-weight: 600;
    color: var(--ds-steel);
}

.fi-wi-stats-overview-stat {
    position: relative;
    overflow: hidden;
}

.fi-wi-stats-overview-stat-value {
    font-weight: 800;
    letter-spacing: -0.02em;
}

/* --------------------------------------------------------------- sign-in */

.fi-simple-layout {
    background:
        repeating-linear-gradient(90deg, transparent 0 46px, rgb(255 255 255 / 0.035) 46px 48px),
        var(--ds-navy);
}

.fi-simple-main {
    border-radius: 1.25rem;
    box-shadow: 0 30px 60px -20px rgb(0 0 0 / 0.45);
    border-top: 6px solid var(--ds-signal);
}

/* ------------------------------------------------------------ scan station */

.ds-station {
    display: grid;
    gap: 1.25rem;
    align-items: start;
}

@media (min-width: 1100px) {
    .ds-station {
        grid-template-columns: minmax(22rem, 2fr) 3fr;
    }
}

.ds-station__panel,
.ds-station__result {
    display: flex;
    flex-direction: column;
    gap: 1.25rem;
}

.ds-station__panel {
    background: #fff;
    border-radius: var(--ds-radius-lg);
    padding: 1.25rem;
    box-shadow: 0 1px 2px rgb(14 36 51 / 0.06), 0 0 0 1px rgb(14 36 51 / 0.05);
}

.dark .ds-station__panel {
    background: rgb(255 255 255 / 0.04);
    box-shadow: 0 0 0 1px rgb(255 255 255 / 0.08);
}

.ds-station__title {
    display: flex;
    gap: 0.875rem;
    align-items: center;
}

.ds-station__title h2 {
    font-size: 1.125rem;
    font-weight: 750;
    color: var(--ds-navy);
}

.dark .ds-station__title h2 {
    color: #fff;
}

.ds-station__title p {
    font-size: 0.875rem;
    color: var(--ds-steel);
    max-width: 38ch;
}

.ds-station__badge {
    display: grid;
    place-items: center;
    width: 2.75rem;
    height: 2.75rem;
    border-radius: 0.75rem;
    background: var(--ds-navy);
    color: var(--ds-signal);
    flex: none;
}

/* Progress */
.ds-progress__head {
    display: flex;
    justify-content: space-between;
    align-items: baseline;
    gap: 1rem;
    margin-bottom: 0.5rem;
    font-size: 0.875rem;
}

.ds-progress__label {
    color: var(--ds-steel);
    font-weight: 600;
}

.ds-progress__count strong {
    font-size: 1.5rem;
    font-weight: 800;
    color: var(--ds-navy);
}

.dark .ds-progress__count strong {
    color: #fff;
}

.ds-progress__pct {
    margin-inline-start: 0.5rem;
    color: var(--ds-steel);
}

.ds-progress__track {
    height: 0.75rem;
    border-radius: 999px;
    background: rgb(14 36 51 / 0.08);
    overflow: hidden;
}

.dark .ds-progress__track {
    background: rgb(255 255 255 / 0.1);
}

.ds-progress__bar {
    height: 100%;
    border-radius: inherit;
    background: var(--ds-signal);
    transition: width 0.35s ease;
}

.ds-progress.is-done .ds-progress__bar {
    background: var(--ds-ok);
}

.ds-progress__done {
    display: flex;
    align-items: center;
    gap: 0.4rem;
    margin-top: 0.625rem;
    color: var(--ds-ok);
    font-weight: 600;
    font-size: 0.875rem;
}

/* Result card — the invoice number painted large, like on a container door. */
.ds-result {
    --ds-tone: var(--ds-ok);
    background: #fff;
    border-radius: var(--ds-radius-lg);
    box-shadow: 0 1px 2px rgb(14 36 51 / 0.06), 0 0 0 1px rgb(14 36 51 / 0.05);
    border-inline-start: 0.6rem solid var(--ds-tone);
    padding: 1.25rem 1.5rem 1.5rem;
}

.dark .ds-result {
    background: rgb(255 255 255 / 0.04);
}

.ds-result--warning {
    --ds-tone: var(--ds-warn);
}

.ds-result--danger {
    --ds-tone: var(--ds-bad);
}

.ds-result__head {
    display: flex;
    align-items: center;
    gap: 1rem;
}

.ds-result__icon {
    color: var(--ds-tone);
    flex: none;
}

.ds-result__eyebrow {
    font-size: 0.875rem;
    font-weight: 600;
    color: var(--ds-tone);
}

.ds-result__invoice {
    font-size: clamp(2.25rem, 5vw, 3.5rem);
    line-height: 1;
    font-weight: 900;
    letter-spacing: 0.01em;
    color: var(--ds-navy);
    word-break: break-all;
}

.dark .ds-result__invoice {
    color: #fff;
}

.ds-result__message {
    font-size: 1.25rem;
    font-weight: 700;
    color: var(--ds-navy);
}

.dark .ds-result__message {
    color: #fff;
}

.ds-result__chip {
    margin-inline-start: auto;
    align-self: flex-start;
    padding: 0.3rem 0.7rem;
    border-radius: 999px;
    background: var(--ds-navy);
    color: var(--ds-signal);
    font-size: 0.8rem;
    font-weight: 700;
    white-space: nowrap;
}

.ds-result__grid {
    display: grid;
    gap: 0.875rem 1.5rem;
    margin-top: 1.25rem;
    padding-top: 1.25rem;
    border-top: 1px dashed rgb(14 36 51 / 0.15);
}

@media (min-width: 640px) {
    .ds-result__grid {
        grid-template-columns: 1fr 1fr;
    }
}

.ds-result__grid dt {
    font-size: 0.78rem;
    color: var(--ds-steel);
}

.ds-result__grid dd {
    font-size: 1rem;
    color: rgb(14 36 51 / 0.9);
}

.dark .ds-result__grid dd {
    color: rgb(255 255 255 / 0.88);
}

.ds-result__strong {
    font-size: 1.2rem !important;
    font-weight: 700;
}

.ds-result__actions {
    display: flex;
    flex-wrap: wrap;
    gap: 0.5rem;
    margin-top: 1.25rem;
}

.ds-result__actions:empty {
    display: none;
}

/* Household list */
.ds-household {
    background: #fff;
    border-radius: var(--ds-radius-lg);
    box-shadow: 0 0 0 1px rgb(14 36 51 / 0.06);
    padding: 1rem 1.25rem;
}

.dark .ds-household {
    background: rgb(255 255 255 / 0.04);
}

.ds-household__head {
    display: flex;
    align-items: center;
    gap: 0.5rem;
    font-weight: 700;
    color: var(--ds-navy);
}

.dark .ds-household__head {
    color: #fff;
}

.ds-household__sub {
    margin-inline-start: auto;
    font-weight: 500;
    font-size: 0.85rem;
    color: var(--ds-steel);
}

.ds-household__list {
    margin-top: 0.75rem;
    display: grid;
    gap: 0.25rem;
}

.ds-household__list li {
    display: grid;
    grid-template-columns: auto 1fr auto auto;
    gap: 0.75rem;
    align-items: center;
    padding: 0.5rem 0.25rem;
    border-top: 1px solid rgb(14 36 51 / 0.06);
    color: var(--ds-steel);
    font-size: 0.9rem;
}

.ds-household__list li.is-done {
    color: var(--ds-ok);
}

.ds-household__invoice {
    font-weight: 700;
    color: var(--ds-navy);
}

.dark .ds-household__invoice {
    color: #fff;
}

/* Empty state */
.ds-empty {
    display: grid;
    justify-items: center;
    text-align: center;
    gap: 0.5rem;
    padding: 3.5rem 1.5rem;
    border-radius: var(--ds-radius-lg);
    border: 2px dashed rgb(14 36 51 / 0.14);
    color: var(--ds-steel);
}

.ds-empty__title {
    font-size: 1.125rem;
    font-weight: 700;
    color: var(--ds-navy);
}

.dark .ds-empty__title {
    color: #fff;
}

.ds-empty__text {
    max-width: 36ch;
    font-size: 0.9rem;
}

/* Trip progress (dashboard table) */
.ds-trip-progress {
    display: flex;
    align-items: center;
    gap: 0.75rem;
    min-width: 12rem;
    padding-inline: 0.75rem;
}

.ds-trip-progress__track {
    position: relative;
    flex: 1;
    height: 0.5rem;
    border-radius: 999px;
    background: rgb(14 36 51 / 0.08);
    overflow: hidden;
}

.ds-trip-progress__track > span {
    position: absolute;
    inset-block: 0;
    left: 0;
    border-radius: inherit;
}

.ds-trip-progress__loaded {
    background: var(--ds-signal);
}

.ds-trip-progress__delivered {
    background: var(--ds-ok);
}

.ds-trip-progress__nums {
    font-size: 0.85rem;
    font-weight: 700;
    white-space: nowrap;
}

.ds-trip-progress__nums span {
    font-weight: 400;
    color: var(--ds-steel);
}

@media (prefers-reduced-motion: reduce) {
    .ds-progress__bar {
        transition: none;
    }
}

/* Larger stat labels on the inventory widget (kept from the original theme). */
.fi-wi-stats-overview-stat-label {
    font-weight: 600;
}

/* The station's result card already shows the last scan (with the right colour). */
.ds-station .bb-scanner__last {
    display: none;
}

/* =================================================================
 * Sign-in pages — one design per panel (Admin, Partner hub,
 * Warehouse, Delivery). Filament's own form is placed inside.
 * ================================================================= */

.ds-auth-main {
    min-height: 100vh;
    min-height: 100dvh;
}

.ds-auth {
    --ds-input-h: 3.25rem;
    min-height: 100vh;
    min-height: 100dvh;
    color: var(--ds-navy);
    font-family: Archivo, ui-sans-serif, system-ui, sans-serif;
}

/* Company name + logo */
.ds-company {
    display: inline-flex;
    align-items: center;
    gap: 0.875rem;
}

.ds-company__logo {
    width: 3.25rem;
    height: 3.25rem;
    border-radius: 0.75rem;
    object-fit: contain;
    background: #fff;
    flex: none;
}

.ds-company__logo--initials {
    display: grid;
    place-items: center;
    background: var(--ds-signal);
    color: var(--ds-navy);
    font-weight: 900;
    font-size: 1.1rem;
}

.ds-company--sm .ds-company__logo {
    width: 2.5rem;
    height: 2.5rem;
    border-radius: 0.6rem;
    font-size: 0.9rem;
}

.ds-company--lg .ds-company__logo {
    width: 3.75rem;
    height: 3.75rem;
}

.ds-company__text {
    display: flex;
    flex-direction: column;
    gap: 0.2rem;
}

.ds-company__name {
    font-size: 1.2rem;
    font-weight: 800;
    letter-spacing: -0.01em;
    line-height: 1.15;
}

.ds-company--lg .ds-company__name {
    font-size: 1.75rem;
}

.ds-company--sm .ds-company__name {
    font-size: 1.05rem;
}

.ds-company__sub {
    font-size: 0.8rem;
    font-weight: 600;
    color: var(--ds-steel);
}

.ds-company--dark {
    color: #fff;
}

.ds-company--dark .ds-company__sub {
    color: #8fa3b3;
}

.ds-company__sub--accent,
.ds-company--dark .ds-company__sub--accent {
    color: var(--ds-signal);
}

/* Shared form styling */
.ds-auth__form {
    width: 100%;
    max-width: 26.5rem;
    display: flex;
    flex-direction: column;
    gap: 0.5rem;
}

.ds-auth__chip {
    align-self: flex-start;
    font-size: 0.8rem;
    font-weight: 700;
    padding: 0.35rem 0.75rem;
    border-radius: 999px;
    background: var(--ds-navy);
    color: var(--ds-signal);
}

.ds-auth__title {
    margin: 0.5rem 0 0;
    font-size: 2.1rem;
    font-weight: 800;
    letter-spacing: -0.02em;
    line-height: 1.1;
}

.ds-auth__title--xl {
    font-size: clamp(2.2rem, 4vw, 2.75rem);
    letter-spacing: -0.03em;
}

.ds-auth__lead {
    margin: 0 0 1.25rem;
    font-size: 1rem;
    color: var(--ds-steel);
}

.ds-auth__help {
    margin: 1.25rem 0 0;
    font-size: 0.82rem;
    line-height: 1.5;
    color: var(--ds-steel);
    max-width: 26.5rem;
}

.ds-auth .fi-fo-field-label-content {
    font-weight: 600;
    color: var(--ds-navy);
}

.ds-auth .fi-input-wrp {
    min-height: var(--ds-input-h);
    border-radius: 0.65rem;
    align-items: center;
}

.ds-auth .fi-input {
    font-size: 1rem;
}

.ds-auth form .fi-btn {
    min-height: 3.4rem;
    border-radius: 0.65rem;
    font-size: 1.05rem;
    font-weight: 800;
}

.ds-auth--company form .fi-btn,
.ds-auth--warehouse form .fi-btn,
.ds-auth--delivery form .fi-btn {
    background: var(--ds-navy);
    color: #fff;
}

.ds-auth--company form .fi-btn:hover,
.ds-auth--warehouse form .fi-btn:hover,
.ds-auth--delivery form .fi-btn:hover {
    background: var(--ds-navy-3);
}

.ds-auth--company form .fi-btn,
.ds-auth--delivery form .fi-btn {
    border-radius: 999px;
}

/* ---------- Admin: navy story + form */
.ds-auth--admin {
    display: grid;
    background: var(--ds-deck);
}

@media (min-width: 1024px) {
    .ds-auth--admin {
        grid-template-columns: minmax(28rem, 44%) 1fr;
    }
}

.ds-auth-admin__story {
    position: relative;
    overflow: hidden;
    background: var(--ds-navy);
    color: #fff;
    padding: 2.5rem 1.75rem;
    display: flex;
    flex-direction: column;
    gap: 2rem;
}

@media (min-width: 1024px) {
    .ds-auth-admin__story {
        padding: 3.5rem 4rem;
        justify-content: space-between;
    }
}

.ds-auth-admin__pitch {
    position: relative;
    z-index: 1;
    display: flex;
    flex-direction: column;
    gap: 1.5rem;
}

.ds-auth-admin__pitch h1 {
    margin: 0;
    font-size: clamp(2.1rem, 4.2vw, 3.5rem);
    line-height: 1.03;
    font-weight: 800;
    letter-spacing: -0.03em;
    max-width: 14ch;
}

.ds-auth-admin__pitch p {
    margin: 0;
    font-size: 1.05rem;
    line-height: 1.55;
    color: #b7c4cf;
    max-width: 34ch;
}

.ds-auth-admin__foot {
    position: relative;
    z-index: 1;
    padding-top: 1.25rem;
    border-top: 1px solid rgb(255 255 255 / 0.12);
    font-size: 0.9rem;
    color: #8fa3b3;
}

.ds-auth-admin__ribs {
    position: absolute;
    right: -9rem;
    top: 7rem;
    width: 26rem;
    height: 35rem;
    border-radius: 1.75rem;
    background: repeating-linear-gradient(90deg, #12304a 0 34px, var(--ds-navy) 34px 46px);
    opacity: 0.7;
}

@media (max-width: 1023px) {
    .ds-auth-admin__foot,
    .ds-auth-admin__pitch p {
        display: none;
    }

    .ds-auth-admin__ribs {
        display: none;
    }
}

@media (max-width: 1023px) {
    /* On small screens the card already shows the company. */
    .ds-auth-warehouse__brand {
        display: none;
    }
}

.ds-auth__form-side {
    display: flex;
    align-items: center;
    justify-content: center;
    padding: 2.5rem 1.75rem 3rem;
}

/* ---------- Partner hub: form + yellow steps */
.ds-auth--company {
    display: grid;
    background: var(--ds-signal);
}

@media (min-width: 1024px) {
    .ds-auth--company {
        grid-template-columns: minmax(30rem, 42%) 1fr;
    }
}

.ds-auth__form-side--white {
    background: #fff;
    flex-direction: column;
    align-items: stretch;
    justify-content: space-between;
    gap: 2.5rem;
}

@media (min-width: 1024px) {
    .ds-auth__form-side--white {
        padding: 4rem 5.5rem;
    }
}

.ds-auth-company__story {
    padding: 3rem 1.75rem;
    display: flex;
    flex-direction: column;
    justify-content: center;
    gap: 2.5rem;
}

@media (min-width: 1024px) {
    .ds-auth-company__story {
        padding: 4.5rem 5rem;
    }
}

.ds-auth-company__story h1 {
    margin: 0;
    font-size: clamp(2.25rem, 4.5vw, 4rem);
    line-height: 0.98;
    font-weight: 900;
    letter-spacing: -0.035em;
    max-width: 14ch;
}

.ds-auth-company__steps {
    margin: 0;
    padding: 0;
    list-style: none;
    display: flex;
    flex-direction: column;
    max-width: 35rem;
}

.ds-auth-company__steps li {
    position: relative;
    display: grid;
    grid-template-columns: 2.75rem 1fr;
    gap: 1.25rem;
    padding-bottom: 1.6rem;
}

.ds-auth-company__steps li:not(:last-child)::before {
    content: '';
    position: absolute;
    left: calc(1.375rem - 1.5px);
    top: 2.9rem;
    bottom: 0.3rem;
    width: 3px;
    background: rgb(14 36 51 / 0.35);
}

.ds-auth-company__num {
    width: 2.75rem;
    height: 2.75rem;
    border-radius: 999px;
    display: grid;
    place-items: center;
    background: var(--ds-navy);
    color: var(--ds-signal);
    font-weight: 800;
    font-size: 1.1rem;
}

.ds-auth-company__steps strong {
    display: block;
    padding-top: 0.45rem;
    font-size: 1.25rem;
    font-weight: 800;
}

.ds-auth-company__steps span:not(.ds-auth-company__num) {
    display: block;
    margin-top: 0.25rem;
    font-size: 0.95rem;
    color: #3b3000;
}

/* ---------- Warehouse: container side + card */
.ds-auth--warehouse {
    position: relative;
    overflow: hidden;
    display: flex;
    flex-direction: column;
    align-items: center;
    justify-content: center;
    gap: 2rem;
    padding: 2.5rem 1.25rem;
    background: repeating-linear-gradient(90deg, var(--ds-navy) 0 52px, #12304a 52px 60px, #0b1f2d 60px 64px);
}

.ds-auth-warehouse__stripe {
    position: absolute;
    inset-block: 0;
    left: 0;
    width: 1.125rem;
    background: var(--ds-signal);
}

@media (min-width: 1024px) {
    .ds-auth-warehouse__brand {
        position: absolute;
        left: 4.5rem;
        top: 4rem;
    }
}

.ds-auth-warehouse__card {
    position: relative;
    width: 100%;
    max-width: 30rem;
    background: #fff;
    border-radius: 1.4rem;
    padding: 2.75rem 2rem 2.25rem;
    box-shadow: 0 40px 80px -30px rgb(0 0 0 / 0.6);
    display: flex;
    flex-direction: column;
    gap: 0.75rem;
}

@media (min-width: 640px) {
    .ds-auth-warehouse__card {
        padding: 2.75rem 3rem 2.5rem;
    }
}

.ds-auth-warehouse__tab {
    position: absolute;
    left: 3rem;
    right: 3rem;
    top: 0;
    height: 6px;
    border-radius: 0 0 6px 6px;
    background: var(--ds-signal);
}

.ds-auth-warehouse__card .ds-auth__title {
    margin-bottom: 0.75rem;
    font-size: 1.6rem;
}

/* ---------- Delivery: phone first */
.ds-auth--delivery {
    display: flex;
    flex-direction: column;
    background: #fff;
    max-width: 34rem;
    margin-inline: auto;
}

@media (min-width: 640px) {
    .ds-auth-main:has(.ds-auth--delivery) {
        background: var(--ds-navy);
        padding: 3rem 1rem;
    }

    .ds-auth--delivery {
        min-height: auto;
        border-radius: 1.5rem;
        overflow: hidden;
        box-shadow: 0 40px 80px -30px rgb(0 0 0 / 0.6);
    }
}

.ds-auth-delivery__top {
    background: var(--ds-signal);
    padding: 2.25rem 1.75rem 2rem;
    display: flex;
    flex-direction: column;
    gap: 1.4rem;
}

.ds-auth-delivery__top .ds-company__sub {
    color: var(--ds-navy);
    font-weight: 700;
}

.ds-auth-delivery__top h1 {
    margin: 0;
    font-size: 2.25rem;
    line-height: 1;
    font-weight: 900;
    letter-spacing: -0.035em;
    max-width: 12ch;
}

.ds-auth-delivery__form {
    flex: 1;
    padding: 1.75rem 1.75rem 2.5rem;
    display: flex;
    flex-direction: column;
    gap: 0.5rem;
}

.ds-auth-delivery__form .ds-auth__title {
    margin-top: 0;
    font-size: 1.75rem;
}

.ds-auth--delivery {
    --ds-input-h: 3.5rem;
}

.dark .ds-auth--admin .ds-auth__form-side,
.dark .ds-auth__form-side--white,
.dark .ds-auth-warehouse__card,
.dark .ds-auth--delivery {
    color-scheme: light;
}

/* On yellow backgrounds the initials badge flips to navy. */
.ds-auth-delivery__top .ds-company__logo--initials {
    background: var(--ds-navy);
    color: var(--ds-signal);
}

/* Sign-in pages are always light: readable text even if dark mode slips through. */
.ds-auth {
    color-scheme: light;
}

.ds-auth .fi-input-wrp {
    background-color: #fff;
}

.ds-auth .fi-input,
.ds-auth .fi-input-wrp input {
    color: var(--ds-navy);
    -webkit-text-fill-color: var(--ds-navy);
    caret-color: var(--ds-navy);
}

.ds-auth .fi-input::placeholder {
    color: #8b98a3;
    -webkit-text-fill-color: #8b98a3;
}

/* Safari / Chrome autofill keeps a readable white box. */
.ds-auth input:-webkit-autofill {
    -webkit-box-shadow: 0 0 0 1000px #fff inset;
    -webkit-text-fill-color: var(--ds-navy);
}

/* Uploaded company logo in the panel header. */
.ds-brand__mark--image {
    object-fit: contain;
    border-radius: 0.5rem;
    background: #fff;
}

.ds-brand__name {
    max-width: 11rem;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
}

/* Delivery attempts history (dispatcher view). */
.ds-attempts {
    display: flex;
    flex-direction: column;
    gap: 0.75rem;
}

.ds-attempts__item {
    padding: 0.875rem 1rem;
    border-radius: var(--ds-radius);
    background: rgb(14 36 51 / 0.04);
}

.dark .ds-attempts__item {
    background: rgb(255 255 255 / 0.05);
}

.ds-attempts__head {
    display: flex;
    flex-wrap: wrap;
    align-items: center;
    justify-content: space-between;
    gap: 0.5rem;
}

.ds-attempts__when,
.ds-attempts__who {
    font-size: 0.85rem;
    color: var(--ds-steel);
}

.ds-attempts__who {
    margin-top: 0.4rem;
}

.ds-attempts__note {
    margin-top: 0.4rem;
    font-size: 0.95rem;
}

.ds-attempts__photos {
    display: flex;
    flex-wrap: wrap;
    gap: 0.5rem;
    margin-top: 0.6rem;
}

.ds-attempts__photos img {
    width: 6rem;
    height: 6rem;
    object-fit: cover;
    border-radius: 0.5rem;
}

/* =================================================================
 * Driver dashboard (Delivery panel) — phone first.
 * ================================================================= */
.ds-driver {
    display: flex;
    flex-direction: column;
    gap: 1.25rem;
    max-width: 40rem;
    color: var(--ds-navy);
}

.dark .ds-driver {
    color: #fff;
}

.ds-driver h2 {
    margin: 0;
    font-size: 1.15rem;
    font-weight: 800;
    display: flex;
    align-items: center;
    gap: 0.5rem;
}

.ds-driver__muted {
    display: block;
    font-size: 0.78rem;
    color: #8fa3b3;
}

.ds-driver__soft {
    display: block;
    font-size: 0.85rem;
    color: var(--ds-steel);
}

/* Trip card */
.ds-driver__trip {
    background: var(--ds-navy);
    color: #fff;
    border-radius: 1.1rem;
    padding: 1.25rem;
    display: flex;
    flex-direction: column;
    gap: 1rem;
}

.ds-driver__trip .ds-driver__soft {
    color: #b7c4cf;
}

.ds-driver__trip-head {
    display: flex;
    justify-content: space-between;
    align-items: flex-start;
    gap: 0.75rem;
}

.ds-driver__trip-no {
    display: block;
    font-size: 1.9rem;
    font-weight: 900;
    letter-spacing: 0.01em;
    line-height: 1.1;
}

.ds-driver__pill {
    padding: 0.35rem 0.8rem;
    border-radius: 999px;
    background: var(--ds-signal);
    color: var(--ds-navy);
    font-size: 0.8rem;
    font-weight: 800;
    white-space: nowrap;
}

.ds-driver__trip-grid {
    display: grid;
    grid-template-columns: repeat(2, minmax(0, 1fr));
    gap: 0.75rem;
    font-size: 0.9rem;
}

.ds-driver__trip-grid strong {
    display: block;
    font-weight: 700;
}

.ds-driver__progress-head {
    display: flex;
    justify-content: space-between;
    align-items: baseline;
    margin-bottom: 0.5rem;
    color: #b7c4cf;
}

.ds-driver__progress-head strong {
    font-size: 1.75rem;
    font-weight: 900;
    color: #fff;
}

.ds-driver__left {
    font-weight: 700;
    color: var(--ds-signal);
}

.ds-driver__bar {
    height: 0.75rem;
    border-radius: 999px;
    background: rgb(255 255 255 / 0.12);
    overflow: hidden;
}

.ds-driver__bar > span {
    display: block;
    height: 100%;
    border-radius: inherit;
    background: var(--ds-signal);
}

.ds-driver__warn {
    margin-top: 0.6rem;
    font-size: 0.85rem;
    color: #ffd7d7;
}

/* All delivered */
.ds-driver__trip--done {
    background: var(--ds-ok);
}

.ds-driver__trip--done .ds-driver__bar {
    background: rgb(255 255 255 / 0.25);
}

.ds-driver__trip--done .ds-driver__bar > span {
    background: #fff;
}

.ds-driver__done-title {
    font-size: 1.8rem;
    font-weight: 900;
    line-height: 1.05;
}

.ds-driver__done-sub {
    color: #d4f0e4;
}

.ds-driver__card {
    background: #fff;
    border-radius: 1rem;
    padding: 1.1rem;
    box-shadow: 0 0 0 1px rgb(14 36 51 / 0.06);
    display: flex;
    flex-direction: column;
    gap: 0.6rem;
}

.dark .ds-driver__card {
    background: rgb(255 255 255 / 0.05);
}

/* Big buttons */
.ds-driver__actions {
    display: grid;
    grid-template-columns: repeat(2, minmax(0, 1fr));
    gap: 0.75rem;
}

.ds-driver__action {
    min-height: 4rem;
    border-radius: 0.9rem;
    display: flex;
    align-items: center;
    justify-content: center;
    gap: 0.6rem;
    font-weight: 800;
    font-size: 1rem;
    background: #fff;
    color: var(--ds-navy);
    box-shadow: inset 0 0 0 1.5px #d5dde3;
}

.ds-driver__action--primary {
    background: var(--ds-signal);
    box-shadow: none;
}

.ds-driver__action:focus-visible {
    outline: 3px solid var(--ds-navy);
    outline-offset: 2px;
}

/* Sections */
.ds-driver__section {
    display: flex;
    flex-direction: column;
    gap: 0.6rem;
}

.ds-driver__section-head {
    display: flex;
    justify-content: space-between;
    align-items: baseline;
    gap: 1rem;
}

.ds-driver__count {
    font-size: 0.8rem;
    padding: 0.1rem 0.55rem;
    border-radius: 999px;
    background: var(--ds-signal);
    color: var(--ds-navy);
}

/* Stop card */
.ds-stop {
    display: flex;
    align-items: center;
    gap: 0.75rem;
    padding: 0.85rem 0.9rem;
    border-radius: 0.9rem;
    background: #fff;
    box-shadow: 0 0 0 1px rgb(14 36 51 / 0.06);
}

.dark .ds-stop {
    background: rgb(255 255 255 / 0.05);
}

.ds-stop--priority {
    background: #fff8db;
    box-shadow: inset 0 0 0 1.5px var(--ds-signal);
}

.ds-stop--problem {
    box-shadow: inset 0 0 0 1.5px #f2c4c4;
}

.ds-stop--soft {
    background: var(--ds-deck);
    box-shadow: none;
}

.dark .ds-stop--priority,
.dark .ds-stop--soft {
    background: rgb(255 255 255 / 0.06);
}

.ds-stop__text {
    flex: 1;
    min-width: 0;
    display: flex;
    flex-direction: column;
    gap: 0.15rem;
}

.ds-stop__label {
    font-size: 0.8rem;
    font-weight: 700;
    color: #b02e2e;
}

.ds-stop__invoice {
    font-weight: 900;
    font-size: 1.02rem;
    word-break: break-word;
}

.ds-stop__name {
    font-weight: 700;
}

.ds-stop__address,
.ds-stop__remark {
    font-size: 0.88rem;
    color: #4a5865;
}

.dark .ds-stop__address,
.dark .ds-stop__remark {
    color: #b7c4cf;
}

.ds-stop__count {
    font-size: 0.82rem;
    font-weight: 700;
    color: #2f6f9f;
}

.ds-stop__call {
    width: 3rem;
    height: 3rem;
    flex: none;
    border-radius: 999px;
    display: grid;
    place-items: center;
    background: var(--ds-navy);
    color: #fff;
}

/* Areas */
.ds-driver__areas {
    background: #fff;
    border-radius: 1rem;
    overflow: hidden;
    box-shadow: 0 0 0 1px rgb(14 36 51 / 0.06);
}

.dark .ds-driver__areas {
    background: rgb(255 255 255 / 0.04);
}

.ds-driver__area + .ds-driver__area {
    border-top: 1px solid #e8edf1;
}

.ds-driver__area-btn {
    width: 100%;
    min-height: 4rem;
    padding: 0.75rem 1rem;
    display: flex;
    align-items: center;
    gap: 0.75rem;
    text-align: left;
}

.ds-driver__area-name {
    flex: 1;
    display: flex;
    flex-direction: column;
    gap: 0.1rem;
}

.ds-driver__area-name span,
.ds-driver__area-count span {
    font-size: 0.85rem;
    color: var(--ds-steel);
}

.ds-driver__area-count {
    display: flex;
    flex-direction: column;
    align-items: flex-end;
}

.ds-driver__area-count strong {
    font-size: 1.15rem;
    font-weight: 900;
}

.ds-driver__chev {
    color: var(--ds-steel);
    transition: transform 0.2s;
}

.ds-driver__chev.is-open {
    transform: rotate(180deg);
}

.ds-driver__stops {
    padding: 0 1rem 0.9rem;
    display: flex;
    flex-direction: column;
    gap: 0.5rem;
}

/* Delivered today */
.ds-driver__list {
    background: #fff;
    border-radius: 1rem;
    padding: 0.25rem 1rem;
    box-shadow: 0 0 0 1px rgb(14 36 51 / 0.06);
}

.dark .ds-driver__list {
    background: rgb(255 255 255 / 0.04);
}

.ds-driver__done-row {
    display: flex;
    align-items: center;
    gap: 0.75rem;
    padding: 0.75rem 0;
}

.ds-driver__done-row + .ds-driver__done-row {
    border-top: 1px solid #e8edf1;
}

.ds-driver__done-row img,
.ds-driver__nophoto {
    width: 3.25rem;
    height: 3.25rem;
    border-radius: 0.6rem;
    object-fit: cover;
    flex: none;
}

.ds-driver__nophoto {
    display: grid;
    place-items: center;
    background: #e4e9ed;
    color: var(--ds-steel);
}

.ds-driver__done-text {
    flex: 1;
    min-width: 0;
    display: flex;
    flex-direction: column;
}

.ds-driver__done-text span,
.ds-driver__done-when span:last-child {
    font-size: 0.85rem;
    color: var(--ds-steel);
}

.ds-driver__done-when {
    display: flex;
    flex-direction: column;
    align-items: flex-end;
}

.ds-driver__ok {
    font-size: 0.82rem;
    font-weight: 700;
    color: var(--ds-ok);
}

/* Not on a trip */
.ds-driver__empty {
    border: 2px dashed #c9d3da;
    border-radius: 1.1rem;
    padding: 2.25rem 1.5rem;
    display: flex;
    flex-direction: column;
    align-items: center;
    text-align: center;
    gap: 0.85rem;
}

.ds-driver__empty h2 {
    font-size: 1.35rem;
}

.ds-driver__empty p {
    max-width: 30ch;
    color: #4a5865;
}

.dark .ds-driver__empty p {
    color: #b7c4cf;
}

.ds-driver__empty-icon {
    width: 4.5rem;
    height: 4.5rem;
    border-radius: 1.25rem;
    display: grid;
    place-items: center;
    background: var(--ds-navy);
    color: var(--ds-signal);
}

@media (prefers-reduced-motion: reduce) {
    .ds-driver__chev {
        transition: none;
    }
}

/* Undo on "Delivered today" */
.ds-driver__done-when {
    gap: 0.3rem;
}

.ds-driver__undo {
    display: flex;
    align-items: center;
    gap: 0.4rem;
}

.ds-driver__undo > span {
    font-size: 0.75rem;
    color: var(--ds-steel);
}

.ds-driver__locked {
    display: inline-flex;
    align-items: center;
    gap: 0.25rem;
    font-size: 0.78rem;
    color: var(--ds-steel);
}

.ds-attempts__item--undo {
    border-left: 3px solid var(--ds-warn, #e08a00);
}

/* ------------------------------------------------------------------ trip board (Delivery Log widgets) */

.ds-board {
    display: flex;
    flex-direction: column;
    gap: 1rem;
}

.ds-board__cards {
    display: grid;
    grid-template-columns: repeat(4, minmax(0, 1fr));
    gap: 0.875rem;
}

@media (max-width: 1024px) {
    .ds-board__cards { grid-template-columns: repeat(2, minmax(0, 1fr)); }
}

.ds-board__card {
    display: flex;
    flex-direction: column;
    gap: 0.6rem;
    padding: 1rem 1.1rem;
    border-radius: var(--ds-radius-lg);
    background: #fff;
    box-shadow: 0 0 0 1px rgb(14 36 51 / 0.06);
    color: var(--ds-navy);
    text-decoration: none;
    transition: box-shadow 0.15s;
}

.ds-board__card:hover { box-shadow: 0 0 0 1px rgb(14 36 51 / 0.2); }
.ds-board__card:focus-visible { outline: 3px solid var(--ds-signal); outline-offset: 2px; }
.ds-board__card.is-active { box-shadow: inset 0 0 0 2px var(--ds-navy); }

.ds-board__card-head {
    display: flex;
    justify-content: space-between;
    align-items: center;
    font-size: 0.875rem;
    font-weight: 600;
    color: #4a5865;
}

.ds-board__card-value {
    font-size: 2.1rem;
    font-weight: 800;
    line-height: 1;
}

.ds-board__card-sub,
.ds-board__muted {
    font-size: 0.8rem;
    color: var(--ds-steel);
}

.ds-board__dot { width: 0.6rem; height: 0.6rem; border-radius: 999px; }
.ds-board__dot--navy { background: var(--ds-navy); }
.ds-board__dot--yellow { background: var(--ds-signal); }
.ds-board__dot--ok { background: var(--ds-ok); }
.ds-board__dot--bad { background: var(--ds-bad); }

.ds-board__bar {
    display: block;
    width: 100%;
    height: 0.4rem;
    border-radius: 999px;
    background: #e8edf1;
    overflow: hidden;
}

.ds-board__bar-fill { display: block; height: 100%; border-radius: 999px; background: var(--ds-navy); }
.ds-board__bar-fill--yellow { background: var(--ds-signal); }
.ds-board__bar-fill--ok { background: var(--ds-ok); }
.ds-board__bar-fill--warn { background: var(--ds-warn); }

.ds-board__panel {
    padding: 1.1rem 1.25rem;
    border-radius: var(--ds-radius-lg);
    background: #fff;
    box-shadow: 0 0 0 1px rgb(14 36 51 / 0.06);
    display: flex;
    flex-direction: column;
    gap: 0.75rem;
}

.ds-board__panel-head {
    display: flex;
    justify-content: space-between;
    align-items: baseline;
}

.ds-board__panel-head h2 { font-size: 1.05rem; font-weight: 800; color: var(--ds-navy); }
.ds-board__panel-head span { font-size: 0.8rem; color: var(--ds-steel); }

.ds-board__attention li {
    display: grid;
    grid-template-columns: 9.5rem minmax(0, 1fr) auto auto;
    gap: 1rem;
    align-items: center;
    padding: 0.7rem 0;
}

.ds-board__attention li + li { border-top: 1px solid #eef1f4; }

.ds-board__attention-text { font-size: 0.9rem; color: var(--ds-navy); }
.ds-board__detail { display: block; font-size: 0.8rem; color: #4a5865; }
.ds-board__truck { white-space: nowrap; }

@media (max-width: 768px) {
    .ds-board__attention li { grid-template-columns: 1fr auto; }
    .ds-board__attention-text { grid-column: 1 / -1; }
    .ds-board__truck { display: none; }
}

.ds-board__tag {
    padding: 0.2rem 0.6rem;
    border-radius: 999px;
    font-size: 0.75rem;
    font-weight: 700;
    text-align: center;
    background: #eef1f4;
    color: #4a5865;
}

.ds-board__tag--bad { background: #fdecea; color: var(--ds-bad); }
.ds-board__tag--warn { background: #fff1dc; color: #9a5b00; }

.ds-board__trends {
    display: grid;
    grid-template-columns: minmax(0, 1.6fr) minmax(0, 1fr);
    gap: 0.875rem;
}

@media (max-width: 1024px) {
    .ds-board__trends { grid-template-columns: 1fr; }
}

.ds-board__chart {
    display: flex;
    align-items: flex-end;
    gap: 0.4rem;
    height: 11rem;
}

.ds-board__col {
    flex: 1;
    display: flex;
    flex-direction: column;
    align-items: center;
    justify-content: flex-end;
    gap: 0.25rem;
    height: 100%;
}

.ds-board__col-n,
.ds-board__col-day { font-size: 0.7rem; color: var(--ds-steel); }

.ds-board__col-bar {
    width: 100%;
    max-width: 1.75rem;
    border-radius: 4px 4px 0 0;
    background: var(--ds-navy);
}

.ds-board__col-bar.is-today { background: var(--ds-signal); }
.ds-board__col-bar.is-zero { background: #d5dde3; }

.ds-board__reason { display: flex; flex-direction: column; gap: 0.25rem; }
.ds-board__reason .ds-board__bar { height: 0.5rem; background: #eef1f4; }
.ds-board__reason-row { display: flex; justify-content: space-between; font-size: 0.875rem; color: var(--ds-navy); }

.dark .ds-board__card,
.dark .ds-board__panel { background: #10283a; box-shadow: 0 0 0 1px rgb(255 255 255 / 0.08); color: #e6edf3; }
.dark .ds-board__card.is-active { box-shadow: inset 0 0 0 2px var(--ds-signal); }
.dark .ds-board__card-head,
.dark .ds-board__detail { color: #b7c4cf; }
.dark .ds-board__panel-head h2,
.dark .ds-board__attention-text,
.dark .ds-board__reason-row { color: #e6edf3; }
.dark .ds-board__attention li + li { border-color: rgb(255 255 255 / 0.08); }
.dark .ds-board__col-bar { background: #7fa3bf; }
.dark .ds-board__col-bar.is-today { background: var(--ds-signal); }

/* ------------------------------------------------------------------ install as an app (PWA) */

.ds-pwa-install { display: none; }
html[data-pwa-installable] .ds-pwa-install { display: block; }

.ds-pwa-sheet:not([hidden]) {
    position: fixed;
    inset: 0;
    z-index: 60;
    display: flex;
    align-items: flex-end;
    justify-content: center;
}

.ds-pwa-sheet__backdrop { position: absolute; inset: 0; background: rgb(14 36 51 / 0.45); }

.ds-pwa-sheet__panel {
    position: relative;
    width: 100%;
    max-width: 30rem;
    padding: 1.4rem 1.4rem calc(1.9rem + env(safe-area-inset-bottom));
    border-radius: 1.4rem 1.4rem 0 0;
    background: #fff;
    color: var(--ds-navy);
    display: flex;
    flex-direction: column;
    gap: 1rem;
}

.ds-pwa-sheet__grip { align-self: center; width: 2.5rem; height: 0.3rem; border-radius: 999px; background: #d5dde3; }
.ds-pwa-sheet__head { display: flex; gap: 0.9rem; align-items: center; }
.ds-pwa-sheet__head img { width: 3.5rem; height: 3.5rem; border-radius: 0.9rem; flex: none; }
.ds-pwa-sheet__head > span { display: flex; flex-direction: column; gap: 0.15rem; }
.ds-pwa-sheet__head strong { font-size: 1.1rem; }
.ds-pwa-sheet__head span span { font-size: 0.875rem; color: #4a5865; }

.ds-pwa-sheet__steps { display: flex; flex-direction: column; gap: 0.6rem; }

.ds-pwa-sheet__steps li {
    display: flex;
    gap: 0.75rem;
    align-items: center;
    padding: 0.75rem 0.9rem;
    border-radius: 0.75rem;
    background: var(--ds-deck);
    font-size: 0.95rem;
}

.ds-pwa-sheet__steps li > span:first-child {
    width: 1.75rem;
    height: 1.75rem;
    flex: none;
    border-radius: 999px;
    background: var(--ds-navy);
    color: var(--ds-signal);
    font-weight: 800;
    display: flex;
    align-items: center;
    justify-content: center;
}

.ds-pwa-share { display: inline-block; padding: 0 0.35rem; border: 1.5px solid #0a84ff; border-radius: 0.35rem; color: #0a84ff; font-size: 0.8rem; }

.ds-pwa-sheet__close,
.ds-pwa-offline button {
    height: 3.1rem;
    border-radius: 0.75rem;
    font: inherit;
    font-weight: 700;
    font-size: 1rem;
    cursor: pointer;
}

.ds-pwa-sheet__close { border: 1.5px solid #d5dde3; background: #fff; color: var(--ds-navy); }

.ds-pwa-offline:not([hidden]) {
    position: fixed;
    inset: 0;
    z-index: 70;
    display: flex;
    align-items: center;
    justify-content: center;
    padding: 1.75rem;
    background: var(--ds-deck);
    color: var(--ds-navy);
}

.ds-pwa-offline__body { width: 100%; max-width: 28rem; display: flex; flex-direction: column; gap: 1.1rem; }

.ds-pwa-offline__icon {
    width: 4.5rem;
    height: 4.5rem;
    border-radius: 1.4rem;
    background: #fff1dc;
    color: var(--ds-warn);
    display: flex;
    align-items: center;
    justify-content: center;
}

.ds-pwa-offline h2 { font-size: 1.75rem; font-weight: 800; line-height: 1.15; }
.ds-pwa-offline p { font-size: 1rem; line-height: 1.5; color: #4a5865; }

.ds-pwa-offline ul {
    padding: 0.9rem 1rem;
    border-radius: 0.9rem;
    background: #fff;
    box-shadow: 0 0 0 1px rgb(14 36 51 / 0.06);
    display: flex;
    flex-direction: column;
    gap: 0.6rem;
    font-size: 0.95rem;
}

.ds-pwa-offline li { display: flex; gap: 0.6rem; }
.ds-pwa-offline .is-ok { color: var(--ds-ok); font-weight: 800; }
.ds-pwa-offline .is-warn { color: var(--ds-warn); font-weight: 800; }
.ds-pwa-offline button { border: 0; background: var(--ds-signal); color: var(--ds-navy); font-weight: 800; height: 3.5rem; }
.ds-pwa-offline button[disabled] { background: #d5dde3; color: #4a5865; }

.ds-pwa-sheet button:focus-visible,
.ds-pwa-offline button:focus-visible { outline: 3px solid var(--ds-navy); outline-offset: 3px; }

/* App icon & favicon page */
.ds-icons-preview {
    display: flex;
    flex-wrap: wrap;
    align-items: center;
    gap: 1.25rem 2rem;
    padding: 1rem 1.25rem;
    border-radius: var(--ds-radius-lg);
    background: #fff;
    box-shadow: 0 0 0 1px rgb(14 36 51 / 0.06);
}

.ds-icons-preview__tab {
    display: flex;
    align-items: center;
    gap: 0.5rem;
    min-width: 12rem;
    padding: 0.5rem 0.9rem;
    border-radius: 0.6rem 0.6rem 0 0;
    background: var(--ds-deck);
    font-size: 0.85rem;
    color: var(--ds-navy);
}

.ds-icons-preview__phone {
    display: flex;
    flex-direction: column;
    align-items: center;
    gap: 0.4rem;
    padding: 0.9rem 1.2rem;
    border-radius: 1rem;
    background: linear-gradient(160deg, #2b4d66, #0e2433);
    color: #fff;
    font-size: 0.75rem;
}

.ds-icons-preview__phone img { border-radius: 0.9rem; }

.ds-icons-preview p {
    flex: 1 1 18rem;
    font-size: 0.85rem;
    line-height: 1.5;
    color: var(--ds-steel);
}

.dark .ds-icons-preview { background: #10283a; box-shadow: 0 0 0 1px rgb(255 255 255 / 0.08); }
.dark .ds-icons-preview__tab { background: #0e2433; color: #e6edf3; }
.dark .ds-icons-preview p { color: #b7c4cf; }

/* Scan progress: left, last scan, problems */
.ds-progress__meta {
    display: flex;
    flex-wrap: wrap;
    gap: 0.35rem 1rem;
    margin-top: 0.6rem;
    font-size: 0.85rem;
    color: var(--ds-steel);
}

.ds-progress__left { font-weight: 700; color: var(--ds-navy); }
.dark .ds-progress__left { color: var(--ds-signal); }
.ds-progress__problems { color: var(--ds-bad); font-weight: 600; }

/* Module boards (Containers, Vehicles, Invoice Issue) — extend the trip board styles */
.ds-board__card--static:hover { box-shadow: 0 0 0 1px rgb(14 36 51 / 0.06); }
.ds-board__card-value.is-alert { color: var(--ds-bad); }
.ds-board__dot--steel { background: var(--ds-steel); }
.ds-board__dot--warn { background: var(--ds-warn); }
.ds-board__bar-fill--teal { background: #3fa7b9; }
.ds-board__bar-fill--bad { background: var(--ds-bad); }
.ds-board__trends--even { grid-template-columns: repeat(2, minmax(0, 1fr)); }

@media (max-width: 1024px) {
    .ds-board__trends--even { grid-template-columns: 1fr; }
}

.ds-board__photos {
    display: grid;
    grid-template-columns: repeat(5, minmax(0, 1fr));
    gap: 0.75rem;
}

@media (max-width: 1024px) {
    .ds-board__photos { grid-template-columns: repeat(2, minmax(0, 1fr)); }
}

.ds-board__photos figure { position: relative; display: flex; flex-direction: column; gap: 0.4rem; margin: 0; }
.ds-board__photos img,
.ds-board__photo-none { width: 100%; height: 7rem; border-radius: 0.6rem; object-fit: cover; background: var(--ds-deck); }
.ds-board__photo-none { display: flex; align-items: center; justify-content: center; font-size: 0.8rem; color: var(--ds-steel); }
.ds-board__photos .ds-board__tag { position: absolute; left: 0.4rem; top: 0.4rem; }
.ds-board__photos figcaption { display: flex; flex-direction: column; font-size: 0.8rem; color: var(--ds-steel); }
.ds-board__photos figcaption strong { font-size: 0.9rem; color: var(--ds-navy); }
.dark .ds-board__photos figcaption strong { color: #e6edf3; }

/* Open issues slider (Invoice Issue widget) */
.ds-slider { display: flex; flex-direction: column; gap: 0.75rem; }
.ds-slider__viewport { overflow: hidden; margin: 0 -0.4rem; }
.ds-slider__track { display: flex; transition: transform 0.5s ease; }
.ds-slider__slide { flex: 0 0 25%; margin: 0; padding: 0 0.4rem; box-sizing: border-box; }

.ds-slider__card {
    height: 100%;
    display: flex;
    flex-direction: column;
    gap: 0.5rem;
    padding: 0.6rem;
    border-radius: 0.8rem;
    background: var(--ds-deck);
}

.ds-slider__photo { position: relative; }
.ds-slider__photo img,
.ds-slider__photo .ds-board__photo-none { width: 100%; height: 8.5rem; border-radius: 0.6rem; object-fit: cover; background: #e3e8ec; display: flex; }
.ds-slider__photo .ds-board__tag { position: absolute; left: 0.4rem; top: 0.4rem; }
.ds-slider__card figcaption { display: flex; flex-direction: column; gap: 0.15rem; font-size: 0.8rem; color: var(--ds-steel); flex: 1; }
.ds-slider__card figcaption strong { font-size: 0.95rem; color: var(--ds-navy); }
.ds-slider__note { color: #4a5865; line-height: 1.35; }

.ds-slider__controls { display: flex; align-items: center; justify-content: center; gap: 0.75rem; }

.ds-slider__arrow {
    width: 2.25rem;
    height: 2.25rem;
    border-radius: 999px;
    border: 1.5px solid #d5dde3;
    background: #fff;
    color: var(--ds-navy);
    display: flex;
    align-items: center;
    justify-content: center;
    cursor: pointer;
}

.ds-slider__dots { display: flex; gap: 0.4rem; }
.ds-slider__dot { width: 0.55rem; height: 0.55rem; border-radius: 999px; border: 0; padding: 0; background: #d5dde3; cursor: pointer; }
.ds-slider__dot.is-active { width: 1.4rem; background: var(--ds-navy); }
.ds-slider__arrow:focus-visible,
.ds-slider__dot:focus-visible { outline: 3px solid var(--ds-signal); outline-offset: 2px; }

.ds-slider__empty { display: flex; align-items: center; gap: 0.5rem; font-size: 0.9rem; color: var(--ds-ok); }

@media (prefers-reduced-motion: reduce) {
    .ds-slider__track { transition: none; }
}

.dark .ds-slider__card { background: #0e2433; }
.dark .ds-slider__card figcaption strong { color: #e6edf3; }
.dark .ds-slider__note { color: #b7c4cf; }
.dark .ds-slider__arrow { background: #10283a; border-color: rgb(255 255 255 / 0.15); color: #e6edf3; }
.dark .ds-slider__dot.is-active { background: var(--ds-signal); }
.ds-slider__counter { min-width: 4.5rem; text-align: center; font-size: 0.85rem; font-weight: 700; color: var(--ds-navy); font-variant-numeric: tabular-nums; }
.dark .ds-slider__counter { color: #e6edf3; }

/* Boxes by hub (Admin dashboard) */
.ds-board__dot--teal { background: #3fa7b9; }
.ds-hubs__head { display: flex; justify-content: space-between; align-items: flex-start; gap: 1rem; flex-wrap: wrap; }
.ds-hubs__head h2 { font-size: 1.05rem; font-weight: 800; color: var(--ds-navy); }
.ds-hubs__legend { display: flex; flex-wrap: wrap; gap: 0.35rem 1rem; margin-top: 0.35rem; font-size: 0.8rem; color: #4a5865; }
.ds-hubs__legend span { display: inline-flex; align-items: center; gap: 0.35rem; }
.ds-hubs__legend i { width: 0.75rem; height: 0.75rem; border-radius: 3px; }
.ds-hubs .is-wait { background: #3fa7b9; }
.ds-hubs .is-load { background: var(--ds-signal); }
.ds-hubs .is-out { background: var(--ds-navy); }
.ds-hubs .is-done { background: var(--ds-ok); }
.ds-hubs__sort { display: flex; gap: 0.35rem; }
.ds-hubs__sort button { height: 2rem; padding: 0 0.75rem; border-radius: 0.5rem; border: 0; background: #eef1f4; color: #4a5865; font-size: 0.8rem; font-weight: 700; cursor: pointer; }
.ds-hubs__sort button.is-active { background: var(--ds-navy); color: #fff; }
.ds-hubs__sort button:focus-visible, .ds-hubs__row:focus-visible { outline: 3px solid var(--ds-signal); outline-offset: 2px; }

.ds-hubs__table { display: flex; flex-direction: column; overflow-x: auto; }
.ds-hubs__row {
    display: grid;
    grid-template-columns: 13rem minmax(8rem, 1fr) 5rem 5rem 5.5rem 5.5rem 6.5rem 5rem;
    align-items: center;
    min-width: 54rem;
    padding: 0.7rem 0.25rem;
    border-top: 1px solid #f0f3f5;
    font-size: 0.9rem;
    color: var(--ds-navy);
    text-decoration: none;
    font-variant-numeric: tabular-nums;
}
.ds-hubs__row > span:nth-child(n + 3) { text-align: right; }
a.ds-hubs__row:hover { background: #f8fafb; }
.ds-hubs__row--head { border-top: 0; font-size: 0.75rem; font-weight: 600; color: var(--ds-steel); }
.ds-hubs__row--total { font-weight: 800; background: #f8fafb; border-top: 1px solid #e8edf1; }
.ds-hubs__name { display: flex; flex-direction: column; }
.ds-hubs__name small { font-size: 0.75rem; color: var(--ds-steel); }
.ds-hubs__bar { display: flex; align-items: center; gap: 0.6rem; padding-right: 1rem; }
.ds-hubs__bar b { min-width: 2.5rem; text-align: right; font-size: 0.85rem; }
.ds-hubs__track { flex: 1; display: flex; height: 0.85rem; border-radius: 4px; overflow: hidden; background: var(--ds-deck); }
.ds-hubs__track span { display: block; height: 100%; }
.ds-hubs .is-good { color: var(--ds-ok); font-weight: 700; background: none; }
.ds-hubs .is-muted { color: #4a5865; }
.ds-hubs .is-bad { color: var(--ds-bad); font-weight: 700; }

.dark .ds-hubs__row { color: #e6edf3; border-color: rgb(255 255 255 / 0.08); }
.dark a.ds-hubs__row:hover, .dark .ds-hubs__row--total { background: #0e2433; }
.dark .ds-hubs__head h2 { color: #e6edf3; }
.dark .ds-hubs .is-out { background: #7fa3bf; }
.dark .ds-hubs__track { background: #0e2433; }
.dark .ds-hubs__sort button { background: #0e2433; color: #b7c4cf; }
.dark .ds-hubs__sort button.is-active { background: var(--ds-signal); color: var(--ds-navy); }
.dark .ds-hubs .is-muted { color: #b7c4cf; }

/* Partner hub: your boxes as steps */
.ds-hubsteps { display: flex; flex-direction: column; gap: 0.75rem; }
.ds-hubsteps h2 { font-size: 1.05rem; font-weight: 800; color: var(--ds-navy); }
.ds-hubsteps__row { display: grid; grid-template-columns: repeat(4, minmax(0, 1fr)); gap: 0.75rem; counter-reset: step; }
@media (max-width: 900px) { .ds-hubsteps__row { grid-template-columns: repeat(2, minmax(0, 1fr)); } }
.ds-hubsteps__step {
    display: flex; flex-direction: column; gap: 0.35rem;
    padding: 1rem 1.1rem; border-radius: var(--ds-radius-lg); background: #fff;
    box-shadow: 0 0 0 1px rgb(14 36 51 / 0.06); border-top: 4px solid var(--ds-navy);
}
.ds-hubsteps__step.is-wait { border-top-color: #3fa7b9; }
.ds-hubsteps__step.is-load { border-top-color: var(--ds-signal); }
.ds-hubsteps__step.is-done { border-top-color: var(--ds-ok); }
.ds-hubsteps__label { font-size: 0.85rem; font-weight: 600; color: #4a5865; }
.ds-hubsteps__value { font-size: 2rem; font-weight: 800; line-height: 1; color: var(--ds-navy); font-variant-numeric: tabular-nums; }
.ds-hubsteps__sub, .ds-hubsteps__note { font-size: 0.8rem; color: var(--ds-steel); }
.ds-hubsteps__alert {
    display: flex; align-items: center; gap: 1rem; padding: 1rem 1.1rem;
    border-radius: var(--ds-radius-lg); background: #fff8db; box-shadow: 0 0 0 1px #f3d77a; color: var(--ds-navy);
}
.ds-hubsteps__alert > span { flex: 1; display: flex; flex-direction: column; gap: 0.15rem; font-size: 0.9rem; }
.ds-hubsteps__alert > span > span { color: #4a5865; }
@media (max-width: 640px) { .ds-hubsteps__alert { flex-wrap: wrap; } }
.dark .ds-hubsteps h2, .dark .ds-hubsteps__value { color: #e6edf3; }
.dark .ds-hubsteps__step { background: #10283a; box-shadow: 0 0 0 1px rgb(255 255 255 / 0.08); }
.dark .ds-hubsteps__label { color: #b7c4cf; }
.dark .ds-hubsteps__alert { background: rgb(120 90 0 / 0.25); box-shadow: 0 0 0 1px rgb(243 215 122 / 0.4); color: #e6edf3; }
.dark .ds-hubsteps__alert > span > span { color: #d8c690; }

/* ------------------------------------------------------------------ partner hub (Company) panel */
.ds-co { display: flex; flex-direction: column; gap: 1rem; }
.ds-co__h2 { font-size: 1.05rem; font-weight: 800; color: var(--ds-navy); margin-bottom: 1rem; }
.ds-co__link { font-size: 0.85rem; font-weight: 700; color: #2f6f9f; white-space: nowrap; }
.ds-co__num { font-variant-numeric: tabular-nums; }

.ds-co__tabs { display: flex; gap: 0.35rem; }
.ds-co__tabs button { height: 2.1rem; padding: 0 0.85rem; border-radius: 0.5rem; border: 0; background: #eef1f4; color: #4a5865; font-size: 0.85rem; font-weight: 700; cursor: pointer; }
.ds-co__tabs button.is-active { background: var(--ds-navy); color: #fff; }

.ds-co__empty { display: flex; flex-direction: column; align-items: center; gap: 0.35rem; padding: 2.5rem 1rem; border-radius: var(--ds-radius-lg); background: #fff; color: var(--ds-steel); text-align: center; box-shadow: 0 0 0 1px rgb(14 36 51 / 0.06); }
.ds-co__empty strong { color: var(--ds-navy); font-size: 1rem; }

/* incoming boxes */
.ds-co__areas { display: flex; flex-direction: column; gap: 0.5rem; }
.ds-co__area {
    display: grid; grid-template-columns: 1.4rem minmax(0, 1fr) minmax(6rem, 12rem) 4rem 8.5rem; gap: 1rem; align-items: center;
    width: 100%; padding: 0.8rem 1rem; border: 0; border-radius: 0.8rem; background: #fff; color: var(--ds-navy); text-align: left; cursor: pointer;
    box-shadow: 0 0 0 1px rgb(14 36 51 / 0.06);
}
.ds-co__area.is-on { background: #fff8db; box-shadow: inset 0 0 0 2px var(--ds-signal); }
.ds-co__area:focus-visible { outline: 3px solid var(--ds-signal); outline-offset: 2px; }
.ds-co__check { width: 1.4rem; height: 1.4rem; border-radius: 0.4rem; display: flex; align-items: center; justify-content: center; font-weight: 900; color: transparent; box-shadow: inset 0 0 0 2px #b7c4cf; }
.ds-co__area.is-on .ds-co__check { background: var(--ds-navy); color: var(--ds-signal); box-shadow: none; }
.ds-co__area-name { display: flex; flex-direction: column; min-width: 0; }
.ds-co__area-name small { font-size: 0.75rem; color: var(--ds-steel); overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.ds-co__age { justify-self: end; padding: 0.2rem 0.6rem; border-radius: 999px; font-size: 0.75rem; font-weight: 700; white-space: nowrap; }
.ds-co__age.is-ok { background: #e3f5ed; color: var(--ds-ok); }
.ds-co__age.is-warn { background: #fff1dc; color: #9a5b00; }
.ds-co__age.is-bad { background: #fdecea; color: var(--ds-bad); }
@media (max-width: 768px) { .ds-co__area { grid-template-columns: 1.4rem 1fr 3rem; } .ds-co__area .ds-board__bar, .ds-co__area .ds-co__age { display: none; } }

.ds-co__oldest { display: grid; grid-template-columns: 8rem 1fr 1.2fr 7rem 6rem; gap: 0.75rem; align-items: center; padding: 0.6rem 0; border-top: 1px solid #eef1f4; font-size: 0.9rem; }
.ds-co__oldest--head { border-top: 0; font-size: 0.75rem; font-weight: 600; color: var(--ds-steel); }

.ds-co__tripbar {
    position: sticky; bottom: 0.75rem; z-index: 5; display: flex; align-items: center; gap: 0.75rem;
    padding: 0.9rem 1.1rem; border-radius: var(--ds-radius-lg); background: var(--ds-navy); color: #fff;
}
.ds-co__tripbar > span { flex: 1; display: flex; flex-direction: column; }
.ds-co__tripbar strong { font-size: 1.05rem; }
.ds-co__tripbar small { color: #b7c4cf; font-size: 0.8rem; }

/* drivers */
.ds-co__driver { display: grid; grid-template-columns: 2rem 2.5rem minmax(0, 1fr) 5.5rem 9rem 6.5rem minmax(0, 1fr); gap: 0.85rem; align-items: center; padding: 0.7rem 0; border-top: 1px solid #eef1f4; font-size: 0.9rem; }
.ds-co__driver--head { border-top: 0; font-size: 0.75rem; font-weight: 600; color: var(--ds-steel); }
.ds-co__rank { font-weight: 800; color: #8a97a2; text-align: center; }
.ds-co__avatar { width: 2.5rem; height: 2.5rem; border-radius: 999px; background: #24465f; color: #fff; display: flex; align-items: center; justify-content: center; font-weight: 800; font-size: 0.85rem; text-transform: uppercase; }
.ds-co__rate { display: flex; flex-direction: column; gap: 0.25rem; }
.ds-co__rate b.is-ok { color: var(--ds-ok); }
.ds-co__rate b.is-warn { color: var(--ds-warn); }
@media (max-width: 900px) { .ds-co__driver { grid-template-columns: 2rem 2.5rem 1fr 4rem; } .ds-co__driver > :nth-child(n + 5) { display: none; } }

/* not delivered */
.ds-co__group { border-left: 4px solid var(--ds-warn); }
.ds-co__group.is-danger { border-left-color: var(--ds-bad); }
.ds-co__group.is-info, .ds-co__group.is-gray { border-left-color: #3fa7b9; }
.ds-co__group-head { display: flex; align-items: center; gap: 1rem; flex-wrap: wrap; }
.ds-co__group-head h2 { font-size: 1.05rem; font-weight: 800; color: var(--ds-navy); }
.ds-co__group-head h2 span { font-weight: 600; font-size: 0.9rem; color: var(--ds-steel); }
.ds-co__tip { flex: 1; font-size: 0.85rem; color: #4a5865; }
.ds-co__retry { display: grid; grid-template-columns: 7.5rem minmax(0, 1fr) minmax(0, 1fr) 4.5rem 7.5rem auto; gap: 0.75rem; align-items: center; padding: 0.55rem 0; border-top: 1px solid #eef1f4; font-size: 0.9rem; }
.ds-co__tries { font-size: 0.75rem; font-weight: 700; color: var(--ds-steel); }
.ds-co__tries.is-bad { color: var(--ds-bad); }
.ds-co__retry-actions { display: flex; gap: 0.4rem; justify-content: flex-end; }
@media (max-width: 900px) { .ds-co__retry { grid-template-columns: 1fr auto; } .ds-co__retry > :nth-child(n + 2):not(.ds-co__retry-actions) { display: none; } }

/* track a box */
.ds-co__search { display: flex; align-items: center; gap: 0.6rem; padding: 0.4rem 0.4rem 0.4rem 0.9rem; border-radius: 0.8rem; background: #fff; box-shadow: 0 0 0 2px var(--ds-signal); color: var(--ds-steel); }
.ds-co__search input { flex: 1; min-width: 0; border: 0; background: transparent; font-size: 1.05rem; font-weight: 600; color: var(--ds-navy); outline: none; box-shadow: none; }
.ds-co__search--small { box-shadow: 0 0 0 1px #d5dde3; padding: 0.15rem 0.75rem; width: 15rem; }
.ds-co__search--small input { font-size: 0.9rem; font-weight: 500; padding: 0.45rem 0; }
.ds-co__track { display: grid; grid-template-columns: minmax(0, 1fr) 20rem; gap: 1rem; align-items: start; }
@media (max-width: 1024px) { .ds-co__track { grid-template-columns: 1fr; } }
.ds-co__timeline { display: flex; flex-direction: column; }
.ds-co__timeline li { position: relative; display: grid; grid-template-columns: 1.6rem minmax(0, 1fr) auto; gap: 0.75rem; padding-bottom: 1.1rem; }
.ds-co__timeline li:not(:last-child)::before { content: ''; position: absolute; left: 0.5rem; top: 1.2rem; bottom: 0; width: 2px; background: #e3e8ec; }
.ds-co__dot { width: 1.1rem; height: 1.1rem; margin-top: 0.15rem; border-radius: 999px; background: #fff; box-shadow: inset 0 0 0 3px #b7c4cf; z-index: 1; }
.ds-co__timeline li.is-ok .ds-co__dot { background: var(--ds-ok); box-shadow: none; }
.ds-co__timeline li.is-warn .ds-co__dot { background: var(--ds-warn); box-shadow: none; }
.ds-co__event { display: flex; flex-direction: column; gap: 0.15rem; font-size: 0.9rem; color: var(--ds-navy); }
.ds-co__event > span { color: #4a5865; font-size: 0.85rem; }
.ds-co__event img { margin-top: 0.4rem; width: 10rem; height: 6.5rem; object-fit: cover; border-radius: 0.6rem; }
.ds-co__timeline time { font-size: 0.8rem; white-space: nowrap; }
.ds-co__boxcard { gap: 0.4rem; }
.ds-co__boxno { font-size: 1.3rem; color: var(--ds-navy); }
.ds-co__boxcard dl { display: grid; gap: 0.2rem; margin-top: 0.5rem; padding-top: 0.75rem; border-top: 1px solid #eef1f4; font-size: 0.9rem; }
.ds-co__boxcard dt { color: var(--ds-steel); font-size: 0.8rem; margin-top: 0.4rem; }
.ds-co__boxcard dd { color: var(--ds-navy); }
.ds-co__boxcard dd a { font-weight: 700; color: #2f6f9f; margin-left: 0.4rem; }
.ds-co__status { align-self: flex-start; padding: 0.2rem 0.7rem; border-radius: 999px; font-size: 0.8rem; font-weight: 800; background: #e6edf3; color: var(--ds-navy); white-space: nowrap; }
.ds-co__status.is-ok, .ds-co__status.is-done { background: #e3f5ed; color: var(--ds-ok); }
.ds-co__status.is-loading { background: #fff6d6; color: #8a6a00; }

/* dashboard */
.ds-co__hello { display: flex; align-items: center; gap: 0.75rem; flex-wrap: wrap; margin-bottom: 0.5rem; }
.ds-co__hello > div { flex: 1; min-width: 14rem; }
.ds-co__hello-title { font-size: 1.6rem; font-weight: 800; color: var(--ds-navy); line-height: 1.2; }
.ds-co__today { display: grid; grid-template-columns: minmax(0, 1.5fr) minmax(0, 1fr); gap: 0.875rem; align-items: start; }
.ds-co__today--even { grid-template-columns: repeat(2, minmax(0, 1fr)); }
@media (max-width: 1024px) { .ds-co__today, .ds-co__today--even { grid-template-columns: 1fr; } }
.ds-co__trip { display: grid; grid-template-columns: 2.5rem minmax(0, 1fr) 10rem 6.5rem; gap: 0.85rem; align-items: center; padding: 0.65rem 0; border-top: 1px solid #eef1f4; }
.ds-co__trip .ds-co__status { justify-self: end; }
@media (max-width: 640px) { .ds-co__trip { grid-template-columns: 2.5rem 1fr; } .ds-co__trip > :nth-child(n + 3) { grid-column: 2; justify-self: start; } }
.ds-co__attn { display: grid; grid-template-columns: auto minmax(0, 1fr) auto; gap: 0.75rem; align-items: center; padding: 0.55rem 0; border-top: 1px solid #eef1f4; font-size: 0.85rem; }

.dark .ds-co__area, .dark .ds-co__empty { background: #10283a; color: #e6edf3; box-shadow: 0 0 0 1px rgb(255 255 255 / 0.08); }
.dark .ds-co__area.is-on { background: rgb(246 190 0 / 0.12); }
.dark .ds-co__hello-title, .dark .ds-co__h2, .dark .ds-co__group-head h2, .dark .ds-co__event, .dark .ds-co__boxno, .dark .ds-co__boxcard dd, .dark .ds-co__empty strong { color: #e6edf3; }
.dark .ds-co__search { background: #10283a; }
.dark .ds-co__search input { color: #e6edf3; }
.dark .ds-co__tabs button { background: #0e2433; color: #b7c4cf; }
.dark .ds-co__tabs button.is-active { background: var(--ds-signal); color: var(--ds-navy); }
.dark .ds-co__driver, .dark .ds-co__retry, .dark .ds-co__trip, .dark .ds-co__attn, .dark .ds-co__oldest { border-color: rgb(255 255 255 / 0.08); }
.ds-co__clear { height: 2.25rem; padding: 0 0.9rem; border-radius: 0.5rem; border: 1.5px solid rgb(255 255 255 / 0.35); background: transparent; color: #fff; font-weight: 700; font-size: 0.85rem; cursor: pointer; }
.ds-co__clear:hover { background: rgb(255 255 255 / 0.1); }

/* ------------------------------------------------------------------ box photos */
.ds-ph { display: flex; flex-direction: column; gap: 0.7rem; margin-top: 0.9rem; padding: 0.9rem 1rem; border-radius: var(--ds-radius); background: #fff; box-shadow: 0 0 0 1px rgb(14 36 51 / 0.08); }
.ds-ph__cond > span { display: block; font-size: 0.8rem; font-weight: 700; color: var(--ds-navy); margin-bottom: 0.4rem; }
.ds-ph__cond > div { display: grid; grid-template-columns: repeat(4, 1fr); gap: 0.4rem; }
.ds-ph__chip { min-height: 2.5rem; border-radius: 0.6rem; font-size: 0.85rem; font-weight: 700; background: #e3f5ed; color: #17895e; }
.ds-ph__chip.is-damaged { background: #fdecea; color: #cf3b3b; }
.ds-ph__chip.is-wet { background: #e3f0fb; color: #1f6fb2; }
.ds-ph__chip.is-open { background: #fff1dc; color: #9a5b00; }
.ds-ph__chip.is-on { color: #fff; background: #17895e; }
.ds-ph__chip.is-damaged.is-on { background: #cf3b3b; }
.ds-ph__chip.is-wet.is-on { background: #1f6fb2; }
.ds-ph__chip.is-open.is-on { background: #9a5b00; }
.ds-ph__tip { margin: 0; padding: 0.55rem 0.75rem; border-radius: 0.6rem; background: #fff8db; color: #6b4a00; font-size: 0.82rem; }
.ds-ph__note { width: 100%; border: 1px solid #d5dce2; border-radius: 0.6rem; padding: 0.5rem 0.7rem; font-size: 0.875rem; background: #fff; color: var(--ds-navy); }
.ds-ph__shots { display: flex; flex-wrap: wrap; align-items: center; gap: 0.4rem; }
.ds-ph__shots img { width: 3.5rem; height: 3.5rem; object-fit: cover; border-radius: 0.5rem; }
.ds-ph__shots span { font-size: 0.78rem; color: var(--ds-steel); margin-left: 0.25rem; }
.ds-ph__add { display: flex; align-items: center; justify-content: center; gap: 0.5rem; min-height: 2.9rem; border-radius: 0.7rem; background: var(--ds-navy); color: #fff; font-weight: 700; }
.ds-ph__add:disabled { opacity: 0.7; }
.ds-ph__batch { display: flex; align-items: center; gap: 0.5rem; padding: 0.6rem 0.75rem; border-radius: 0.6rem; background: var(--ds-navy); color: #fff; font-size: 0.82rem; }
.ds-ph__batch span { flex: 1; }
.ds-ph__batch button { padding: 0.4rem 0.8rem; border-radius: 0.5rem; background: var(--ds-signal); color: var(--ds-navy); font-weight: 800; }
.ds-ph__batch button.is-skip { background: #24465f; color: #fff; }
.ds-ph__err { margin: 0; color: var(--ds-bad); font-size: 0.82rem; }
.ds-gm__status.is-good { color: var(--ds-ok); }
.ds-gm__status.is-damaged { color: var(--ds-bad); }
.ds-gm__status.is-wet { color: #1f6fb2; }
.ds-gm__status.is-open { color: var(--ds-warn); }
.ds-phs { display: flex; flex-direction: column; gap: 0.75rem; }
.ds-phs__big { width: 100%; max-height: 26rem; object-fit: contain; border-radius: var(--ds-radius); background: #000; }
.ds-phs__thumbs { display: flex; flex-wrap: wrap; gap: 0.5rem; }
.ds-phs__thumbs button { width: 6rem; border-radius: 0.5rem; overflow: hidden; opacity: 0.7; text-align: left; font-size: 0.7rem; background: var(--ds-deck); }
.ds-phs__thumbs button.is-on { opacity: 1; box-shadow: 0 0 0 3px var(--ds-signal); }
.ds-phs__thumbs img { width: 100%; height: 4.2rem; object-fit: cover; }
.ds-phs__thumbs span { display: block; padding: 0.15rem 0.35rem; color: var(--ds-navy); }
.ds-ps__row { display: grid; grid-template-columns: auto 1fr auto; align-items: center; padding: 0.55rem 0; border-top: 1px solid #eef1f4; }
/* layout helpers used by the photo pages */
.ds-tp { display: flex; flex-direction: column; gap: 1rem; }
.ds-tp__recent { display: flex; flex-direction: column; margin: 0; padding: 0; list-style: none; }
.ds-tp__recent li { display: grid; grid-template-columns: minmax(0, 1fr) auto minmax(0, 1fr); gap: 0.75rem; padding: 0.45rem 0; border-top: 1px solid #eef1f4; font-size: 0.85rem; }
.ds-gm input[type=number] { border: 1px solid #d5dce2; border-radius: 0.5rem; padding: 0.4rem 0.6rem; background: #fff; color: var(--ds-navy); font-size: 0.875rem; }
.ds-gm__field { display: flex; flex-direction: column; gap: 0.3rem; font-size: 0.8rem; color: var(--ds-steel); }
.ds-gm__grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(14rem, 1fr)); gap: 0.9rem; }
.ds-gm__check { display: flex; align-items: center; gap: 0.6rem; font-size: 0.875rem; }
.ds-gm__save { display: flex; justify-content: flex-end; }
.ds-gm__status { font-size: 0.78rem; font-weight: 600; color: var(--ds-steel); }

/* ------------------------------------------------------------------ Box Photos (v2) */
.ds-bp {
    --bp-bg: #f3f5f7; --bp-surf: #ffffff; --bp-raised: #f6f8fa; --bp-line: rgb(14 36 51 / 0.09);
    --bp-text: #0e2433; --bp-muted: #5b6b78; --bp-pill-on: #0e2433; --bp-pill-on-text: #ffffff;
    --bp-ok: #17895e; --bp-bad: #d64236; --bp-wet: #2f7fc4; --bp-warn: #b97412; --bp-gold: #f6be00;
    --bp-shadow: 0 18px 40px rgb(14 36 51 / 0.08);
    display: flex; flex-direction: column; gap: 1.1rem; color: var(--bp-text); padding-bottom: 6rem;
}
.dark .ds-bp {
    --bp-surf: #122230; --bp-raised: #172b3a; --bp-line: rgb(255 255 255 / 0.08);
    --bp-text: #e9eff3; --bp-muted: #8ea2b0; --bp-pill-on: #e9eff3; --bp-pill-on-text: #0b1620;
    --bp-ok: #2fb37f; --bp-bad: #ef5a4f; --bp-wet: #4f9be0; --bp-warn: #e8a33a; --bp-shadow: 0 18px 40px rgb(0 0 0 / 0.35);
}
.ds-bp__head { display: flex; align-items: flex-end; justify-content: space-between; gap: 1.25rem; flex-wrap: wrap; }
.ds-bp__head h1 { margin: 0; font-size: 2.1rem; font-weight: 900; letter-spacing: -0.02em; line-height: 1.1; }
.ds-bp__head p { margin: 0.35rem 0 0; color: var(--bp-muted); }
.ds-bp__stats { display: flex; gap: 0.5rem; }
.ds-bp__stats span { display: flex; flex-direction: column; align-items: flex-end; padding: 0.5rem 0.9rem; border-radius: 0.9rem; background: var(--bp-surf); box-shadow: inset 0 0 0 1px var(--bp-line); }
.ds-bp__stats strong { font-size: 1.25rem; font-variant-numeric: tabular-nums; line-height: 1.1; }
.ds-bp__stats small { font-size: 0.72rem; color: var(--bp-muted); }
.ds-bp__stats .is-bad strong { color: var(--bp-bad); }
.ds-bp__stats .is-wet strong { color: var(--bp-wet); }
.ds-bp__search { display: flex; align-items: center; gap: 0.85rem; height: 3.9rem; padding: 0 1.2rem; border-radius: 1.1rem; background: var(--bp-surf); color: var(--bp-muted);
    box-shadow: inset 0 0 0 1px var(--bp-line), 0 0 0 4px rgb(246 190 0 / 0.12); }
.ds-bp__search:focus-within { box-shadow: inset 0 0 0 2px var(--bp-gold), 0 0 0 5px rgb(246 190 0 / 0.18); }
.ds-bp__search input { flex: 1; min-width: 0; border: 0; outline: 0; background: transparent; color: var(--bp-text); font-size: 1.15rem; font-weight: 700; letter-spacing: 0.01em; }
.ds-bp__search input::placeholder { color: var(--bp-muted); font-weight: 500; }
.ds-bp__search input::-webkit-search-cancel-button { display: none; }
.ds-bp__clear { width: 1.9rem; height: 1.9rem; border-radius: 50%; background: var(--bp-raised); color: var(--bp-muted); font-size: 0.75rem; }
.ds-bp__hint { font-size: 0.75rem; padding: 0.3rem 0.6rem; border-radius: 0.5rem; background: var(--bp-raised); white-space: nowrap; }
.ds-bp__empty { display: flex; flex-direction: column; align-items: center; gap: 0.6rem; padding: 4.5rem 1.25rem; border-radius: 1.5rem; background: var(--bp-surf); box-shadow: inset 0 0 0 1px var(--bp-line); text-align: center; }
.ds-bp__empty.is-small { padding: 2.5rem 1.25rem; }
.ds-bp__empty-icon { display: grid; place-items: center; width: 4rem; height: 4rem; border-radius: 1.25rem; background: var(--bp-raised); color: var(--bp-gold); margin-bottom: 0.4rem; }
.ds-bp__empty h2 { margin: 0; font-size: 1.35rem; font-weight: 800; letter-spacing: -0.01em; }
.ds-bp__empty p { margin: 0; max-width: 30rem; color: var(--bp-muted); line-height: 1.5; }
.ds-bp__recent { display: flex; flex-wrap: wrap; justify-content: center; align-items: center; gap: 0.45rem; margin-top: 0.5rem; }
.ds-bp__recent span { font-size: 0.8rem; color: var(--bp-muted); }
.ds-bp__recent button { height: 2.1rem; padding: 0 0.85rem; border-radius: 0.65rem; background: var(--bp-raised); box-shadow: inset 0 0 0 1px var(--bp-line); font-weight: 700; font-size: 0.85rem; color: var(--bp-text); }
.ds-bp__pills { display: flex; flex-wrap: wrap; align-items: center; gap: 0.45rem; }
.ds-bp__pills button { display: inline-flex; align-items: center; gap: 0.4rem; height: 2.2rem; padding: 0 0.9rem; border-radius: 999px; font-size: 0.82rem; font-weight: 700;
    background: var(--bp-surf); color: var(--bp-text); box-shadow: inset 0 0 0 1px var(--bp-line); }
.ds-bp__pills button.is-on { background: var(--bp-pill-on); color: var(--bp-pill-on-text); box-shadow: none; }
.ds-bp__sep { width: 1px; height: 1.4rem; margin: 0 0.3rem; background: var(--bp-line); }
.ds-bp__dot { display: inline-block; width: 0.55rem; height: 0.55rem; border-radius: 50%; background: var(--bp-muted); flex: none; }
.ds-bp__dot.is-ok { background: var(--bp-ok); box-shadow: 0 0 0 3px color-mix(in srgb, var(--bp-ok) 22%, transparent); }
.ds-bp__dot.is-bad { background: var(--bp-bad); box-shadow: 0 0 0 3px color-mix(in srgb, var(--bp-bad) 22%, transparent); }
.ds-bp__dot.is-wet { background: var(--bp-wet); box-shadow: 0 0 0 3px color-mix(in srgb, var(--bp-wet) 22%, transparent); }
.ds-bp__dot.is-warn { background: var(--bp-warn); box-shadow: 0 0 0 3px color-mix(in srgb, var(--bp-warn) 22%, transparent); }
.ds-bp__count { margin: 0; font-size: 0.82rem; color: var(--bp-muted); }
.ds-bp__layout { display: grid; grid-template-columns: minmax(0, 1fr) minmax(20rem, 29rem); gap: 1.25rem; align-items: start; }
.ds-bp__list { display: flex; flex-direction: column; gap: 0.8rem; min-width: 0; }
.ds-bp__box { display: flex; flex-direction: column; gap: 0.9rem; padding: 1.1rem 1.25rem; border-radius: 1.15rem; background: var(--bp-surf); box-shadow: inset 0 0 0 1px var(--bp-line); transition: box-shadow 0.15s; }
.ds-bp__box.is-open { box-shadow: 0 0 0 2px var(--bp-gold), var(--bp-shadow); }
.ds-bp__boxhead { display: grid; grid-template-columns: auto auto auto 1fr; align-items: center; gap: 0.3rem 0.6rem; text-align: left; color: inherit; }
.ds-bp__inv { font-size: 1.3rem; font-weight: 800; letter-spacing: -0.01em; font-variant-numeric: tabular-nums; }
.ds-bp__n { justify-self: end; grid-column: 4; font-size: 0.78rem; color: var(--bp-muted); }
.ds-bp__who { grid-column: 1 / -1; font-size: 0.82rem; color: var(--bp-muted); }
.ds-bp__chip { display: inline-flex; align-items: center; padding: 0.15rem 0.6rem; border-radius: 999px; font-size: 0.72rem; font-weight: 800; color: var(--bp-muted); background: var(--bp-raised); }
.ds-bp__chip.is-ok { color: var(--bp-ok); background: color-mix(in srgb, var(--bp-ok) 14%, transparent); }
.ds-bp__chip.is-bad { color: var(--bp-bad); background: color-mix(in srgb, var(--bp-bad) 14%, transparent); }
.ds-bp__chip.is-wet { color: var(--bp-wet); background: color-mix(in srgb, var(--bp-wet) 14%, transparent); }
.ds-bp__chip.is-warn { color: var(--bp-warn); background: color-mix(in srgb, var(--bp-warn) 14%, transparent); }
.ds-bp__journey { display: flex; flex-wrap: wrap; align-items: center; gap: 0.4rem 0; margin: 0; padding: 0; list-style: none; }
.ds-bp__journey li { display: inline-flex; align-items: center; gap: 0.45rem; font-size: 0.76rem; font-weight: 600; color: var(--bp-muted); }
.ds-bp__journey li + li::before { content: ''; width: 1.4rem; height: 2px; margin: 0 0.45rem; background: var(--bp-line); border-radius: 2px; }
.ds-bp__thumbs { display: flex; flex-wrap: wrap; gap: 0.6rem; }
.ds-bp__thumb { position: relative; display: flex; flex-direction: column; gap: 0.3rem; width: 6.5rem; }
.ds-bp__img { position: relative; display: block; width: 6.5rem; height: 4.8rem; border-radius: 0.75rem; overflow: hidden; background: var(--bp-raised); }
.ds-bp__img img { width: 100%; height: 100%; object-fit: cover; }
.ds-bp__img .ds-bp__dot { position: absolute; left: 0.45rem; bottom: 0.45rem; }
.ds-bp__thumb.is-cur .ds-bp__img { outline: 2px solid var(--bp-gold); outline-offset: 2px; }
.ds-bp__thumb small { font-size: 0.68rem; color: var(--bp-muted); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
.ds-bp__tick { position: absolute; right: 0.35rem; top: 0.35rem; display: grid; place-items: center; width: 1.4rem; height: 1.4rem; border-radius: 0.45rem; font-size: 0.75rem; font-weight: 900;
    background: rgb(11 22 32 / 0.5); color: transparent; box-shadow: inset 0 0 0 1.5px rgb(255 255 255 / 0.85); }
.ds-bp__thumb.is-sel .ds-bp__tick { background: var(--bp-gold); color: #0e2433; box-shadow: none; }
.ds-bp__card { display: flex; flex-direction: column; gap: 0.75rem; padding: 0.85rem 0.95rem; border-radius: 0.95rem; }
.ds-bp__card.is-ok { --c: var(--bp-ok); }
.ds-bp__card.is-warn { --c: var(--bp-warn); }
.ds-bp__card { background: color-mix(in srgb, var(--c) 9%, transparent); box-shadow: inset 0 0 0 1px color-mix(in srgb, var(--c) 35%, transparent); }
.ds-bp__cardhead { display: flex; align-items: center; gap: 0.7rem; }
.ds-bp__cardhead > span:nth-child(2) { flex: 1; min-width: 0; display: flex; flex-direction: column; }
.ds-bp__cardhead strong { color: var(--c); font-size: 0.92rem; }
.ds-bp__cardhead small { font-size: 0.75rem; color: var(--bp-muted); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
.ds-bp__cardhead em { font-style: normal; font-size: 0.75rem; color: var(--bp-muted); }
.ds-bp__badge { display: grid; place-items: center; width: 2rem; height: 2rem; border-radius: 0.65rem; background: var(--c); color: #0b1620; font-weight: 900; flex: none; }
.ds-bp__cardnote { margin: 0; font-size: 0.8rem; color: var(--bp-muted); font-style: italic; }
.ds-bp__viewer { position: sticky; top: 5rem; display: flex; flex-direction: column; gap: 0.85rem; padding: 0.9rem; border-radius: 1.35rem; background: var(--bp-surf); box-shadow: inset 0 0 0 1px var(--bp-line); }
.ds-bp__big { position: relative; aspect-ratio: 4 / 3; border-radius: 0.9rem; overflow: hidden; background: #000; }
.ds-bp__big img { width: 100%; height: 100%; object-fit: contain; }
.ds-bp__pos { position: absolute; right: 0.6rem; top: 0.6rem; padding: 0.2rem 0.55rem; border-radius: 999px; background: rgb(14 36 51 / 0.72); color: #fff; font-size: 0.75rem; font-variant-numeric: tabular-nums; }
.ds-bp__nav { position: absolute; top: 50%; transform: translateY(-50%); width: 2.2rem; height: 2.2rem; border-radius: 50%; background: rgb(14 36 51 / 0.6); color: #fff; font-size: 1.3rem; line-height: 1; }
.ds-bp__nav.is-prev { left: 0.6rem; }
.ds-bp__nav.is-next { right: 0.6rem; }
.ds-bp__strip { display: flex; gap: 0.45rem; overflow-x: auto; }
.ds-bp__strip button { flex: none; width: 4.4rem; height: 3.3rem; border-radius: 0.6rem; overflow: hidden; opacity: 0.55; }
.ds-bp__strip button.is-on { opacity: 1; outline: 2px solid var(--bp-gold); outline-offset: 2px; }
.ds-bp__strip img { width: 100%; height: 100%; object-fit: cover; }
.ds-bp__vhead { display: flex; align-items: flex-start; justify-content: space-between; gap: 0.75rem; }
.ds-bp__vhead > span:first-child { display: flex; flex-direction: column; gap: 0.15rem; min-width: 0; }
.ds-bp__vhead strong { font-size: 1.05rem; }
.ds-bp__vhead small { font-size: 0.8rem; color: var(--bp-muted); }
.ds-bp__quote { margin: 0; padding: 0.6rem 0.85rem; border-radius: 0.7rem; background: var(--bp-raised); font-style: italic; font-size: 0.88rem; border-left: 3px solid var(--bp-gold); }
.ds-bp__meta { display: grid; grid-template-columns: 6rem 1fr; gap: 0.45rem 0.75rem; margin: 0; font-size: 0.85rem; }
.ds-bp__meta dt { color: var(--bp-muted); }
.ds-bp__meta dd { margin: 0; overflow-wrap: anywhere; }
.ds-bp__meta .is-mono { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: 0.8rem; }
.ds-bp__vactions { display: grid; grid-template-columns: 1fr 1fr; gap: 0.5rem; }
.ds-bp__vactions a, .ds-bp__vactions button { display: flex; align-items: center; justify-content: center; height: 2.6rem; border-radius: 0.75rem; font-size: 0.88rem; font-weight: 700;
    background: var(--bp-raised); color: var(--bp-text); box-shadow: inset 0 0 0 1px var(--bp-line); }
.ds-bp__del { align-self: flex-start; font-size: 0.8rem; color: var(--bp-bad); text-decoration: underline; }
.ds-bp__dock { position: fixed; left: 50%; bottom: 1.5rem; z-index: 40; transform: translateX(-50%); display: flex; align-items: center; gap: 0.6rem; padding: 0.55rem 0.55rem 0.55rem 0.85rem;
    border-radius: 1.25rem; background: #0e2433; color: #fff; box-shadow: 0 24px 60px rgb(0 0 0 / 0.4), inset 0 0 0 1px rgb(255 255 255 / 0.08); }
.ds-bp__dockn { display: grid; place-items: center; min-width: 1.9rem; height: 1.9rem; padding: 0 0.4rem; border-radius: 999px; background: var(--bp-gold); color: #0e2433; font-weight: 900; font-variant-numeric: tabular-nums; }
.ds-bp__docktext { display: flex; flex-direction: column; margin-right: 1rem; }
.ds-bp__docktext small { font-size: 0.72rem; color: #9fb3c1; }
.ds-bp__dock > button { height: 2.5rem; padding: 0 0.95rem; border-radius: 0.8rem; font-weight: 700; font-size: 0.88rem; }
.ds-bp__dock > .is-ghost { color: #9fb3c1; }
.ds-bp__dock > .is-dark { background: #24465f; color: #fff; }
.ds-bp__panel { padding: 1rem 1.2rem; border-radius: 1.15rem; background: var(--bp-surf); box-shadow: inset 0 0 0 1px var(--bp-line); }
.ds-bp__panel h3 { margin: 0 0 0.4rem; font-size: 0.95rem; font-weight: 800; }
.ds-bp__mails { margin: 0; padding: 0; list-style: none; }
.ds-bp__mails li { display: grid; grid-template-columns: minmax(0, 1fr) auto minmax(0, 1fr); gap: 0.75rem; padding: 0.5rem 0; border-top: 1px solid var(--bp-line); font-size: 0.85rem; }
.ds-bp__mails small { color: var(--bp-muted); text-align: right; }
@media (max-width: 64rem) { .ds-bp__layout { grid-template-columns: 1fr; } .ds-bp__viewer { position: static; order: -1; } }
@media (max-width: 40rem) { .ds-bp__hint, .ds-bp__stats { display: none; } .ds-bp__dock { left: 0.75rem; right: 0.75rem; transform: none; flex-wrap: wrap; } }
.ds-phs__link { font-size: 0.8rem; text-decoration: underline; }

/* ------------------------------------------------------------------ Scan app (/scan) */
.fi-panel-scan, .fi-panel-scan .fi-layout, .fi-panel-scan .fi-main-ctn { background: #0a1219; }
.fi-panel-scan .fi-main { padding: 0 !important; max-width: none !important; }
.fi-panel-scan .fi-page > .fi-header, .fi-panel-scan .fi-page-header-main-ctn > .fi-header { display: none; }
.fi-panel-scan .fi-page-content, .fi-panel-scan .fi-page-main { gap: 0 !important; }
.ds-sa {
    --sa-text: #eef3f6; --sa-muted: #7f93a1; --sa-line: rgb(255 255 255 / 0.07); --sa-glass: rgb(255 255 255 / 0.045);
    --sa-gold: #f6be00; --sa-ok: #34c38f; --sa-bad: #ff6b5e; --sa-wet: #5aa8ff; --sa-warn: #f0a93b;
    position: fixed; inset: 0; z-index: 20; overflow: hidden auto; color: var(--sa-text); font-feature-settings: 'tnum';
    background: radial-gradient(120% 70% at 0% 0%, #15293a 0%, #0a1219 55%);
    -webkit-tap-highlight-color: transparent;
}
.ds-sa button { cursor: pointer; }
.ds-sa__screen { min-height: 100%; box-sizing: border-box; display: flex; flex-direction: column; gap: 1.25rem; max-width: 34rem; margin: 0 auto;
    padding: calc(env(safe-area-inset-top) + 1.25rem) 1.35rem calc(env(safe-area-inset-bottom) + 1.5rem); animation: sa-in .35s ease-out; }
@keyframes sa-in { from { opacity: 0; transform: translateY(8px); } to { opacity: 1; transform: none; } }
@keyframes sa-up { from { transform: translateY(100%); } to { transform: none; } }
@keyframes sa-pulse { from { box-shadow: 0 0 0 0 rgb(52 195 143 / 0.55); } to { box-shadow: 0 0 0 22px rgb(52 195 143 / 0); } }
@keyframes sa-shake { 0%,100% { transform: none; } 20% { transform: translateX(-8px); } 40% { transform: translateX(7px); } 60% { transform: translateX(-5px); } 80% { transform: translateX(3px); } }
@keyframes sa-sweep { 0% { top: 12%; opacity: 0; } 15%, 85% { opacity: 1; } 100% { top: 86%; opacity: 0; } }
@keyframes sa-ring { from { stroke-dashoffset: 302; } }
.ds-sa__hello { display: flex; align-items: center; justify-content: space-between; gap: 1rem; }
.ds-sa__hello > span:first-child { display: flex; flex-direction: column; gap: 0.25rem; }
.ds-sa__hello small { font-size: 0.875rem; color: var(--sa-muted); }
.ds-sa__hello strong { font-size: 1.85rem; font-weight: 700; letter-spacing: -0.025em; line-height: 1.15; }
.ds-sa__avatar { display: grid; place-items: center; width: 2.75rem; height: 2.75rem; border-radius: 50%; flex: none; font-weight: 800; color: #0a1219; background: linear-gradient(135deg, #f6be00, #e08a00); }
.ds-sa__today { display: flex; align-items: center; gap: 1.1rem; padding: 1.1rem; border-radius: 1.6rem; background: var(--sa-glass); box-shadow: inset 0 0 0 1px var(--sa-line); }
.ds-sa__today dl { flex: 1; display: grid; grid-template-columns: 1fr auto; gap: 0.6rem 0.75rem; margin: 0; font-size: 0.9rem; }
.ds-sa__today dt { color: var(--sa-muted); }
.ds-sa__today dd { margin: 0; font-weight: 700; }
.ds-sa .is-bad { color: #ff8a7e; }
.ds-sa__ring { position: relative; flex: none; width: 5.25rem; height: 5.25rem; }
.ds-sa__ring svg { width: 100%; height: 100%; transform: rotate(-90deg); }
.ds-sa__ring circle { fill: none; stroke-width: 9; }
.ds-sa__ring .is-track { stroke: rgb(255 255 255 / 0.08); }
.ds-sa__ring .is-fill { stroke: var(--sa-gold); stroke-linecap: round; stroke-dasharray: 289; transition: stroke-dashoffset .6s cubic-bezier(.2,.8,.2,1); }
.ds-sa__ring .is-fill.is-ok { stroke: var(--sa-ok); animation: sa-ring 1.1s cubic-bezier(.2,.8,.2,1); }
.ds-sa__ring > span { position: absolute; inset: 0; display: flex; flex-direction: column; align-items: center; justify-content: center; }
.ds-sa__ring > span strong { font-size: 1.35rem; letter-spacing: -0.02em; }
.ds-sa__ring > span small { font-size: 0.65rem; color: var(--sa-muted); }
.ds-sa__ring.is-small { width: 3.25rem; height: 3.25rem; }
.ds-sa__ring.is-small circle { stroke-width: 10; }
.ds-sa__ring.is-small b { font-size: 0.72rem; }
.ds-sa__ring.is-tiny { width: 3rem; height: 3rem; }
.ds-sa__ring.is-tiny circle { stroke-width: 11; }
.ds-sa__ring.is-big { width: 9.5rem; height: 9.5rem; align-self: center; margin-top: 1.5rem; }
.ds-sa__ring.is-big circle { stroke-width: 7; }
.ds-sa__ring.is-big i { display: grid; place-items: center; width: 4.75rem; height: 4.75rem; border-radius: 50%; background: rgb(52 195 143 / 0.14); color: var(--sa-ok); }
.ds-sa__ring.is-big i svg { width: 2.4rem; height: 2.4rem; transform: none; }
.ds-sa__label { margin: 0 0 -0.6rem; font-size: 0.8rem; font-weight: 600; color: var(--sa-muted); }
.ds-sa__list { display: flex; flex-direction: column; border-radius: 1.6rem; background: var(--sa-glass); box-shadow: inset 0 0 0 1px var(--sa-line); overflow: hidden; }
.ds-sa__row { display: flex; align-items: center; gap: 0.9rem; width: 100%; padding: 0.95rem 1rem; text-align: left; color: inherit; transition: background .2s, transform .12s; }
.ds-sa__row + .ds-sa__row { box-shadow: inset 0 1px 0 var(--sa-line); }
.ds-sa__row:active { background: rgb(255 255 255 / 0.05); transform: scale(.99); }
.ds-sa__chip { display: grid; place-items: center; width: 2.65rem; height: 2.65rem; border-radius: 0.9rem; flex: none; color: var(--sa-gold); background: rgb(246 190 0 / 0.1); box-shadow: inset 0 0 0 1px rgb(246 190 0 / 0.18); }
.ds-sa__chip svg { width: 1.25rem; height: 1.25rem; }
.ds-sa__rowtext { flex: 1; display: flex; flex-direction: column; gap: 0.1rem; }
.ds-sa__rowtext strong { font-size: 1rem; }
.ds-sa__rowtext small { font-size: 0.8rem; color: var(--sa-muted); }
.ds-sa__chev { font-size: 1.5rem; color: #4f6472; line-height: 1; }
.ds-sa__foot { margin-top: auto; display: flex; align-items: center; justify-content: space-between; gap: 0.75rem; font-size: 0.8rem; color: var(--sa-muted); }
.ds-sa__online { display: inline-flex; align-items: center; gap: 0.5rem; }
.ds-sa__online i { width: 0.45rem; height: 0.45rem; border-radius: 50%; background: var(--sa-ok); box-shadow: 0 0 0 4px rgb(52 195 143 / 0.18); }
.ds-sa__footlinks { display: flex; gap: 0.9rem; }
.ds-sa__footlinks button { color: var(--sa-muted); text-decoration: underline; }
.ds-sa__footlinks .ds-pwa-install { display: none; }
html[data-pwa-installable] .ds-sa__footlinks .ds-pwa-install { display: inline; }
.ds-sa__note { padding: 0.9rem 1rem; border-radius: 1.1rem; background: rgb(255 255 255 / 0.035); font-size: 0.875rem; color: #a9b8c2; line-height: 1.5; }
.ds-sa__pill { align-self: flex-start; display: inline-flex; align-items: center; gap: 0.4rem; height: 2.4rem; padding: 0 0.9rem 0 0.7rem; border-radius: 999px; background: rgb(255 255 255 / 0.06); color: inherit; font-weight: 600; font-size: 0.875rem; }
.ds-sa__title { display: flex; flex-direction: column; gap: 0.25rem; }
.ds-sa__title small { font-size: 0.875rem; color: var(--sa-muted); }
.ds-sa__title strong { font-size: 1.75rem; font-weight: 700; letter-spacing: -0.025em; }
.ds-sa__choice { display: flex; align-items: center; gap: 0.9rem; width: 100%; padding: 1.1rem; border-radius: 1.5rem; text-align: left; color: inherit; background: var(--sa-glass); box-shadow: inset 0 0 0 1px var(--sa-line); animation: sa-in .35s ease-out both; transition: transform .12s; }
.ds-sa__choice:active { transform: scale(.98); }
.ds-sa__choicetext { flex: 1; min-width: 0; display: flex; flex-direction: column; gap: 0.3rem; }
.ds-sa__choicetext strong { font-size: 1.1rem; letter-spacing: -0.01em; }
.ds-sa__choicetext small { font-size: 0.8rem; color: var(--sa-muted); }
.ds-sa__choicetext .is-num { color: #c9d5dc; }
.ds-sa__scan { padding: 0; max-width: none; gap: 0; position: relative; min-height: 100dvh; }
.ds-sa__cam { position: absolute; inset: 0; background: radial-gradient(90% 60% at 50% 38%, #2a3a45, #0b141b 75%); overflow: hidden; }
.ds-sa__cam video { position: absolute; inset: 0; width: 100%; height: 100%; object-fit: cover; }
.ds-sa__frame { position: absolute; left: 50%; top: 38%; width: min(72vw, 17rem); height: min(46vw, 11rem); transform: translate(-50%, -50%); }
.ds-sa__frame i { position: absolute; width: 2.1rem; height: 2.1rem; border: 3px solid #fff; transition: border-color .15s; }
.ds-sa__frame i:nth-child(1) { left: 0; top: 0; border-right: 0; border-bottom: 0; border-top-left-radius: 1.1rem; }
.ds-sa__frame i:nth-child(2) { right: 0; top: 0; border-left: 0; border-bottom: 0; border-top-right-radius: 1.1rem; }
.ds-sa__frame i:nth-child(3) { left: 0; bottom: 0; border-right: 0; border-top: 0; border-bottom-left-radius: 1.1rem; }
.ds-sa__frame i:nth-child(4) { right: 0; bottom: 0; border-left: 0; border-top: 0; border-bottom-right-radius: 1.1rem; }
.ds-sa__frame.is-hit i { border-color: var(--sa-ok); }
.ds-sa__sweep { position: absolute; left: 0.75rem; right: 0.75rem; height: 2px; border-radius: 2px; background: linear-gradient(90deg, transparent, var(--sa-gold), transparent); box-shadow: 0 0 14px var(--sa-gold); animation: sa-sweep 2.4s ease-in-out infinite; }
.ds-sa__camtext { position: absolute; left: 1.5rem; right: 1.5rem; top: 58%; margin: 0; text-align: center; font-size: 0.875rem; color: rgb(238 243 246 / 0.8); }
.ds-sa__camtext.is-error, .ds-sa__camtext.is-hint { top: 60%; padding: 0.6rem 0.8rem; border-radius: 0.8rem; background: rgb(10 18 25 / 0.75); color: #ffd8d3; }
.ds-sa__controls { position: absolute; left: 0; right: 0; bottom: 0; display: flex; flex-direction: column; gap: 1rem; padding: 1rem 1.25rem calc(env(safe-area-inset-bottom) + 1.6rem); background: linear-gradient(180deg, transparent, rgb(10 18 25 / 0.85) 40%); }
.ds-sa__type { display: flex; align-items: center; height: 3rem; padding: 0 0.35rem 0 1rem; border-radius: 1rem; background: rgb(10 18 25 / 0.6); backdrop-filter: blur(14px); -webkit-backdrop-filter: blur(14px); box-shadow: inset 0 0 0 1px rgb(255 255 255 / 0.1); }
.ds-sa__type input { flex: 1; min-width: 0; border: 0; outline: 0; background: transparent; color: var(--sa-text); font-size: 1rem; font-weight: 600; }
.ds-sa__type input::placeholder { color: var(--sa-muted); font-weight: 500; }
.ds-sa__type button { width: 2.4rem; height: 2.4rem; border-radius: 0.75rem; background: rgb(255 255 255 / 0.1); color: var(--sa-text); font-size: 1.1rem; }
.ds-sa__buttons { display: grid; grid-template-columns: 1fr auto 1fr; align-items: center; justify-items: center; }
.ds-sa__round { grid-column: 1; display: grid; place-items: center; width: 3.25rem; height: 3.25rem; border-radius: 50%; background: rgb(255 255 255 / 0.1); backdrop-filter: blur(10px); color: var(--sa-text); }
.ds-sa__round svg { width: 1.35rem; height: 1.35rem; }
.ds-sa__round.is-on { background: var(--sa-gold); color: #0a1219; }
.ds-sa__round.is-text { grid-column: 3; font-size: 0.78rem; font-weight: 700; }
.ds-sa__shutter { grid-column: 2; display: grid; place-items: center; width: 5.4rem; height: 5.4rem; border-radius: 50%; box-shadow: 0 0 0 4px rgb(255 255 255 / 0.9); transition: transform .12s; }
.ds-sa__shutter:active { transform: scale(.94); }
.ds-sa__shutter > span { display: grid; place-items: center; width: 4.4rem; height: 4.4rem; border-radius: 50%; background: rgb(255 255 255 / 0.15); color: #fff; transition: background .25s; }
.ds-sa__shutter > span.is-live { background: var(--sa-gold); color: #0a1219; }
.ds-sa__shutter svg { width: 1.75rem; height: 1.75rem; }
.ds-sa__bar { position: absolute; top: calc(env(safe-area-inset-top) + 0.75rem); left: 1rem; right: 1rem; z-index: 2; display: flex; align-items: center; gap: 0.75rem; padding: 0.5rem; border-radius: 1.5rem;
    background: rgb(10 18 25 / 0.55); backdrop-filter: blur(18px); -webkit-backdrop-filter: blur(18px); box-shadow: inset 0 0 0 1px rgb(255 255 255 / 0.08); }
.ds-sa__back { display: grid; place-items: center; width: 2.5rem; height: 2.5rem; border-radius: 50%; flex: none; background: rgb(255 255 255 / 0.08); color: var(--sa-text); font-size: 1.3rem; }
.ds-sa__bartext { flex: 1; min-width: 0; display: flex; flex-direction: column; }
.ds-sa__bartext small { font-size: 0.75rem; color: #9fb0bc; }
.ds-sa__bartext strong { font-size: 0.95rem; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
.ds-sa__count { display: flex; flex-direction: column; align-items: flex-end; padding-right: 0.5rem; }
.ds-sa__count strong { font-size: 1.05rem; }
.ds-sa__count small { font-size: 0.7rem; color: #9fb0bc; }
.ds-sa__sheet { position: fixed; left: 0; right: 0; bottom: 0; z-index: 25; max-width: 34rem; margin: 0 auto; display: flex; flex-direction: column; gap: 0.95rem; padding: 0.6rem 1.25rem calc(env(safe-area-inset-bottom) + 1.6rem);
    border-radius: 1.9rem 1.9rem 0 0; background: rgb(15 24 32 / 0.985); backdrop-filter: blur(24px); -webkit-backdrop-filter: blur(24px);
    box-shadow: 0 -20px 50px rgb(0 0 0 / 0.45), inset 0 1px 0 rgb(255 255 255 / 0.08); animation: sa-up .38s cubic-bezier(.2,.9,.2,1); }
.ds-sa__sheet.is-bad { background: rgb(32 16 18 / 0.985); box-shadow: 0 -20px 50px rgb(0 0 0 / 0.45), inset 0 1px 0 rgb(255 107 94 / 0.25); }
.ds-sa__sheet.is-warn { background: rgb(34 26 12 / 0.985); }
.ds-sa__grab { align-self: center; width: 2.5rem; height: 0.3rem; border-radius: 3px; background: rgb(255 255 255 / 0.2); }
.ds-sa__hit { display: flex; align-items: center; gap: 0.85rem; }
.ds-sa__hit > span:nth-child(2) { flex: 1; min-width: 0; display: flex; flex-direction: column; gap: 0.15rem; }
.ds-sa__hit strong { font-size: 1.7rem; letter-spacing: -0.02em; line-height: 1.05; overflow-wrap: anywhere; }
.ds-sa__hit small { font-size: 0.82rem; color: #6fd6ad; }
.ds-sa__sheet.is-bad .ds-sa__hit small { color: #ff9d93; }
.ds-sa__sheet.is-warn .ds-sa__hit small { color: #f3c98a; }
.ds-sa__hit em { font-style: normal; padding: 0.3rem 0.7rem; border-radius: 999px; background: rgb(255 255 255 / 0.07); font-size: 0.75rem; font-weight: 600; color: #c9d5dc; }
.ds-sa__hit.is-shake { animation: sa-shake .45s ease-in-out .3s; }
.ds-sa__mark { display: grid; place-items: center; width: 3.1rem; height: 3.1rem; border-radius: 50%; flex: none; font-weight: 900; font-size: 1.4rem; }
.ds-sa__mark svg { width: 1.5rem; height: 1.5rem; }
.ds-sa__mark.is-ok { background: var(--sa-ok); color: #0a1219; animation: sa-pulse 1s ease-out; }
.ds-sa__mark.is-bad { background: var(--sa-bad); color: #fff; }
.ds-sa__mark.is-warn { background: var(--sa-warn); color: #0a1219; }
.ds-sa__msg { margin: 0; font-size: 0.95rem; line-height: 1.5; color: #e9cfcc; }
.ds-sa__who { display: flex; align-items: center; gap: 0.75rem; padding: 0.75rem 0.9rem; border-radius: 1.1rem; background: rgb(255 255 255 / 0.04); }
.ds-sa__who > span:first-child { display: grid; place-items: center; width: 2.25rem; height: 2.25rem; border-radius: 50%; flex: none; background: rgb(255 255 255 / 0.08); font-size: 0.8rem; font-weight: 700; }
.ds-sa__who > span:last-child { display: flex; flex-direction: column; min-width: 0; }
.ds-sa__who small { font-size: 0.8rem; color: var(--sa-muted); }
.ds-sa__seg { position: relative; display: grid; grid-template-columns: repeat(4, 1fr); padding: 4px; border-radius: 1rem; background: rgb(255 255 255 / 0.05); }
.ds-sa__segthumb { position: absolute; top: 4px; bottom: 4px; width: calc((100% - 8px) / 4); border-radius: 0.75rem; transition: left .28s cubic-bezier(.2,.9,.2,1), background .28s; background: var(--sa-ok); }
.ds-sa__segthumb.is-damaged { background: var(--sa-bad); }
.ds-sa__segthumb.is-wet { background: var(--sa-wet); }
.ds-sa__segthumb.is-open { background: var(--sa-warn); }
.ds-sa__seg button { position: relative; z-index: 1; display: flex; align-items: center; justify-content: center; gap: 0.35rem; height: 2.65rem; font-size: 0.8rem; font-weight: 700; color: #c9d5dc; transition: color .2s; }
.ds-sa__seg button.is-on { color: #0a1219; }
.ds-sa__seg i { width: 0.45rem; height: 0.45rem; border-radius: 50%; }
.ds-sa__seg i.is-good { background: var(--sa-ok); }
.ds-sa__seg i.is-damaged { background: var(--sa-bad); }
.ds-sa__seg i.is-wet { background: var(--sa-wet); }
.ds-sa__seg i.is-open { background: var(--sa-warn); }
.ds-sa__seg button.is-on i { background: #0a1219; }
.ds-sa__note-in { height: 2.9rem; padding: 0 1rem; border: 0; border-radius: 0.9rem; background: rgb(255 255 255 / 0.06); color: var(--sa-text); font-size: 0.95rem; box-shadow: inset 0 0 0 1px rgb(255 255 255 / 0.08); }
.ds-sa__photos { display: flex; flex-wrap: wrap; align-items: center; gap: 0.6rem; }
.ds-sa__shot img { width: 3.5rem; height: 3.5rem; border-radius: 0.9rem; object-fit: cover; box-shadow: inset 0 0 0 1px rgb(255 255 255 / 0.15); animation: sa-in .25s ease-out; }
.ds-sa__addphoto { flex: 1; min-width: 10rem; display: flex; align-items: center; justify-content: center; gap: 0.5rem; height: 3.5rem; border-radius: 1rem; background: rgb(255 255 255 / 0.06); box-shadow: inset 0 0 0 1px rgb(255 255 255 / 0.1); color: var(--sa-text); font-weight: 600; }
.ds-sa__addphoto svg { width: 1.25rem; height: 1.25rem; }
.ds-sa__err { width: 100%; margin: 0; font-size: 0.8rem; color: #ff9d93; }
.ds-sa__primary { height: 3.6rem; border-radius: 1.15rem; background: var(--sa-gold); color: #0a1219; font-size: 1.05rem; font-weight: 700; transition: transform .12s; }
.ds-sa__secondary { height: 3rem; border-radius: 1rem; background: rgb(255 255 255 / 0.06); color: var(--sa-text); font-size: 0.95rem; font-weight: 600; }
.ds-sa__primary:active, .ds-sa__secondary:active { transform: scale(.98); }
.ds-sa__sheet .fi-btn { height: 3.4rem; border-radius: 1.1rem; }
.ds-sa__done { align-items: stretch; text-align: center; }
.ds-sa__done h2 { margin: 0.5rem 0 0; font-size: 1.75rem; font-weight: 700; letter-spacing: -0.025em; }
.ds-sa__done > p { margin: 0; color: var(--sa-muted); }
.ds-sa__totals { display: grid; grid-template-columns: repeat(3, 1fr); margin-top: 0.75rem; border-radius: 1.4rem; background: var(--sa-glass); box-shadow: inset 0 0 0 1px var(--sa-line); }
.ds-sa__totals span { display: flex; flex-direction: column; gap: 0.15rem; padding: 1rem 0.4rem; }
.ds-sa__totals span + span { box-shadow: inset 1px 0 0 var(--sa-line); }
.ds-sa__totals strong { font-size: 1.5rem; }
.ds-sa__totals small { font-size: 0.75rem; color: var(--sa-muted); }
.ds-sa__done .ds-sa__note { text-align: left; }
.ds-sa__done .ds-sa__primary { margin-top: auto; }
@media (prefers-reduced-motion: reduce) { .ds-sa *, .ds-sa *::before { animation: none !important; transition: none !important; } }
/* scan app sign-in */
.ds-auth--scan .ds-auth-delivery__top h1 { max-width: 14ch; }
.ds-sa__waiting { padding: 0.2rem 0.6rem; border-radius: 999px; font-size: 0.72rem; font-weight: 700; color: var(--sa-gold); background: rgb(246 190 0 / 0.12); white-space: nowrap; }
.ds-sa__waiting.is-none { color: var(--sa-muted); background: rgb(255 255 255 / 0.05); }
.ds-sa__choice.is-finished { opacity: 0.5; }
.ds-sa__choice.is-finished .ds-sa__ring .is-fill { stroke: var(--sa-ok); }
.ds-sa__more { align-self: center; padding: 0.5rem 1rem; border-radius: 999px; font-size: 0.85rem; font-weight: 600; color: var(--sa-muted); text-decoration: underline; }

/* ------------------------------------------------------------------ Driver app (delivery home) */
.fi-panel-delivery .fi-main:has(.ds-dr) { padding: 0 !important; max-width: none !important; }
.fi-panel-delivery .fi-page:has(.ds-dr) .fi-header { display: none; }
.ds-sa__avatar.is-green { background: linear-gradient(135deg, #34c38f, #1f9a6c); }
.ds-sa__ring.is-mid { width: 6rem; height: 6rem; }
.ds-sa__ring.is-mid > span strong { font-size: 1.5rem; }
.ds-sa__ring.is-mid > span small { font-size: 0.6rem; text-align: center; max-width: 4.5rem; line-height: 1.2; }
.ds-sa__ring .is-fill.is-green { stroke: var(--sa-ok); }
.ds-sa__today dd.is-ok { color: #6fd6ad; }
.ds-sa__today dd.is-warn { color: var(--sa-warn); }
.ds-dr__scanbtn { display: flex; align-items: center; justify-content: center; gap: 0.6rem; height: 4rem; border-radius: 1.4rem; font-size: 1.1rem; font-weight: 800; box-shadow: 0 14px 34px rgb(246 190 0 / 0.22); }
.ds-dr__scanbtn svg { width: 1.5rem; height: 1.5rem; }
.ds-dr__labelrow { display: flex; justify-content: space-between; align-items: baseline; margin-bottom: -0.6rem; }
.ds-dr__labelrow .ds-sa__label { margin: 0; }
.ds-dr__labelrow button { color: var(--sa-gold); font-size: 0.82rem; font-weight: 700; }
.ds-sa__list.is-warn { box-shadow: inset 0 0 0 1px rgb(240 169 59 / 0.35); }
.ds-sa__list.is-warn .ds-sa__rowtext strong { color: #f3c98a; }
.ds-dr__done { cursor: default; }
.ds-dr__thumb { width: 2.6rem; height: 2.6rem; border-radius: 0.7rem; object-fit: cover; flex: none; }
.ds-dr__undo { padding: 0.45rem 0.7rem; border-radius: 0.7rem; background: rgb(255 255 255 / 0.08); color: var(--sa-text); font-size: 0.75rem; font-weight: 700; white-space: nowrap; }
.ds-dr__office { font-size: 0.72rem; color: var(--sa-muted); white-space: nowrap; }
.ds-dr__crew { display: flex; flex-direction: column; gap: 0.5rem; padding: 0.75rem 0.9rem; border-radius: 1.1rem; background: rgb(255 255 255 / 0.035); font-size: 0.82rem; color: #a9b8c2; }
.ds-dr__crew span { display: flex; align-items: center; gap: 0.6rem; }
.ds-dr__crew i { display: grid; place-items: center; width: 1.9rem; height: 1.9rem; border-radius: 50%; background: rgb(255 255 255 / 0.08); font-style: normal; font-weight: 700; font-size: 0.7rem; color: var(--sa-text); }
.ds-dr__celebrate { display: flex; flex-direction: column; align-items: center; gap: 0.5rem; text-align: center; padding: 1rem 0; }
.ds-dr__celebrate strong { font-size: 1.5rem; letter-spacing: -0.02em; }
.ds-dr__celebrate p { margin: 0; color: var(--sa-muted); }
.ds-sa__empty { display: flex; flex-direction: column; align-items: center; gap: 0.6rem; padding: 3rem 1rem; text-align: center; border-radius: 1.6rem; background: var(--sa-glass); box-shadow: inset 0 0 0 1px var(--sa-line); }
.ds-sa__empty-icon { display: grid; place-items: center; width: 3.5rem; height: 3.5rem; border-radius: 1.1rem; background: rgb(246 190 0 / 0.1); color: var(--sa-gold); }
.ds-sa__empty-icon svg { width: 1.6rem; height: 1.6rem; }
.ds-sa__empty strong { font-size: 1.2rem; }
.ds-sa__empty p { margin: 0; color: var(--sa-muted); font-size: 0.9rem; line-height: 1.5; }
.ds-dr__listhead { display: flex; align-items: center; gap: 0.7rem; }
.ds-dr__listhead strong { flex: 1; font-size: 1.6rem; font-weight: 700; letter-spacing: -0.025em; }
.ds-dr__scanmini { display: grid; place-items: center; width: 2.75rem; height: 2.75rem; border-radius: 0.9rem; background: var(--sa-gold); color: #0a1219; }
.ds-dr__scanmini svg { width: 1.25rem; height: 1.25rem; }
.ds-dr__search { display: flex; align-items: center; gap: 0.6rem; height: 3rem; padding: 0 0.9rem; border-radius: 1rem; background: rgb(255 255 255 / 0.05); box-shadow: inset 0 0 0 1px var(--sa-line); color: var(--sa-muted); }
.ds-dr__search svg { width: 1.1rem; height: 1.1rem; flex: none; }
.ds-dr__search input { flex: 1; min-width: 0; border: 0; outline: 0; background: transparent; color: var(--sa-text); font-size: 1rem; }
.ds-dr__search input::-webkit-search-cancel-button { filter: invert(1); }
.ds-sa__seg.is-3 { grid-template-columns: repeat(3, 1fr); }
.ds-sa__seg.is-3 .ds-sa__segthumb { width: calc((100% - 8px) / 3); }
.ds-sa__segthumb.is-light { background: var(--sa-text); }
.ds-sa__seg.is-3 button { font-size: 0.74rem; }
.ds-dr__rows { display: flex; flex-direction: column; gap: 0.6rem; }
.ds-dr__card { display: flex; align-items: center; gap: 0.75rem; padding: 0.85rem 1rem; border-radius: 1.25rem; background: var(--sa-glass); box-shadow: inset 0 0 0 1px var(--sa-line); animation: sa-in .3s ease-out both; }
.ds-dr__cardmain { flex: 1; min-width: 0; display: flex; flex-direction: column; gap: 0.15rem; text-align: left; color: inherit; }
.ds-dr__cardtop { display: flex; align-items: baseline; gap: 0.5rem; }
.ds-dr__cardtop strong { font-size: 1rem; }
.ds-dr__cardtop em { font-style: normal; font-size: 0.7rem; font-weight: 700; padding: 0.1rem 0.5rem; border-radius: 999px; color: #c9d5dc; background: rgb(255 255 255 / 0.07); }
.ds-dr__cardtop em.is-ok { color: #6fd6ad; background: rgb(52 195 143 / 0.14); }
.ds-dr__cardtop em.is-warn { color: #f3c98a; background: rgb(240 169 59 / 0.14); }
.ds-dr__name { font-size: 0.9rem; }
.ds-dr__cardmain small { font-size: 0.75rem; color: var(--sa-muted); overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.ds-dr__call { display: grid; place-items: center; width: 2.5rem; height: 2.5rem; border-radius: 50%; flex: none; background: rgb(52 195 143 / 0.14); color: var(--sa-ok); }
.ds-dr__call svg { width: 1.1rem; height: 1.1rem; }
.ds-dr__toast { position: fixed; top: calc(env(safe-area-inset-top) + 5.5rem); left: 1rem; right: 1rem; z-index: 26; max-width: 32rem; margin: 0 auto; display: flex; align-items: center; gap: 0.75rem; padding: 0.75rem 0.75rem 0.75rem 0.9rem; border-radius: 1.25rem;
    background: rgb(15 43 35 / 0.96); backdrop-filter: blur(18px); box-shadow: 0 16px 40px rgb(0 0 0 / 0.4), inset 0 0 0 1px rgb(52 195 143 / 0.4); animation: dr-toast .35s cubic-bezier(.2,.9,.2,1); }
@keyframes dr-toast { from { transform: translateY(-140%); } to { transform: none; } }
@keyframes dr-count { from { stroke-dashoffset: 0; } to { stroke-dashoffset: 113; } }
.ds-dr__toast .ds-sa__mark { width: 2.2rem; height: 2.2rem; }
.ds-dr__toast .ds-sa__mark svg { width: 1.1rem; height: 1.1rem; }
.ds-dr__toast > span:nth-child(2) { flex: 1; display: flex; flex-direction: column; }
.ds-dr__toast small { font-size: 0.75rem; color: #9fd8c0; }
.ds-dr__toast button { display: flex; align-items: center; gap: 0.45rem; height: 2.5rem; padding: 0 0.85rem 0 0.6rem; border-radius: 0.8rem; background: rgb(255 255 255 / 0.1); color: var(--sa-text); font-weight: 700; }
.ds-dr__toast button svg { width: 1.35rem; height: 1.35rem; transform: rotate(-90deg); }
.ds-dr__toast circle { fill: none; stroke-width: 4; }
.ds-dr__toast .is-track { stroke: rgb(255 255 255 / 0.15); }
.ds-dr__toast .is-fill { stroke: var(--sa-gold); stroke-dasharray: 113; animation: dr-count 15s linear forwards; }
.ds-dr__tags { display: flex; align-items: center; gap: 0.6rem; }
.ds-dr__ontruck { padding: 0.25rem 0.65rem; border-radius: 999px; background: rgb(52 195 143 / 0.14); color: #6fd6ad; font-size: 0.75rem; font-weight: 700; }
.ds-dr__tags strong { font-size: 0.95rem; color: #c9d5dc; }
.ds-dr__tags em { margin-left: auto; font-style: normal; padding: 0.25rem 0.65rem; border-radius: 999px; background: rgb(255 255 255 / 0.07); font-size: 0.75rem; font-weight: 600; color: #c9d5dc; }
.ds-dr__receiver { display: flex; flex-direction: column; gap: 0.25rem; }
.ds-dr__receiver strong { font-size: 1.6rem; letter-spacing: -0.02em; line-height: 1.1; }
.ds-dr__receiver span { font-size: 0.9rem; color: #a9b8c2; line-height: 1.45; }
.ds-dr__two { display: grid; grid-template-columns: repeat(auto-fit, minmax(0, 1fr)); gap: 0.5rem; }
.ds-dr__two a { display: flex; align-items: center; justify-content: center; gap: 0.5rem; height: 3rem; border-radius: 0.9rem; background: rgb(255 255 255 / 0.06); color: var(--sa-text); font-weight: 600; font-size: 0.9rem; }
.ds-dr__two svg { width: 1.1rem; height: 1.1rem; }
.ds-dr__meta { font-size: 0.8rem; color: var(--sa-muted); }
.ds-dr__prev { font-size: 0.8rem; color: #f3c98a; }
.ds-sa__primary.is-green { background: var(--sa-ok); }
.ds-sa__primary.is-amber { background: var(--sa-warn); }
.ds-sa__primary.is-off { background: rgb(255 255 255 / 0.08); color: var(--sa-muted); }
.ds-dr__link { height: 2.6rem; color: var(--sa-muted); font-weight: 600; }
.ds-dr__sheethead { display: flex; flex-direction: column; gap: 0.25rem; }
.ds-dr__sheethead small { font-size: 0.8rem; color: var(--sa-muted); }
.ds-dr__sheethead.is-warn small { color: #c9b08a; }
.ds-dr__sheethead strong { font-size: 1.45rem; letter-spacing: -0.02em; }
.ds-dr__sheethead > span { font-size: 0.88rem; color: #a9b8c2; }
.ds-dr__grid { display: grid; grid-template-columns: repeat(3, 1fr); gap: 0.6rem; }
.ds-dr__proof { position: relative; aspect-ratio: 1; border-radius: 1.1rem; overflow: hidden; animation: sa-in .25s ease-out; }
.ds-dr__proof img { width: 100%; height: 100%; object-fit: cover; }
.ds-dr__proof b { position: absolute; left: 0.45rem; bottom: 0.45rem; padding: 0.05rem 0.5rem; border-radius: 999px; background: rgb(10 18 25 / 0.75); font-size: 0.7rem; }
.ds-dr__proof button { position: absolute; right: 0.35rem; top: 0.35rem; width: 1.6rem; height: 1.6rem; border-radius: 50%; background: rgb(10 18 25 / 0.7); color: #fff; font-size: 0.7rem; }
.ds-dr__proof.is-small { width: 3.5rem; height: 3.5rem; aspect-ratio: auto; border-radius: 0.9rem; }
.ds-dr__add { aspect-ratio: 1; border-radius: 1.1rem; display: flex; flex-direction: column; align-items: center; justify-content: center; gap: 0.35rem; background: rgb(255 255 255 / 0.05); box-shadow: inset 0 0 0 1.5px rgb(255 255 255 / 0.18); color: var(--sa-text); font-size: 0.8rem; font-weight: 600; }
.ds-dr__add svg { width: 1.6rem; height: 1.6rem; }
.ds-dr__chips { display: flex; flex-wrap: wrap; gap: 0.45rem; }
.ds-dr__chips button { height: 2.35rem; padding: 0 0.85rem; border-radius: 999px; background: rgb(255 255 255 / 0.07); color: var(--sa-text); font-size: 0.8rem; font-weight: 700; transition: background .2s, color .2s; }
.ds-dr__chips button.is-on { background: var(--sa-warn); color: #0a1219; }
.ds-sa__sheet.is-warn .ds-sa__note-in { background: rgb(255 255 255 / 0.06); }
.ds-sa.ds-dr { z-index: 32; }

/* ===================================================================== AI helpers */
.ds-ai {
    --ai-surf: #fff; --ai-raised: #f6f8fa; --ai-line: #e8edf1; --ai-text: #0e2433; --ai-muted: #5b6b78;
    --ai-violet: #6c55d9; --ai-violet-soft: #f2efff; --ai-violet-text: #3f3380;
    --ai-ok: #17895e; --ai-ok-soft: #e5f6ee; --ai-bad: #c2382f; --ai-bad-soft: #fde8e6; --ai-warn: #a76400; --ai-warn-soft: #fff2d9;
    --ai-blue: #1f6fa5; --ai-blue-soft: #e5f1fa; --ai-gold: #d4a72c;
    display: flex; flex-direction: column; gap: 1rem; color: var(--ai-text);
}
.dark .ds-ai {
    --ai-surf: #142430; --ai-raised: #1a2d3b; --ai-line: rgb(255 255 255 / 0.08); --ai-text: #e9eff3; --ai-muted: #93a6b4;
    --ai-violet-soft: rgb(108 85 217 / 0.18); --ai-violet-text: #cdc3ff;
    --ai-ok-soft: rgb(23 137 94 / 0.2); --ai-bad-soft: rgb(194 56 47 / 0.2); --ai-warn-soft: rgb(167 100 0 / 0.22); --ai-blue-soft: rgb(31 111 165 / 0.22);
    --ai-ok: #4fd09d; --ai-bad: #ff8a7e; --ai-warn: #f3c06b; --ai-blue: #8cc4ff;
}
.ds-ai__card { background: var(--ai-surf); border-radius: 1rem; box-shadow: 0 0 0 1px var(--ai-line); padding: 1rem 1.1rem; display: flex; flex-direction: column; gap: 0.8rem; min-width: 0; }
.ds-ai__card-head { display: flex; align-items: center; justify-content: space-between; gap: 0.75rem; flex-wrap: wrap; }
.ds-ai__card-head b { font-size: 1rem; }
.ds-ai__bar { display: flex; align-items: center; justify-content: space-between; gap: 0.75rem; flex-wrap: wrap; }
.ds-ai__seg { display: inline-flex; flex-wrap: wrap; gap: 0.3rem; align-items: center; }
.ds-ai__seg button { height: 2.1rem; padding: 0 0.85rem; border-radius: 0.65rem; font-size: 0.85rem; font-weight: 700; color: var(--ai-text); background: var(--ai-surf); box-shadow: inset 0 0 0 1px var(--ai-line); }
.ds-ai__seg.is-small button { height: 1.85rem; padding: 0 0.65rem; font-size: 0.78rem; background: var(--ai-raised); box-shadow: none; }
.ds-ai__seg button.is-on { background: var(--ds-navy); color: #fff; box-shadow: none; }
.dark .ds-ai__seg button.is-on { background: #e9eff3; color: #0b1620; }
.ds-ai__seg button i { font-style: normal; margin-left: 0.3rem; padding: 0 0.4rem; border-radius: 999px; background: #f0a93b; color: #fff; font-size: 0.72rem; }
.ds-ai__stats { display: grid; grid-template-columns: repeat(auto-fit, minmax(10rem, 1fr)); gap: 0.75rem; }
.ds-ai__stats > div { background: var(--ai-surf); border-radius: 1rem; box-shadow: 0 0 0 1px var(--ai-line); padding: 0.85rem 1rem; display: flex; flex-direction: column; gap: 0.15rem; }
.ds-ai__stats.is-small > div { background: var(--ai-raised); box-shadow: none; }
.ds-ai__stats small { font-size: 0.8rem; color: var(--ai-muted); }
.ds-ai__stats b { font-size: 1.6rem; font-weight: 900; letter-spacing: -0.02em; font-variant-numeric: tabular-nums; }
.ds-ai__stats b span { font-size: 0.9rem; font-weight: 600; color: var(--ai-muted); }
.ds-ai__stats em { font-style: normal; font-size: 0.75rem; color: var(--ai-muted); }
.ds-ai .is-red { color: var(--ai-bad); } .ds-ai .is-amber { color: var(--ai-warn); } .ds-ai .is-green { color: var(--ai-ok); }
.ds-ai__split { display: grid; grid-template-columns: minmax(0, 1fr) 24rem; gap: 1rem; align-items: start; }
.ds-ai__split.is-even { grid-template-columns: repeat(auto-fit, minmax(22rem, 1fr)); }
@media (max-width: 1100px) { .ds-ai__split { grid-template-columns: 1fr; } }
.ds-ai__list { padding: 0; gap: 0; overflow: hidden; }
.ds-ai__list > .ds-ai__card-head { padding: 0.8rem 1rem; border-bottom: 1px solid var(--ai-line); }
.ds-ai__row { width: 100%; display: flex; align-items: center; gap: 0.8rem; padding: 0.7rem 1rem; text-align: left; border-top: 1px solid var(--ai-line); background: var(--ai-surf); color: inherit; }
.ds-ai__row:first-of-type { border-top: 0; }
.ds-ai__row:hover { background: var(--ai-raised); }
.ds-ai__row.is-sel { background: var(--ai-warn-soft); box-shadow: inset 3px 0 0 var(--ai-gold); }
.ds-ai__row img { width: 4.2rem; height: 3.2rem; border-radius: 0.55rem; object-fit: cover; flex: none; background: var(--ai-raised); }
.ds-ai__row-main { flex: 1; min-width: 0; display: flex; flex-direction: column; gap: 0.15rem; font-size: 0.85rem; }
.ds-ai__row-main b { font-size: 0.95rem; }
.ds-ai__row-main small { font-size: 0.75rem; color: var(--ai-muted); }
.ds-ai__tag { display: inline-block; font-style: normal; padding: 0.1rem 0.5rem; border-radius: 999px; font-size: 0.72rem; font-weight: 800; background: var(--ai-raised); color: var(--ai-muted); }
.ds-ai__tag.is-damaged, .ds-ai__tag.is-no_box { background: var(--ai-bad-soft); color: var(--ai-bad); }
.ds-ai__tag.is-wet { background: var(--ai-blue-soft); color: var(--ai-blue); }
.ds-ai__tag.is-open { background: var(--ai-warn-soft); color: var(--ai-warn); }
.ds-ai__tag.is-blurry { background: var(--ai-violet-soft); color: var(--ai-violet-text); }
.ds-ai__tag.is-ok { background: var(--ai-ok-soft); color: var(--ai-ok); }
.ds-ai__state { flex: none; padding: 0.15rem 0.6rem; border-radius: 999px; font-size: 0.75rem; font-weight: 700; background: var(--ai-raised); color: var(--ai-muted); }
.ds-ai__state.is-damaged, .ds-ai__state.is-removed { background: var(--ai-bad-soft); color: var(--ai-bad); }
.ds-ai__state.is-fine, .ds-ai__state.is-texted, .ds-ai__state.is-ok { background: var(--ai-ok-soft); color: var(--ai-ok); }
.ds-ai__state.is-open { background: var(--ai-warn-soft); color: var(--ai-warn); }
.ds-ai__empty { padding: 1.5rem 1rem; color: var(--ai-muted); text-align: center; margin: 0; }
.ds-ai__detail { position: sticky; top: 5rem; }
.ds-ai__photo { position: relative; display: block; border-radius: 0.8rem; overflow: hidden; background: var(--ai-raised); }
.ds-ai__photo img { width: 100%; max-height: 18rem; object-fit: contain; display: block; }
.ds-ai__photo span { position: absolute; left: 0.6rem; top: 0.6rem; padding: 0.15rem 0.55rem; border-radius: 999px; background: rgb(14 36 51 / 0.75); color: #fff; font-size: 0.75rem; font-weight: 700; }
.ds-ai__detail-head { display: flex; align-items: baseline; justify-content: space-between; gap: 0.5rem; }
.ds-ai__detail-head b { font-size: 1.15rem; } .ds-ai__detail-head small { color: var(--ai-muted); font-size: 0.8rem; }
.ds-ai__said { display: flex; gap: 0.7rem; padding: 0.8rem 0.9rem; border-radius: 0.8rem; background: var(--ai-violet-soft); color: var(--ai-violet-text); font-size: 0.9rem; line-height: 1.5; }
.ds-ai__said > span:last-child { display: flex; flex-direction: column; gap: 0.35rem; flex: 1; min-width: 0; }
.ds-ai__said small { font-size: 0.85rem; opacity: 0.9; }
.ds-ai__badge { width: 1.7rem; height: 1.7rem; flex: none; border-radius: 0.5rem; background: var(--ai-violet); color: #fff; display: grid; place-items: center; font-size: 0.7rem; font-weight: 900; }
.ds-ai__two { display: flex; flex-wrap: wrap; gap: 0.5rem; align-items: center; }
.ds-ai__two > * { flex: 1 1 auto; }
.ds-ai__done { margin: 0; padding: 0.7rem 0.85rem; border-radius: 0.7rem; font-size: 0.85rem; font-weight: 600; }
.ds-ai__done.is-damaged { background: var(--ai-bad-soft); color: var(--ai-bad); }
.ds-ai__done.is-fine { background: var(--ai-ok-soft); color: var(--ai-ok); }
.ds-ai__link { color: var(--ai-violet); font-weight: 700; font-size: 0.8rem; margin-left: 0.4rem; text-decoration: none; }
.dark .ds-ai__link { color: #b9a8ff; }
.ds-ai__err { margin: 0; padding: 0.6rem 0.8rem; border-radius: 0.6rem; background: var(--ai-bad-soft, #fde8e6); color: var(--ai-bad, #b3261e); font-size: 0.85rem; }
.ds-ai__test { margin: 0; padding: 0.6rem 0.8rem; border-radius: 0.6rem; font-size: 0.9rem; font-weight: 600; }
.ds-ai__test.is-ok { background: var(--ai-ok-soft); color: var(--ai-ok); }
.ds-ai__test.is-bad { background: var(--ai-bad-soft); color: var(--ai-bad); }
.ds-ai__paused { display: flex; gap: 0.6rem; align-items: center; padding: 0.7rem 0.9rem; border-radius: 0.8rem; background: var(--ai-warn-soft); color: var(--ai-warn); font-size: 0.9rem; }
.ds-ai__paused b { padding: 0.1rem 0.5rem; border-radius: 999px; background: #f0a93b; color: #fff; font-size: 0.75rem; }
.ds-ai__pill { padding: 0.15rem 0.6rem; border-radius: 999px; font-size: 0.75rem !important; font-weight: 700; }
.ds-ai__pill.is-ok { background: var(--ai-ok-soft); color: var(--ai-ok) !important; }
.ds-ai__pill.is-off { background: var(--ai-warn-soft); color: var(--ai-warn) !important; }
/* settings */
.ds-ai-set { gap: 1rem; }
.ds-ai-set__steps { margin: 0; padding-left: 1.2rem; display: flex; flex-direction: column; gap: 0.25rem; font-size: 0.9rem; }
.ds-ai-set__steps a, .ds-ai-set__notes a { color: var(--ai-violet); font-weight: 700; }
.ds-ai-set__key { display: flex; gap: 0.5rem; flex-wrap: wrap; }
.ds-ai-set__key input { flex: 1 1 18rem; min-width: 0; height: 2.6rem; padding: 0 0.8rem; border-radius: 0.6rem; border: 0; box-shadow: inset 0 0 0 1px var(--ai-line); background: var(--ai-surf); color: var(--ai-text); font-family: ui-monospace, monospace; }
.ds-ai-set__feat { display: grid; grid-template-columns: auto 1fr auto; gap: 0.8rem; align-items: start; padding: 0.75rem 0; border-top: 1px solid var(--ai-line); cursor: pointer; }
.ds-ai-set__feat input { margin-top: 0.25rem; }
.ds-ai-set__feat > span:nth-child(2) { display: flex; flex-direction: column; gap: 0.15rem; }
.ds-ai-set__feat small { font-size: 0.85rem; color: var(--ai-muted); }
.ds-ai-set__feat em { font-style: normal; font-size: 0.75rem; font-weight: 700; color: var(--ai-violet); }
.ds-ai-set__use { display: flex; flex-direction: column; align-items: flex-end; font-variant-numeric: tabular-nums; }
.ds-ai-set__use small { font-size: 0.75rem; color: var(--ai-muted); }
.ds-ai-set__save { display: flex; justify-content: flex-end; }
.ds-ai-set__spend { display: flex; flex-direction: column; gap: 0.4rem; }
.ds-ai-set__spend i { display: block; height: 0.5rem; border-radius: 999px; background: var(--ai-raised); overflow: hidden; }
.ds-ai-set__spend s { display: block; height: 100%; background: var(--ai-ok); border-radius: 999px; text-decoration: none; }
.ds-ai-set__spend s.is-bad { background: var(--ai-bad); }
.ds-ai-set__notes { margin: 0; padding-left: 1.2rem; display: flex; flex-direction: column; gap: 0.3rem; font-size: 0.9rem; }
.ds-ai-set code, .ds-ai-set__steps code { font-size: 0.85em; padding: 0.05rem 0.3rem; border-radius: 0.3rem; background: var(--ai-raised); }
/* ask */
.ds-ai__chat { padding: 0; gap: 0; min-height: 34rem; }
.ds-ai__msgs { flex: 1; max-height: 60vh; min-height: 22rem; overflow: auto; padding: 1.2rem 1.4rem; display: flex; flex-direction: column; gap: 0.8rem; }
.ds-ai__hello { margin: auto; text-align: center; display: flex; flex-direction: column; gap: 0.3rem; color: var(--ai-muted); }
.ds-ai__hello b { font-size: 1.1rem; color: var(--ai-text); }
.ds-ai__msg { align-self: flex-start; max-width: 46rem; padding: 0.7rem 0.95rem; border-radius: 1rem 1rem 1rem 0.25rem; background: var(--ai-raised); font-size: 0.95rem; line-height: 1.55; }
.ds-ai__msg.is-me { align-self: flex-end; background: var(--ds-navy); color: #fff; border-radius: 1rem 1rem 0.25rem 1rem; }
.ds-ai__typing { align-self: flex-start; align-items: center; gap: 0.3rem; padding: 0.6rem 0.9rem; border-radius: 1rem; background: var(--ai-violet-soft); color: var(--ai-violet-text); font-size: 0.85rem; }
.ds-ai__typing i { width: 0.4rem; height: 0.4rem; border-radius: 50%; background: var(--ai-violet); animation: ds-ai-dot 1s infinite; }
.ds-ai__typing i:nth-child(2) { animation-delay: 0.15s; } .ds-ai__typing i:nth-child(3) { animation-delay: 0.3s; }
.ds-ai__typing span { margin-left: 0.3rem; }
@keyframes ds-ai-dot { 0%, 80%, 100% { opacity: 0.25; } 40% { opacity: 1; } }
.ds-ai__ask { border-top: 1px solid var(--ai-line); padding: 0.8rem 1rem 1rem; display: flex; flex-direction: column; gap: 0.6rem; }
.ds-ai__chips { display: flex; flex-wrap: wrap; gap: 0.35rem; }
.ds-ai__chips button { height: 1.9rem; padding: 0 0.75rem; border-radius: 999px; background: var(--ai-violet-soft); color: var(--ai-violet-text); font-size: 0.8rem; font-weight: 700; }
.ds-ai__chips button.is-plain { background: var(--ai-raised); color: var(--ai-muted); }
.ds-ai__askrow { display: flex; gap: 0.5rem; }
.ds-ai__askrow input, .ds-ai__text, .ds-ai__select { flex: 1; min-width: 0; height: 2.75rem; padding: 0 0.9rem; border-radius: 0.7rem; border: 0; box-shadow: inset 0 0 0 1px var(--ai-line); background: var(--ai-surf); color: var(--ai-text); font-size: 0.95rem; }
.ds-ai__text { height: auto; padding: 0.7rem 0.9rem; line-height: 1.5; resize: vertical; }
.ds-ai__select { flex: 0 1 14rem; height: 2.2rem; }
/* manifest */
.ds-ai__upload { max-width: 44rem; }
.ds-ai__upload select { height: 2.6rem; border-radius: 0.6rem; border: 0; box-shadow: inset 0 0 0 1px var(--ai-line); background: var(--ai-surf); color: var(--ai-text); padding: 0 0.7rem; }
.ds-ai__drop { display: flex; flex-direction: column; align-items: center; gap: 0.3rem; padding: 1.6rem 1rem; border-radius: 0.9rem; background: var(--ai-raised); box-shadow: inset 0 0 0 1.5px dashed var(--ai-line); border: 1.5px dashed #c9d3db; cursor: pointer; text-align: center; }
.ds-ai__drop input { max-width: 100%; font-size: 0.85rem; }
.ds-ai__drop small { color: var(--ai-muted); }
.ds-ai__table { overflow: auto; max-height: 62vh; border-radius: 0.7rem; box-shadow: 0 0 0 1px var(--ai-line); }
.ds-ai__tr { display: grid; grid-template-columns: 2rem 7rem minmax(10rem, 1.2fr) minmax(14rem, 2fr) 8rem 5rem minmax(12rem, 1.4fr); gap: 0.6rem; align-items: start; padding: 0.55rem 0.8rem; border-top: 1px solid var(--ai-line); font-size: 0.83rem; min-width: 64rem; }
.ds-ai__tr.is-head { position: sticky; top: 0; z-index: 1; background: var(--ai-raised); font-size: 0.75rem; font-weight: 700; color: var(--ai-muted); border-top: 0; }
.ds-ai__tr small { display: block; color: var(--ai-muted); font-size: 0.73rem; }
.ds-ai__tr.is-off { opacity: 0.55; }
.ds-ai__tr.is-warn { background: var(--ai-warn-soft); }
.ds-ai__notes { display: flex; flex-direction: column; gap: 0.2rem; align-items: flex-start; }
.ds-ai__notes .ds-ai__tag { white-space: normal; }
.ds-ai__foot { display: flex; align-items: center; gap: 0.6rem; flex-wrap: wrap; }
.ds-ai__foot > span { flex: 1 1 20rem; font-size: 0.85rem; color: var(--ai-muted); }
/* risky */
.ds-ai__score { width: 3rem; height: 3rem; flex: none; border-radius: 0.8rem; display: grid; place-items: center; font-weight: 900; font-size: 0.9rem; background: var(--ai-warn-soft); color: var(--ai-warn); }
.ds-ai__score.is-high { background: var(--ai-bad-soft); color: var(--ai-bad); }
.ds-ai__why { margin: 0; padding-left: 1.1rem; display: flex; flex-direction: column; gap: 0.2rem; font-size: 0.88rem; }
.ds-ai__label { font-size: 0.85rem; }
.ds-ai__btn { display: inline-flex; align-items: center; justify-content: center; height: 2.25rem; padding: 0 0.9rem; border-radius: 0.55rem; font-weight: 700; font-size: 0.875rem; text-decoration: none; }
.ds-ai__btn.is-green { background: var(--ai-ok); color: #fff; }
/* alerts */
.ds-ai__alert { display: flex; gap: 0.85rem; align-items: flex-start; padding: 0.9rem 0.2rem; border-top: 1px solid var(--ai-line); }
.ds-ai__alert:first-child { border-top: 0; }
.ds-ai__alert-ic { width: 2.5rem; height: 2.5rem; flex: none; border-radius: 0.75rem; display: grid; place-items: center; font-size: 1.1rem; background: var(--ai-blue-soft); }
.ds-ai__alert.is-high .ds-ai__alert-ic { background: var(--ai-bad-soft); }
.ds-ai__alert.is-mid .ds-ai__alert-ic { background: var(--ai-warn-soft); }
.ds-ai__alert-act { display: flex; flex-direction: column; gap: 0.35rem; align-items: stretch; width: 9rem; flex: none; }
.ds-ai__alert-act small { color: var(--ai-muted); font-size: 0.75rem; text-align: center; }
/* insights */
.ds-ai__bars { display: flex; align-items: flex-end; gap: 0.35rem; height: 13rem; padding-top: 0.5rem; overflow-x: auto; }
.ds-ai__barcol { flex: 1 0 2.4rem; display: flex; flex-direction: column; align-items: center; justify-content: flex-end; gap: 0.3rem; height: 100%; }
.ds-ai__barcol em { font-style: normal; font-size: 0.68rem; font-weight: 700; color: var(--ai-muted); font-variant-numeric: tabular-nums; }
.ds-ai__barcol i { position: relative; display: block; width: 1.3rem; border-radius: 0.3rem 0.3rem 0 0; min-height: 2px; }
.ds-ai__barcol i.is-past { background: #c9d3db; }
.dark .ds-ai__barcol i.is-past { background: #3a4f5f; }
.ds-ai__barcol i.is-next { background: #e9b730; }
.ds-ai__barcol i s { position: absolute; left: -0.25rem; right: -0.25rem; height: 2px; background: var(--ai-text); opacity: 0.55; }
.ds-ai__barcol small { font-size: 0.66rem; color: var(--ai-muted); white-space: nowrap; }
/* driver app + scan app */
.ds-dr__risk { display: flex; flex-direction: column; gap: 0.2rem; padding: 0.7rem 0.85rem; border-radius: 0.9rem; background: rgb(240 169 59 / 0.14); box-shadow: inset 0 0 0 1px rgb(240 169 59 / 0.4); color: #f3c98a; font-size: 0.82rem; line-height: 1.45; }
.ds-dr__risk b { color: #ffd28f; font-size: 0.85rem; }
.ds-dr__voice { display: flex; align-items: center; gap: 0.8rem; padding: 0.6rem 0.7rem; border-radius: 1rem; background: rgb(108 85 217 / 0.16); }
.ds-dr__voice button { width: 3.2rem; height: 3.2rem; flex: none; border-radius: 50%; display: grid; place-items: center; background: #8b78ff; color: #fff; }
.ds-dr__voice button.is-on { background: #ff6b5e; animation: ds-ai-pulse 1s infinite; }
.ds-dr__voice button svg { width: 1.5rem; height: 1.5rem; }
.ds-dr__voice > span { display: flex; flex-direction: column; gap: 0.1rem; min-width: 0; }
.ds-dr__voice b { font-size: 0.9rem; } .ds-dr__voice small { font-size: 0.75rem; color: #c9c0ff; }
@keyframes ds-ai-pulse { 0% { box-shadow: 0 0 0 0 rgb(255 107 94 / 0.55); } 100% { box-shadow: 0 0 0 16px rgb(255 107 94 / 0); } }
.ds-sa__aiflag { position: relative; z-index: 6; display: flex; align-items: center; flex-wrap: wrap; gap: 0.6rem; margin: 0 0 0.6rem; padding: 0.7rem 0.8rem; border-radius: 1rem; background: rgb(108 85 217 / 0.2); box-shadow: inset 0 0 0 1px rgb(139 120 255 / 0.5); color: #eef3f6; }
.ds-sa__aiflag > span:nth-child(2) { flex: 1 1 10rem; display: flex; flex-direction: column; font-size: 0.85rem; }
.ds-sa__aiflag small { color: #c9c0ff; font-size: 0.75rem; }
.ds-sa__aiflag button { height: 2.3rem; padding: 0 0.8rem; border-radius: 0.7rem; background: #ff6b5e; color: #fff; font-weight: 800; font-size: 0.8rem; }
.ds-sa__aiflag button.is-plain { background: rgb(255 255 255 / 0.1); }
.ds-sa__aibadge { width: 1.8rem; height: 1.8rem; flex: none; border-radius: 0.55rem; display: grid; place-items: center; background: #8b78ff; color: #fff; font-size: 0.7rem; font-weight: 900; }
/* AI trip helper */
.ds-ai__plan { flex-direction: row; align-items: center; gap: 0.6rem; flex-wrap: wrap; padding: 0.6rem; }
.ds-ai__plan > input { flex: 1 1 18rem; min-width: 0; height: 2.5rem; padding: 0 0.8rem; border-radius: 0.6rem; border: 0; background: var(--ai-raised); color: var(--ai-text); }
.ds-ai__date { display: flex; align-items: center; gap: 0.4rem; font-size: 0.8rem; color: var(--ai-muted); }
.ds-ai__date input { height: 2.5rem; padding: 0 0.6rem; border-radius: 0.6rem; border: 0; box-shadow: inset 0 0 0 1px var(--ai-line); background: var(--ai-surf); color: var(--ai-text); }
.ds-ai__split.is-trips { grid-template-columns: 20rem minmax(0, 1fr); }
@media (max-width: 1100px) { .ds-ai__split.is-trips { grid-template-columns: 1fr; } }
.ds-ai__tree { display: flex; flex-direction: column; gap: 0.7rem; max-height: 55vh; overflow: auto; }
.ds-ai__tree > div { display: flex; flex-direction: column; gap: 0.35rem; }
.ds-ai__tree > div > b { font-size: 0.85rem; }
.ds-ai__tree small { color: var(--ai-muted); font-weight: 600; }
.ds-ai__tree span { display: flex; flex-direction: column; gap: 0.1rem; padding-left: 0.6rem; border-left: 2px solid var(--ai-line); font-size: 0.82rem; }
.ds-ai__tree span small { font-weight: 400; line-height: 1.45; }
.ds-ai__two.is-left > * { flex: 0 0 auto; }
.ds-ai__tripcol { display: flex; flex-direction: column; gap: 0.8rem; min-width: 0; }
.ds-ai__trips { display: grid; grid-template-columns: repeat(auto-fill, minmax(17rem, 1fr)); gap: 0.8rem; }
.ds-ai__trip { display: flex; flex-direction: column; gap: 0.6rem; padding: 0.9rem; border-radius: 1rem; background: var(--ai-surf); box-shadow: 0 0 0 1px var(--ai-line); }
.ds-ai__trip.is-over { box-shadow: 0 0 0 1.5px var(--ai-bad); }
.ds-ai__select.is-full { flex: none; width: 100%; }
.ds-ai__dest { display: flex; align-items: center; gap: 0.5rem; font-size: 0.8rem; color: var(--ai-muted); }
.ds-ai__dest .ds-ai__select { flex: 1; }
.ds-ai__fill { display: flex; justify-content: space-between; font-size: 0.85rem; font-variant-numeric: tabular-nums; }
.ds-ai__meter { display: block; height: 0.45rem; border-radius: 999px; background: var(--ai-raised); overflow: hidden; }
.ds-ai__meter s { display: block; height: 100%; border-radius: 999px; background: var(--ai-ok); text-decoration: none; }
.ds-ai__meter s.is-warn { background: #e0a400; } .ds-ai__meter s.is-bad { background: var(--ai-bad); }
.ds-ai__place { display: flex; justify-content: space-between; align-items: center; gap: 0.5rem; padding: 0.45rem 0.65rem; border-radius: 0.6rem; background: var(--ai-raised); text-align: left; font-size: 0.85rem; color: var(--ai-text); }
.ds-ai__place:hover { box-shadow: inset 0 0 0 1px var(--ai-violet); }
.ds-ai__place > span:first-child { display: flex; flex-direction: column; min-width: 0; }
.ds-ai__place small { color: var(--ai-muted); font-size: 0.72rem; }
.ds-ai__place > span:last-child { color: var(--ai-muted); font-variant-numeric: tabular-nums; white-space: nowrap; }
.ds-ai__why1 { color: var(--ai-violet); font-size: 0.78rem; line-height: 1.4; }
.dark .ds-ai__why1 { color: #b9a8ff; }
.ds-ai__chipbtn { height: 1.9rem; padding: 0 0.7rem; border-radius: 999px; background: var(--ai-raised); font-size: 0.8rem; font-weight: 700; color: var(--ai-text); }
.ds-ai__chipbtn.is-prio { background: var(--ai-bad-soft); color: var(--ai-bad); }
.ds-ai__made { display: flex; align-items: center; gap: 0.8rem; }
.ds-ai__made > span:first-child { width: 2.6rem; height: 2.6rem; border-radius: 50%; background: var(--ai-ok); color: #fff; display: grid; place-items: center; font-size: 1.2rem; font-weight: 900; }
.ds-ai__made > span:last-child { display: flex; flex-direction: column; }
.ds-ai__made b { font-size: 1.15rem; } .ds-ai__made small { color: var(--ai-muted); }
.ds-ai__madeRow { display: grid; grid-template-columns: 8rem 9rem 1fr auto; gap: 0.8rem; align-items: center; padding: 0.6rem 0.8rem; border-radius: 0.7rem; background: var(--ai-raised); font-size: 0.9rem; }
.ds-ai__madeRow small { grid-column: 1 / -1; }
.ds-ai__card.ds-ai__foot { flex-direction: row; flex-wrap: wrap; align-items: center; }
.ds-ai__card.ds-ai__foot > span { flex: 1 1 20rem; }
/* Box aging */
.ds-ag .ds-ai__stats > button { text-align: left; background: var(--ai-surf); border-radius: 1rem; box-shadow: 0 0 0 1px var(--ai-line); padding: 0.85rem 1rem; display: flex; flex-direction: column; gap: 0.15rem; color: inherit; }
.ds-ag .ds-ai__stats > button:hover { box-shadow: 0 0 0 1.5px var(--ai-violet); }
.ds-ai__said > span:last-child > span { display: block; }
.ds-ag__table { padding: 0; gap: 0; overflow: auto; }
.ds-ag__tr { display: grid; grid-template-columns: minmax(15rem, 1.6fr) repeat(4, minmax(5rem, 1fr)) 6rem; align-items: center; padding: 0.6rem 1rem; border-top: 1px solid var(--ai-line); min-width: 44rem; }
.ds-ag__tr.is-head { border-top: 0; background: var(--ai-raised); font-size: 0.75rem; font-weight: 700; color: var(--ai-muted); }
.ds-ag__tr > span { display: flex; flex-direction: column; } .ds-ag__tr > span:not(:first-child) { align-items: center; }
.ds-ag__tr small { font-size: 0.75rem; color: var(--ai-muted); }
.ds-ag__cell { min-width: 3.4rem; height: 2rem; border-radius: 0.55rem; font-weight: 800; font-variant-numeric: tabular-nums; }
.ds-ag__cell.is-ok { background: var(--ai-ok-soft); color: var(--ai-ok); }
.ds-ag__cell.is-warn { background: var(--ai-warn-soft); color: var(--ai-warn); }
.ds-ag__cell.is-late { background: var(--ai-bad-soft); color: var(--ai-bad); }
.ds-ag__cell.is-zero { color: var(--ai-muted); opacity: 0.45; }
.ds-ag__cell.is-sel { box-shadow: 0 0 0 2px var(--ai-text); }
.ds-ag__late { text-align: right; font-size: 1.1rem; font-variant-numeric: tabular-nums; }
.ds-ag__box { display: grid; grid-template-columns: 6.5rem 1fr 4.5rem; gap: 0.6rem; align-items: center; padding: 0.5rem 0.7rem; border-radius: 0.6rem; background: var(--ai-raised); font-size: 0.85rem; }
.ds-ag__box > span:nth-child(2) { display: flex; flex-direction: column; min-width: 0; }
.ds-ag__box small { color: var(--ai-muted); font-size: 0.72rem; }
.ds-ag__age { display: flex; flex-direction: column; align-items: flex-end; font-weight: 800; font-variant-numeric: tabular-nums; }
.ds-ag__age.is-late { color: var(--ai-bad); } .ds-ag__age.is-warn { color: var(--ai-warn); } .ds-ag__age.is-ok { color: var(--ai-ok); }
.ds-ag__bar { display: grid; grid-template-columns: 1fr 10rem 4.5rem; gap: 0.6rem; align-items: center; font-size: 0.85rem; }
.ds-ag__bar small { color: var(--ai-muted); }
.ds-ag__bar i { display: flex; height: 0.6rem; border-radius: 999px; overflow: hidden; background: var(--ai-raised); }
.ds-ag__bar s { display: block; height: 100%; text-decoration: none; }
.ds-ag__bar s.is-ok { background: #34c38f; } .ds-ag__bar s.is-warn { background: #f0a93b; } .ds-ag__bar s.is-late { background: #d9534a; }
.ds-ag__bar b { text-align: right; font-size: 0.8rem; }
.ds-agl__tr { display: grid; grid-template-columns: minmax(14rem, 1.5fr) 6rem 9rem 9rem minmax(14rem, 2fr); gap: 0.7rem; align-items: center; padding: 0.6rem 1rem; border-top: 1px solid var(--ai-line); min-width: 56rem; }
.ds-agl__tr.is-head { border-top: 0; background: var(--ai-raised); font-size: 0.75rem; font-weight: 700; color: var(--ai-muted); }
.ds-agl__tr.is-changed { background: var(--ai-warn-soft); }
.ds-agl__tr > span:first-child { display: flex; flex-direction: column; } .ds-agl__tr small { color: var(--ai-muted); font-size: 0.75rem; }
.ds-agl__num { display: flex; align-items: center; gap: 0.35rem; }
.ds-agl__num button { width: 1.7rem; height: 1.7rem; border-radius: 0.45rem; background: var(--ai-raised); font-weight: 800; }
.ds-agl__num b { min-width: 3.4rem; text-align: center; font-variant-numeric: tabular-nums; }
.ds-agl__why { font-size: 0.78rem; color: var(--ai-violet); line-height: 1.4; }
.dark .ds-agl__why { color: #b9a8ff; }
.ds-ai .ds-gm__field input { height: 2.4rem; padding: 0 0.7rem; border-radius: 0.6rem; border: 0; box-shadow: inset 0 0 0 1px var(--ai-line); background: var(--ai-surf); color: var(--ai-text); }
/* Install QR codes */
.ds-qr { display: flex; flex-direction: column; gap: 0.8rem; }
.ds-qr__grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(24rem, 1fr)); gap: 1rem; }
.ds-qr.is-compact .ds-qr__grid { grid-template-columns: repeat(auto-fit, minmax(20rem, 1fr)); }
.ds-qr__card { display: flex; gap: 1rem; align-items: center; padding: 1rem; border-radius: 1rem; background: #fff; box-shadow: 0 0 0 1px #e6ebef; }
.dark .ds-qr__card { background: rgb(255 255 255 / 0.04); box-shadow: 0 0 0 1px rgb(255 255 255 / 0.08); }
.ds-qr__code { flex: none; padding: 10px; border-radius: 0.8rem; background: #fff; box-shadow: inset 0 0 0 1px #e6ebef; line-height: 0; }
.ds-qr__code svg { display: block; }
.ds-qr.is-off .ds-qr__code { opacity: 0.25; filter: grayscale(1); }
.ds-qr__info { flex: 1; min-width: 0; display: flex; flex-direction: column; gap: 0.5rem; }
.ds-qr__title { display: flex; align-items: center; gap: 0.6rem; }
.ds-qr__title img { width: 36px; height: 36px; border-radius: 9px; }
.ds-qr__title b { font-size: 1.1rem; }
.ds-qr__info small { color: #5b6b78; font-size: 0.82rem; line-height: 1.45; }
.dark .ds-qr__info small { color: #93a6b4; }
.ds-qr__link { display: flex; align-items: center; gap: 0.5rem; padding: 0.4rem 0.4rem 0.4rem 0.7rem; border-radius: 0.6rem; background: #f3f5f7; }
.dark .ds-qr__link { background: rgb(255 255 255 / 0.06); }
.ds-qr__link code { flex: 1; min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; font-size: 0.8rem; }
.ds-qr__link button { padding: 0.25rem 0.6rem; border-radius: 0.45rem; background: #fff; box-shadow: inset 0 0 0 1px #dfe5ea; font-size: 0.75rem; font-weight: 700; color: #0e2433; }
.ds-qr__info ol { margin: 0; padding-left: 1.1rem; font-size: 0.82rem; line-height: 1.6; }
.ds-qr__actions { display: flex; flex-wrap: wrap; gap: 0.4rem; }
.ds-qr__actions a { padding: 0.45rem 0.8rem; border-radius: 0.6rem; background: #eef1f4; color: #0e2433; font-size: 0.82rem; font-weight: 700; text-decoration: none; }
.ds-qr__actions a.is-main { background: #d4a72c; color: #1d1600; }
.dark .ds-qr__actions a:not(.is-main) { background: rgb(255 255 255 / 0.08); color: #e9eff3; }
.ds-qr__warn { margin: 0; padding: 0.6rem 0.8rem; border-radius: 0.6rem; background: #fde8e6; color: #8f2a22; font-size: 0.85rem; }
.ds-qr__warn.is-amber { background: #fff2d9; color: #7a5200; }
.ds-qr__ok { margin: 0; padding: 0.6rem 0.8rem; border-radius: 0.6rem; background: #e5f6ee; color: #0f5c3f; font-size: 0.85rem; }
.ds-qr__note { color: #8a99a5; font-size: 0.78rem; }
.ds-qr__hide { font-size: 0.8rem; font-weight: 700; color: #5b6b78; }
.ds-qr-set { display: flex; flex-direction: column; gap: 0.8rem; }
.ds-qr-set__base { display: flex; gap: 0.6rem; align-items: flex-end; flex-wrap: wrap; }
.ds-qr-set__base .ds-gm__field { flex: 1 1 24rem; }
.ds-qr-set__base input { height: 2.5rem; padding: 0 0.7rem; border-radius: 0.6rem; border: 0; box-shadow: inset 0 0 0 1px #dfe5ea; width: 100%; }
.ds-qr__info ol { list-style: decimal; }

/* ============================================================ Maps & routes */
.ds-mp { display: flex; flex-direction: column; gap: 1rem; }
.ds-mp__chain { display: grid; grid-template-columns: repeat(3, minmax(0, 1fr)); gap: 0.6rem; }
.ds-mp__step { display: flex; flex-direction: column; gap: 0.3rem; padding: 0.75rem; border-radius: 0.8rem; background: #f3f5f7; color: #5b6b78; }
.ds-mp__step.is-on { background: #e5f6ee; color: #0f5c3f; }
.ds-mp__stephead { display: flex; align-items: center; gap: 0.5rem; font-size: 0.9rem; }
.ds-mp__stephead i { width: 1.5rem; height: 1.5rem; border-radius: 50%; display: inline-flex; align-items: center; justify-content: center; font-style: normal; font-size: 0.75rem; font-weight: 900; color: #fff; background: #c9d1d8; }
.ds-mp__step.is-on .ds-mp__stephead i { background: #17895e; }
.ds-mp__step strong { font-size: 0.85rem; }
.ds-mp__step small { font-size: 0.78rem; line-height: 1.4; opacity: .85; }
.ds-mp__warn { margin: 0; padding: 0.5rem 0.75rem; border-radius: 0.6rem; background: #fff1d6; color: #7a5200; font-size: 0.85rem; }
.ds-mp__providers { display: grid; grid-template-columns: repeat(3, minmax(0, 1fr)); gap: 0.75rem; }
.ds-mp__provider { display: flex; flex-direction: column; gap: 0.5rem; padding: 0.9rem; border-radius: 0.9rem; background: #f6f8fa; box-shadow: inset 0 0 0 1px #e6ebef; text-align: left; }
.ds-mp__provider.is-picked { background: #fff8e6; box-shadow: inset 0 0 0 2px #d4a72c; }
.ds-mp__provhead { display: flex; justify-content: space-between; align-items: center; gap: 0.5rem; }
.ds-mp__provhead em { font-style: normal; padding: 0.1rem 0.5rem; border-radius: 999px; font-size: 0.7rem; font-weight: 800; background: #eef1f4; color: #6b7b88; }
.ds-mp__provhead em.is-on { background: #17895e; color: #fff; }
.ds-mp__provider small { font-size: 0.8rem; color: #5b6b78; line-height: 1.45; }
.ds-mp__provider code { font-size: 0.75rem; color: #33424e; }
.ds-mp__keyrow { display: flex; gap: 0.5rem; flex-wrap: wrap; }
.ds-mp__keyrow input, .ds-mp__testaddr input, .ds-mp__starts input, .ds-mp__fix input { flex: 1; min-width: 12rem; height: 2.5rem; padding: 0 0.75rem; border-radius: 0.6rem; border: 0; box-shadow: inset 0 0 0 1px #dfe5ea; background: #fff; font-size: 0.9rem; }
.ds-mp__testaddr { display: flex; align-items: center; gap: 0.6rem; font-size: 0.85rem; color: #5b6b78; }
.ds-mp__result { margin: 0; padding: 0.55rem 0.75rem; border-radius: 0.6rem; background: #fde8e6; color: #8c1d18; font-size: 0.85rem; }
.ds-mp__result.is-ok { background: #e5f6ee; color: #0f5c3f; }
.ds-mp__two { display: grid; grid-template-columns: 1fr 1fr; gap: 1rem; }
.ds-mp__two.is-one { grid-template-columns: minmax(0, 40rem); }
.ds-mp__toggle { align-self: flex-start; height: 2.3rem; padding: 0 0.9rem; border-radius: 0.6rem; font-weight: 800; font-size: 0.85rem; background: #eef1f4; color: #5b6b78; }
.ds-mp__toggle.is-on { background: #e5f6ee; color: #17895e; }
.ds-mp__starts { display: flex; flex-direction: column; gap: 0.45rem; }
.ds-mp__starts label { display: flex; align-items: center; gap: 0.6rem; font-size: 0.85rem; }
.ds-mp__starts label > span { width: 45%; font-weight: 700; }
.ds-mp__starts small { font-weight: 400; color: #8a99a5; }
.ds-mp__stats { display: flex; flex-wrap: wrap; gap: 0.5rem 1.5rem; font-size: 0.85rem; }
.ds-mp__stats small { color: #8a99a5; }
.ds-mp__fix { display: flex; flex-direction: column; gap: 0.5rem; }
.ds-mp__fix > div { display: flex; align-items: center; gap: 0.6rem; flex-wrap: wrap; padding: 0.5rem 0.6rem; border-radius: 0.6rem; background: #f6f8fa; }
.ds-mp__fix > div > span { flex: 2; min-width: 14rem; display: flex; flex-direction: column; font-size: 0.85rem; }
.ds-mp__fix small { color: #6b7b88; }
.ds-mp__fix input { flex: 1; }

.ds-mp__badges { display: flex; flex-wrap: wrap; gap: 0.5rem; align-items: center; }
.ds-mp__badges > span:not(.ds-mp__badgeactions) { padding: 0.45rem 0.75rem; border-radius: 0.6rem; font-size: 0.82rem; font-weight: 700; background: #eef1f4; }
.ds-mp__badges .is-ok { background: #e5f6ee; color: #0f5c3f; }
.ds-mp__badges .is-ai { background: #f2efff; color: #4b3aa8; }
.ds-mp__badges .is-warn { background: #fff1d6; color: #7a5200; }
.ds-mp__badgeactions { margin-left: auto; display: flex; gap: 0.5rem; flex-wrap: wrap; }
.ds-mp__truck { flex-direction: row; align-items: stretch; gap: 0; padding: 0.75rem; }
.ds-mp__cab { width: 4rem; border-radius: 1rem 0.3rem 0.3rem 1rem; background: #0e2433; color: #f6be00; font-size: 0.75rem; font-weight: 900; display: flex; align-items: center; justify-content: center; }
.ds-mp__zone { flex: 1; display: flex; flex-direction: column; justify-content: center; gap: 0.15rem; padding: 0.6rem 0.8rem; min-height: 4.5rem; box-shadow: inset -2px 0 0 #fff; }
.ds-mp__zone b { font-size: 0.9rem; }
.ds-mp__zone small { font-size: 0.75rem; opacity: .85; }
.ds-mp__zone.is-front { background: #e7f0fb; color: #1f5f9e; }
.ds-mp__zone.is-middle { background: #f2efff; color: #4b3aa8; }
.ds-mp__zone.is-back { background: #fff1d6; color: #8a5a00; }
.ds-mp__door { width: 3.5rem; display: flex; align-items: center; justify-content: center; font-size: 0.7rem; font-weight: 800; color: #6b7b88; border-left: 4px dashed #0e2433; }
.ds-mp__grid { display: grid; grid-template-columns: minmax(0, 1.1fr) minmax(0, 1fr); gap: 1rem; align-items: start; }
.ds-mp__map { height: 30rem; border-radius: 0.8rem; overflow: hidden; background: #e8eef2; z-index: 0; }
.ds-mp__legend { margin: 0; display: flex; flex-wrap: wrap; gap: 0.4rem 1rem; font-size: 0.75rem; color: #5b6b78; }
.ds-mp__legend .is-ok { color: #17895e; } .ds-mp__legend .is-area { color: #9a6400; } .ds-mp__legend .is-prio { color: #b3261e; }
.ds-mp__stops { margin: 0; padding: 0; list-style: none; display: flex; flex-direction: column; gap: 0.4rem; }
.ds-mp__stops li { display: grid; grid-template-columns: 1rem 1.8rem minmax(0, 1fr) auto auto auto auto; gap: 0.5rem; align-items: center; padding: 0.5rem 0.6rem; border-radius: 0.6rem; background: #f6f8fa; }
.ds-mp__stops li.is-over { box-shadow: inset 0 0 0 2px #d4a72c; }
.ds-mp__grab { color: #a8b3bb; cursor: grab; }
.ds-mp__no { width: 1.7rem; height: 1.7rem; border-radius: 50%; background: #0e2433; color: #fff; display: flex; align-items: center; justify-content: center; font-weight: 900; font-size: 0.78rem; }
.ds-mp__who { font-size: 0.85rem; min-width: 0; }
.ds-mp__tags { display: flex; gap: 0.25rem; flex-wrap: wrap; margin-top: 0.15rem; }
.ds-mp__tags em { font-style: normal; padding: 0 0.45rem; border-radius: 999px; font-size: 0.68rem; font-weight: 800; }
.ds-mp__tags .is-prio { background: #fde8e6; color: #b3261e; }
.ds-mp__tags .is-warn, .ds-mp__tags .is-area { background: #fff1d6; color: #9a6400; }
.ds-mp__n { font-size: 0.8rem; white-space: nowrap; }
.ds-mp__spot { padding: 0.15rem 0.55rem; border-radius: 999px; font-size: 0.7rem; font-weight: 900; }
.ds-mp__spot.is-front { background: #e7f0fb; color: #1f5f9e; } .ds-mp__spot.is-middle { background: #f2efff; color: #4b3aa8; } .ds-mp__spot.is-back { background: #fff1d6; color: #8a5a00; }
.ds-mp__load { font-size: 0.75rem; font-weight: 800; color: #1f6fa5; white-space: nowrap; }
.ds-mp__updown { display: flex; flex-direction: column; }
.ds-mp__updown button { font-size: 0.6rem; line-height: 1; padding: 0.1rem 0.3rem; color: #6b7b88; }
.ds-mp__updown button:disabled { opacity: .25; }
.ds-map__pin { display: flex !important; align-items: center; justify-content: center; border-radius: 50%; color: #fff; font: 900 13px/1 Archivo, sans-serif; border: 3px solid #fff; box-shadow: 0 1px 4px rgb(0 0 0 / .35); background: #17895e; }
.ds-map__pin.is-area { background: #f0a93b; } .ds-map__pin.is-prio { background: #d9534a; }
.ds-map__pin.is-start { border-radius: 0.5rem; background: #0e2433; color: #f6be00; font-size: 11px; }
.dark .ds-mp__step, .dark .ds-mp__provider, .dark .ds-mp__stops li, .dark .ds-mp__fix > div { background: rgb(255 255 255 / 0.05); color: #e6edf3; box-shadow: none; }
.dark .ds-mp__step.is-on { background: rgb(23 137 94 / .2); color: #8ee0bd; }
.dark .ds-mp__provider.is-picked { box-shadow: inset 0 0 0 2px #d4a72c; }
.dark .ds-mp__keyrow input, .dark .ds-mp__testaddr input, .dark .ds-mp__starts input, .dark .ds-mp__fix input { background: rgb(255 255 255 / .06); color: #e6edf3; box-shadow: inset 0 0 0 1px rgb(255 255 255 / .15); }
@media (max-width: 1024px) { .ds-mp__grid, .ds-mp__two, .ds-mp__chain, .ds-mp__providers { grid-template-columns: 1fr; } }

/* Load truck: what to load next, and "too early" */
.ds-ld__next { display: flex; flex-direction: column; gap: 0.3rem; padding: 0.8rem 0.9rem; border-radius: 0.9rem; background: #eef4fb; box-shadow: inset 0 0 0 1px #c8dcf2; color: #0e2433; }
.ds-ld__next small { font-size: 0.72rem; font-weight: 800; letter-spacing: .04em; color: #1f5f9e; }
.ds-ld__next small b { padding: 0 0.4rem; border-radius: 999px; background: #1f5f9e; color: #fff; }
.ds-ld__next small b.is-middle { background: #4b3aa8; } .ds-ld__next small b.is-back { background: #8a5a00; }
.ds-ld__next strong { font-size: 1.15rem; }
.ds-ld__next > span { font-size: 0.85rem; opacity: .85; }
.ds-ld__bar { display: flex; gap: 0.25rem; margin-top: 0.2rem; }
.ds-ld__bar i { flex: 1; height: 0.45rem; border-radius: 999px; background: rgb(14 36 51 / .12); }
.ds-ld__bar i.is-done { background: #34c38f; } .ds-ld__bar i.is-now { background: #3b8fe0; }
.ds-ld__ends { display: flex; justify-content: space-between; font-size: 0.68rem; opacity: .7; }
.ds-ld__next.is-dark { position: absolute; top: calc(env(safe-area-inset-top) + 5.2rem); left: 1rem; right: 1rem; z-index: 3; background: rgb(10 18 25 / .82); box-shadow: inset 0 0 0 1px rgb(140 196 255 / .35); color: #eef3f6; backdrop-filter: blur(8px); }
.ds-ld__next.is-dark small { color: #8cc4ff; }
.ds-ld__next.is-dark .ds-ld__bar i { background: rgb(255 255 255 / .14); }
.ds-ld__next.is-dark .ds-ld__bar i.is-done { background: #34c38f; } .ds-ld__next.is-dark .ds-ld__bar i.is-now { background: #8cc4ff; }
.ds-ld__early { display: flex; flex-wrap: wrap; align-items: center; gap: 0.4rem 0.8rem; padding: 0.7rem 0.9rem; border-radius: 0.8rem; background: #fff1d6; color: #7a5200; font-size: 0.9rem; }
.ds-ld__kicker { display: block; font-size: 0.72rem; font-weight: 900; letter-spacing: .06em; color: #f3c98a; }
.ds-ld__spot { display: flex; align-items: baseline; gap: 0.6rem; padding: 0.55rem 0.8rem; border-radius: 0.8rem; background: rgb(140 196 255 / .14); color: #8cc4ff; }
.ds-ld__spot strong { font-size: 1.4rem; font-weight: 900; letter-spacing: .02em; }
.ds-ld__spot span { font-size: 0.85rem; color: #c9d5dc; }
.ds-ld__spot.is-middle { background: rgb(176 160 255 / .14); color: #c2b6ff; }
.ds-ld__spot.is-back { background: rgb(240 169 59 / .14); color: #f3c98a; }

/* Driver app: your stops and Navigate */
.ds-nav { display: contents; }
.ds-nav__next { display: flex; align-items: center; gap: 0.7rem; padding: 0.8rem 0.9rem; border-radius: 1rem; background: rgb(246 190 0 / .1); box-shadow: inset 0 0 0 1px rgb(246 190 0 / .35); }
.ds-nav__next > span { flex: 1; display: flex; flex-direction: column; min-width: 0; }
.ds-nav__next small { font-size: 0.75rem; color: #f6d36b; font-weight: 700; }
.ds-nav__next strong { font-size: 1rem; }
.ds-nav__next em { font-style: normal; font-size: 0.8rem; color: #a9b8c2; }
.ds-nav__next button { height: 2.5rem; padding: 0 1rem; border-radius: 0.7rem; background: var(--sa-gold, #f6be00); color: #0a1219; font-weight: 800; }
.ds-nav__row { gap: 0.7rem; }
.ds-nav__no { width: 2rem; height: 2rem; flex: none; border-radius: 50%; display: flex; align-items: center; justify-content: center; font-weight: 900; font-size: 0.85rem; background: rgb(255 255 255 / .1); }
.ds-nav__no.is-next { background: #f6be00; color: #0a1219; }
.ds-nav__no.is-prio { box-shadow: 0 0 0 2px #d9534a; }
.ds-nav__who { flex: 1; padding: 0; min-width: 0; display: flex; flex-direction: column; align-items: flex-start; text-align: left; }
.ds-nav__go { height: 2.1rem; padding: 0 0.75rem; border-radius: 0.6rem; background: rgb(140 196 255 / .14); color: #8cc4ff; font-size: 0.8rem; font-weight: 800; }
.ds-nav__hint { margin: 0; font-size: 0.78rem; color: #7f93a1; text-align: center; }
.ds-nav__hint button { color: #8cc4ff; font-weight: 700; }
.ds-nav__veil { position: fixed; inset: 0; z-index: 60; background: rgb(0 0 0 / .55); display: flex; align-items: flex-end; }
.ds-nav__sheet { width: 100%; max-width: 32rem; margin: 0 auto; padding: 1rem 1.1rem 1.6rem; border-radius: 1.6rem 1.6rem 0 0; background: #101c25; color: #eef3f6; display: flex; flex-direction: column; gap: 0.6rem; }
.ds-nav__sheet > small { font-size: 0.75rem; color: #7f93a1; }
.ds-nav__sheet > strong { font-size: 1.3rem; }
.ds-nav__addr { font-size: 0.9rem; color: #c9d5dc; line-height: 1.45; }
.ds-nav__chips { display: flex; gap: 0.4rem; flex-wrap: wrap; }
.ds-nav__chips em { font-style: normal; padding: 0.2rem 0.6rem; border-radius: 999px; background: rgb(255 255 255 / .08); font-size: 0.78rem; }
.ds-nav__ask { margin-top: 0.3rem; font-size: 0.85rem; }
.ds-nav__app { display: flex; align-items: center; gap: 0.75rem; height: 3.6rem; padding: 0 0.9rem; border-radius: 0.9rem; background: rgb(255 255 255 / .07); color: #fff; text-align: left; font-size: 1.2rem; }
.ds-nav__app > span { flex: 1; display: flex; flex-direction: column; font-size: 1rem; }
.ds-nav__app small { font-size: 0.75rem; color: #a9b8c2; }
.ds-nav__app i { width: 2.4rem; height: 2.4rem; flex: none; border-radius: 0.7rem; display: flex; align-items: center; justify-content: center; font-style: normal; font-weight: 900; font-size: 1.1rem; }
.ds-nav__app .is-waze { background: #33ccff; color: #0a1219; } .ds-nav__app .is-google { background: #fff; color: #1a73e8; } .ds-nav__app .is-apple { background: #e9eef2; color: #0e2433; }
.ds-nav__remember { display: flex; align-items: center; gap: 0.5rem; font-size: 0.82rem; color: #a9b8c2; }
.ds-nav__two { display: grid; grid-template-columns: 1fr 1fr; gap: 0.5rem; }
.ds-nav__soft { height: 2.8rem; border-radius: 0.8rem; background: rgb(140 196 255 / .12); color: #8cc4ff; font-weight: 800; font-size: 0.88rem; display: flex; align-items: center; justify-content: center; }
.ds-nav__soft.is-warn { background: rgb(240 169 59 / .14); color: #f3c98a; }
.ds-nav__back { display: flex; flex-direction: column; gap: 0.5rem; padding: 1rem; border-radius: 1.2rem; background: rgb(52 195 143 / .1); box-shadow: inset 0 0 0 1px rgb(52 195 143 / .4); }
.ds-nav__back small { font-size: 0.78rem; font-weight: 800; color: #6fe0b5; }
.ds-nav__back strong { font-size: 1.2rem; }
.ds-nav__back > span { font-size: 0.85rem; color: #c9d5dc; }
.ds-nav__link { font-size: 0.8rem; color: #7f93a1; }

/* ============================================================ Truck tracking */
.ds-tm { display: flex; flex-direction: column; gap: 0.9rem; }
.ds-tm__top { display: flex; justify-content: space-between; align-items: center; gap: 1rem; flex-wrap: wrap; }
.ds-tm__tabs { display: inline-flex; gap: 0.25rem; padding: 0.25rem; border-radius: 0.75rem; background: #e6ebef; }
.ds-tm__tabs button { height: 2rem; padding: 0 0.9rem; border-radius: 0.55rem; font-size: 0.82rem; font-weight: 800; color: #5b6b78; }
.ds-tm__tabs button.is-on { background: #fff; color: #0e2433; box-shadow: 0 1px 2px rgb(0 0 0 / .12); }
.ds-mp__badges .is-bad { background: #fde8e6; color: #8c1d18; }
.ds-tm__grid { display: grid; grid-template-columns: minmax(0, 1fr) 22rem; gap: 0.9rem; align-items: start; }
.ds-tm__map { height: 36rem; border-radius: 0.8rem; overflow: hidden; background: #e8eef2; z-index: 0; }
.ds-tm__map.is-small { height: 30rem; }
.ds-tm__side { display: flex; flex-direction: column; gap: 0.75rem; min-width: 0; }
.ds-tm__list { padding: 0.5rem; gap: 0.3rem; max-height: 22rem; overflow: auto; }
.ds-tm__row { display: flex; flex-direction: column; align-items: flex-start; gap: 0.15rem; width: 100%; padding: 0.55rem 0.65rem; border-radius: 0.6rem; background: #f6f8fa; text-align: left; }
.ds-tm__row.is-sel { background: #fff8e6; box-shadow: inset 0 0 0 2px #d4a72c; }
.ds-tm__row > span { display: flex; justify-content: space-between; gap: 0.5rem; width: 100%; font-size: 0.85rem; }
.ds-tm__row small { font-size: 0.75rem; color: #5b6b78; }
.ds-tm em.is-ok, .ds-tm em.is-warn, .ds-tm em.is-bad { font-style: normal; padding: 0.1rem 0.5rem; border-radius: 999px; font-size: 0.7rem; font-weight: 800; white-space: nowrap; }
.ds-tm em.is-ok { background: #e5f6ee; color: #17895e; } .ds-tm em.is-warn { background: #fff1d6; color: #9a6400; } .ds-tm em.is-bad { background: #fde8e6; color: #b3261e; }
.ds-tm__cardhead { display: flex; justify-content: space-between; align-items: center; gap: 0.5rem; font-size: 0.95rem; }
.ds-tm__crew { font-size: 0.82rem; color: #33424e; }
.ds-tm__facts { display: grid; grid-template-columns: 1fr 1fr; gap: 0.4rem; }
.ds-tm__facts span { display: flex; flex-direction: column; padding: 0.5rem 0.6rem; border-radius: 0.55rem; background: #f6f8fa; font-size: 0.72rem; color: #6b7b88; }
.ds-tm__facts b { font-size: 0.82rem; color: #0e2433; }
.ds-tm__btns { display: flex; gap: 0.4rem; flex-wrap: wrap; }
.ds-tm__replay { display: flex; align-items: center; gap: 0.7rem; padding: 0.2rem 0.3rem; }
.ds-tm__replay button { width: 2.1rem; height: 2.1rem; border-radius: 50%; background: #0e2433; color: #fff; flex: none; }
.ds-tm__replay input { flex: 1; accent-color: #1f6fa5; }
.ds-tm__replay small { color: #5b6b78; font-size: 0.75rem; }
.ds-tm__who { display: flex; align-items: center; gap: 0.8rem; }
.ds-tm__who b { font-size: 1.15rem; }
.ds-tm__who small { color: #5b6b78; font-size: 0.82rem; }
.ds-tm__who small b { font-size: 0.82rem; color: #0e2433; }
.ds-tm__icon { width: 3rem; height: 3rem; border-radius: 0.9rem; background: #0e2433; display: grid; place-items: center; font-size: 1.4rem; flex: none; }
.ds-tm__stats { display: grid; grid-template-columns: repeat(6, minmax(0, 1fr)); gap: 0.5rem; }
.ds-tm__stats.is-four { grid-template-columns: repeat(4, minmax(0, 1fr)); }
.ds-tm__stats > span { padding: 0.65rem 0.8rem; gap: 0.1rem; }
.ds-tm__stats small { font-size: 0.72rem; color: #6b7b88; }
.ds-tm__stats b { font-size: 1.2rem; }
.ds-tm__stats b.is-ok { color: #17895e; }
.ds-tm__stats em { font-style: normal; font-size: 0.7rem; color: #8a99a5; }
.ds-tm__now { margin: 0; font-size: 0.85rem; line-height: 1.6; }
.ds-tm__events { margin: 0; padding: 0; list-style: none; display: flex; flex-direction: column; }
.ds-tm__events li { display: grid; grid-template-columns: 2.6rem 0.8rem 1fr; gap: 0.5rem; align-items: start; min-height: 2rem; font-size: 0.8rem; line-height: 1.35; }
.ds-tm__events small { color: #6b7b88; font-size: 0.75rem; }
.ds-tm__events i { width: 0.7rem; height: 0.7rem; margin-top: 0.2rem; border-radius: 50%; background: #c9d1d8; box-shadow: 0 0 0 3px #fff; }
.ds-tm__events .is-start i { background: #0e2433; } .ds-tm__events .is-ok i { background: #17895e; } .ds-tm__events .is-warn i { background: #f0a93b; }
.ds-tm__events .is-bad i { background: #d9534a; } .ds-tm__events .is-now i { background: #1f6fa5; }
.ds-tm__table { display: flex; flex-direction: column; gap: 0.35rem; }
.ds-tm__table > div { display: grid; grid-template-columns: 6rem 6rem 9rem 4rem 5rem 5.5rem minmax(0, 1fr) 5.5rem; gap: 0.5rem; align-items: center; padding: 0.55rem 0.7rem; border-radius: 0.6rem; background: #f6f8fa; font-size: 0.82rem; }
.ds-tm__table > div.is-head { background: none; font-size: 0.72rem; font-weight: 800; color: #6b7b88; padding-top: 0; padding-bottom: 0; }
.ds-tm__table > div.is-sel { box-shadow: inset 0 0 0 2px #1f6fa5; }
.ds-tm__table .is-ok { color: #17895e; font-weight: 800; } .ds-tm__table .is-warn { color: #9a6400; font-weight: 800; }
.ds-tm__table small { color: #5b6b78; font-size: 0.75rem; }
.ds-tm__table button { color: #1f6fa5; font-weight: 800; font-size: 0.8rem; }
.ds-tm__alerts { display: flex; flex-direction: column; gap: 0.45rem; }
.ds-tm__alerts > div { display: flex; align-items: center; gap: 0.7rem; flex-wrap: wrap; padding: 0.65rem 0.75rem; border-radius: 0.7rem; background: #f6f8fa; }
.ds-tm__aicon { font-size: 1.1rem; }
.ds-tm__atext { flex: 1; min-width: 14rem; display: flex; flex-direction: column; gap: 0.1rem; font-size: 0.85rem; }
.ds-tm__atext small { color: #5b6b78; font-size: 0.75rem; }
.ds-tm__when { color: #6b7b88; font-size: 0.75rem; white-space: nowrap; }
.ds-tm__alerts input { height: 2.1rem; min-width: 12rem; padding: 0 0.6rem; border-radius: 0.5rem; border: 0; box-shadow: inset 0 0 0 1px #dfe5ea; background: #fff; font-size: 0.8rem; }
.ds-tm__srcs { display: grid; grid-template-columns: repeat(auto-fill, minmax(16rem, 1fr)); gap: 0.4rem; }
.ds-tm__srcs label, .ds-tm__form label { display: flex; justify-content: space-between; align-items: center; gap: 0.6rem; padding: 0.5rem 0.7rem; border-radius: 0.6rem; background: #f6f8fa; font-size: 0.85rem; }
.ds-tm__srcs small { color: #8a99a5; }
.ds-tm__srcs select, .ds-tm__form select, .ds-tm__form input { height: 2.1rem; padding: 0 0.5rem; border-radius: 0.5rem; border: 0; box-shadow: inset 0 0 0 1px #dfe5ea; background: #fff; font-size: 0.82rem; }
.ds-tm__form .is-ok, .ds-tm__srcs .is-ok { color: #17895e; }
.ds-tm__link { display: flex; flex-direction: column; gap: 0.4rem; padding: 0.75rem; border-radius: 0.7rem; background: #f3f5f7; font-size: 0.82rem; }
.ds-tm__link code { font-size: 0.75rem; word-break: break-all; }
.ds-tm__pin { display: flex !important; align-items: center; justify-content: center; border-radius: 999px; color: #fff; font: 900 12px/1 Archivo, sans-serif; border: 2px solid #fff; box-shadow: 0 1px 4px rgb(0 0 0 / .35); background: #0e2433; white-space: nowrap; }
.ds-tm__pin.is-done { background: #17895e; } .ds-tm__pin.is-mark { background: #f0a93b; }
.ds-tm__pin.is-start { border-radius: 0.5rem; color: #f6be00; font-size: 11px; }
.ds-tm__pin.is-truck { padding: 0 0.5rem; font-size: 12px; }
.ds-tm__pin.is-truck.is-warn { background: #9a6400; } .ds-tm__pin.is-truck.is-bad { background: #b3261e; }
.ds-tm__pin.is-truck.is-sel { box-shadow: 0 0 0 3px #f6be00, 0 2px 6px rgb(0 0 0 / .3); z-index: 1000 !important; }
.ds-tm__pin.is-ghost { background: #1f6fa5; font-size: 16px; }
.dark .ds-tm__row, .dark .ds-tm__facts span, .dark .ds-tm__table > div:not(.is-head), .dark .ds-tm__alerts > div, .dark .ds-tm__srcs label, .dark .ds-tm__form label, .dark .ds-tm__link { background: rgb(255 255 255 / .05); color: #e6edf3; }
.dark .ds-tm__facts b { color: #e6edf3; }
@media (max-width: 1100px) { .ds-tm__grid { grid-template-columns: 1fr; } .ds-tm__stats { grid-template-columns: repeat(3, 1fr); } .ds-tm__table > div { grid-template-columns: repeat(4, 1fr); } }

/* Driver app: tracking */
.ds-trk__ask { display: flex; flex-direction: column; gap: 0.7rem; margin: 0 0 1rem; padding: 1.2rem; border-radius: 1.5rem; background: rgb(140 196 255 / .07); box-shadow: inset 0 0 0 1px rgb(140 196 255 / .25); }
.ds-trk__pin { width: 3.2rem; height: 3.2rem; border-radius: 1rem; background: rgb(140 196 255 / .14); display: grid; place-items: center; font-size: 1.5rem; }
.ds-trk__ask strong { font-size: 1.35rem; letter-spacing: -0.02em; }
.ds-trk__ask p { margin: 0; font-size: 0.9rem; color: #c9d5dc; line-height: 1.5; }
.ds-trk__ask ul { margin: 0; padding: 0; list-style: none; display: flex; flex-direction: column; gap: 0.4rem; }
.ds-trk__ask li { display: flex; gap: 0.6rem; padding: 0.6rem 0.75rem; border-radius: 0.8rem; background: rgb(255 255 255 / .05); font-size: 0.85rem; }
.ds-trk__ask li b { color: #6fe0b5; } .ds-trk__ask li i { color: #8cc4ff; font-style: normal; font-weight: 900; }
.ds-trk__ask small { font-size: 0.75rem; color: #7f93a1; text-align: center; }
.ds-trk__bar { display: flex; align-items: center; gap: 0.6rem; width: 100%; margin: 0 0 0.8rem; padding: 0.55rem 0.8rem; border-radius: 0.9rem; background: rgb(52 195 143 / .1); box-shadow: inset 0 0 0 1px rgb(52 195 143 / .35); text-align: left; color: inherit; }
.ds-trk__bar i { width: 0.6rem; height: 0.6rem; flex: none; border-radius: 50%; background: #34c38f; box-shadow: 0 0 0 4px rgb(52 195 143 / .2); }
.ds-trk__bar > span { display: flex; flex-direction: column; }
.ds-trk__bar b { font-size: 0.82rem; } .ds-trk__bar small { font-size: 0.72rem; color: #a9b8c2; }
.ds-trk__bar.is-off { background: rgb(240 169 59 / .1); box-shadow: inset 0 0 0 1px rgb(240 169 59 / .4); }
.ds-trk__bar.is-off i { background: #f0a93b; box-shadow: 0 0 0 4px rgb(240 169 59 / .2); }

/* ============================================================ SMS + AI helpers */
.ds-sms__providers { grid-template-columns: repeat(4, minmax(0, 1fr)); }
.ds-sms__fields { display: grid; grid-template-columns: repeat(auto-fill, minmax(15rem, 1fr)); gap: 0.6rem; }
.ds-sms__fields label { display: flex; flex-direction: column; gap: 0.25rem; font-size: 0.8rem; font-weight: 700; }
.ds-sms__fields small { font-weight: 400; }
.ds-sms__fields small.is-ok { color: #17895e; font-weight: 700; }
.ds-sms__fields input, .ds-sms__fields select, .ds-sms__test input, .ds-sms__text { height: 2.5rem; padding: 0 0.75rem; border-radius: 0.6rem; border: 0; box-shadow: inset 0 0 0 1px #dfe5ea; background: #fff; font-size: 0.88rem; font-weight: 400; }
.ds-sms__test { display: inline-flex; gap: 0.4rem; margin-left: auto; }
.ds-sms__grid { display: grid; grid-template-columns: minmax(0, 1fr) minmax(0, 1.15fr); gap: 1rem; align-items: start; }
.ds-sms__kind { display: flex; align-items: center; gap: 0.7rem; padding: 0.65rem 0.75rem; border-radius: 0.75rem; background: #f6f8fa; }
.ds-sms__kind.is-sel { background: #fff8e6; box-shadow: inset 0 0 0 2px #d4a72c; }
.ds-sms__kind > small { color: #6b7b88; font-size: 0.75rem; white-space: nowrap; }
.ds-sms__kindtext { flex: 1; display: flex; flex-direction: column; text-align: left; font-size: 0.88rem; }
.ds-sms__kindtext small { color: #5b6b78; font-size: 0.75rem; }
.ds-sms__switch { width: 2.5rem; height: 1.5rem; flex: none; padding: 0.15rem; border-radius: 999px; background: #c9d1d8; display: flex; justify-content: flex-start; }
.ds-sms__switch.is-on { background: #17895e; justify-content: flex-end; }
.ds-sms__switch i { width: 1.2rem; height: 1.2rem; border-radius: 50%; background: #fff; box-shadow: 0 1px 2px rgb(0 0 0 / .2); }
.ds-sms__text { height: auto; padding: 0.7rem 0.8rem; line-height: 1.5; font-family: ui-monospace, Menlo, monospace; resize: vertical; width: 100%; }
.ds-sms__blanks { display: flex; flex-wrap: wrap; gap: 0.3rem; }
.ds-sms__blanks em { font-style: normal; padding: 0.1rem 0.5rem; border-radius: 999px; background: #f2efff; color: #4b3aa8; font-size: 0.7rem; font-weight: 800; }
.ds-sms__ai { display: flex; flex-wrap: wrap; gap: 0.35rem; align-items: center; }
.ds-sms__ai button { height: 2.1rem; padding: 0 0.75rem; border-radius: 0.55rem; background: #f2efff; color: #4b3aa8; font-weight: 800; font-size: 0.8rem; }
.ds-sms__ai small { color: #6b7b88; font-size: 0.75rem; }
.ds-sms__ainote { display: flex; align-items: center; gap: 0.6rem; padding: 0.6rem 0.75rem; border-radius: 0.65rem; background: #f2efff; color: #4b3aa8; font-size: 0.82rem; font-weight: 700; }
.ds-sms__ainote button { margin-left: auto; padding: 0.25rem 0.6rem; border-radius: 0.45rem; background: #fff; font-weight: 800; }
.ds-sms__checks { display: flex; flex-direction: column; gap: 0.3rem; }
.ds-sms__checks span { padding: 0.4rem 0.6rem; border-radius: 0.5rem; font-size: 0.8rem; }
.ds-sms__checks .is-ok { background: #e5f6ee; color: #0f5c3f; } .ds-sms__checks .is-warn { background: #fff1d6; color: #7a5200; }
.ds-sms__label { font-size: 0.82rem; margin-top: 0.3rem; }
.ds-sms__phone { display: flex; flex-direction: column; gap: 0.4rem; padding: 0.8rem; border-radius: 1rem; background: #eef1f4; }
.ds-sms__phone small { text-align: center; font-size: 0.7rem; color: #6b7b88; }
.ds-sms__phone span { align-self: flex-start; max-width: 92%; padding: 0.6rem 0.75rem; border-radius: 1rem 1rem 1rem 0.3rem; background: #fff; font-size: 0.88rem; line-height: 1.45; color: #0e2433; }
.ds-sms__other { display: grid; grid-template-columns: 5rem 1fr; gap: 0.6rem; padding: 0.5rem 0.7rem; border-radius: 0.6rem; background: #f6f8fa; text-align: left; font-size: 0.8rem; }
.ds-sms__other span { color: #33424e; }
.ds-tm__stats.is-five { grid-template-columns: repeat(5, minmax(0, 1fr)); }
.ds-tm__stats b em { font-style: normal; font-size: 0.75rem; color: #6b7b88; font-weight: 400; }
.ds-tm__stats b.is-bad { color: #b3261e; }
.ds-tm__ainote { display: flex; flex-direction: column; gap: 0.1rem; margin-top: 0.3rem; padding: 0.5rem 0.65rem; border-radius: 0.55rem; background: #f2efff; color: #2c2470; font-size: 0.8rem; line-height: 1.45; }
.ds-tm__ainote small { color: #4b3aa8; font-weight: 800; font-size: 0.7rem; }
.ds-tm__aiacts { display: flex; flex-wrap: wrap; gap: 0.3rem; margin-top: 0.25rem; }
.ds-tm__aiacts i { font-style: normal; padding: 0.15rem 0.5rem; border-radius: 0.4rem; background: #eef1f4; font-size: 0.72rem; font-weight: 700; }
.ds-tm__daytext { background: #f2efff; }
.ds-tm__daytext small { color: #4b3aa8; font-weight: 800; font-size: 0.75rem; }
.ds-tm__daytext p { margin: 0; font-size: 0.98rem; line-height: 1.55; color: #2c2470; }
.ds-tm__daygrid { display: grid; grid-template-columns: repeat(auto-fill, minmax(17rem, 1fr)); gap: 0.6rem; }
.ds-tm__daycard { display: flex; flex-direction: column; align-items: flex-start; gap: 0.25rem; padding: 0.8rem; border-radius: 0.9rem; background: #fff; box-shadow: 0 0 0 1px #e6ebef; text-align: left; }
.ds-tm__daycard.is-sel { background: #fff8e6; box-shadow: inset 0 0 0 2px #d4a72c; }
.ds-tm__daycard > span:first-child { display: flex; justify-content: space-between; width: 100%; }
.ds-tm__daycard small { color: #5b6b78; font-size: 0.78rem; }
.ds-tm__daycard em { font-style: normal; padding: 0.1rem 0.5rem; border-radius: 999px; font-size: 0.7rem; font-weight: 800; }
.ds-tm__daycard em.is-ok { background: #e5f6ee; color: #17895e; } .ds-tm__daycard em.is-mid { background: #eef4fb; color: #1f5f9e; } .ds-tm__daycard em.is-warn { background: #fff1d6; color: #9a6400; }
.ds-tm__daynums { display: grid; grid-template-columns: repeat(4, 1fr); gap: 0.25rem; width: 100%; margin-top: 0.2rem; }
.ds-tm__daynums i { font-style: normal; display: flex; flex-direction: column; padding: 0.35rem; border-radius: 0.45rem; background: #f6f8fa; font-size: 0.65rem; color: #6b7b88; }
.ds-tm__daynums b { font-size: 0.85rem; color: #0e2433; }
.ds-tm__aibox { margin: 0; display: flex; flex-direction: column; gap: 0.15rem; padding: 0.7rem 0.85rem; border-radius: 0.7rem; background: #f2efff; color: #2c2470; line-height: 1.55; }
.ds-tm__aibox small { color: #4b3aa8; font-weight: 800; font-size: 0.7rem; }
.ds-tm__goodbad { display: grid; grid-template-columns: 1fr 1fr; gap: 0.6rem; }
.ds-tm__goodbad span { display: flex; flex-direction: column; padding: 0.6rem 0.75rem; border-radius: 0.6rem; font-size: 0.82rem; line-height: 1.45; }
.ds-tm__goodbad .is-ok { background: #e5f6ee; color: #0f5c3f; } .ds-tm__goodbad .is-warn { background: #fff1d6; color: #7a5200; }
.dark .ds-sms__kind, .dark .ds-sms__other, .dark .ds-tm__daycard, .dark .ds-tm__daynums i { background: rgb(255 255 255 / .05); color: #e6edf3; box-shadow: none; }
.dark .ds-sms__fields input, .dark .ds-sms__fields select, .dark .ds-sms__test input, .dark .ds-sms__text { background: rgb(255 255 255 / .06); color: #e6edf3; }
@media (max-width: 1100px) { .ds-sms__grid, .ds-sms__providers { grid-template-columns: 1fr; } .ds-tm__stats.is-five { grid-template-columns: repeat(2, 1fr); } }

/* ============================== Help guide ============================== */
.ds-help { --h-ink: var(--ds-navy); --h-muted: #5b6b77; --h-card: #fff; --h-line: rgb(14 36 51 / 0.1); --h-soft: #f3f6f8; --h-accent: var(--ds-signal);
    display: flex; flex-direction: column; gap: 1rem; color: var(--h-ink); max-width: 60rem; }
.dark .ds-help { --h-ink: #e6edf3; --h-muted: #93a5b3; --h-card: #10283a; --h-line: rgb(255 255 255 / 0.09); --h-soft: rgb(255 255 255 / 0.04); }
.ds-help button { cursor: pointer; }
.ds-help__hero { display: flex; align-items: flex-start; justify-content: space-between; gap: 1rem; flex-wrap: wrap; }
.ds-help__hero h1 { font-size: 1.75rem; font-weight: 800; letter-spacing: -0.02em; line-height: 1.15; margin: 0; }
.ds-help__hero p { margin: 0.3rem 0 0; color: var(--h-muted); }
.ds-help__lang { display: inline-flex; padding: 0.2rem; border-radius: 999px; background: var(--h-soft); box-shadow: inset 0 0 0 1px var(--h-line); flex: none; }
.ds-help__lang button { padding: 0.3rem 0.8rem; border-radius: 999px; font-size: 0.8rem; font-weight: 700; color: var(--h-muted); }
.ds-help__lang button.is-on { background: var(--ds-navy); color: #fff; }
.dark .ds-help__lang button.is-on { background: var(--ds-signal); color: #0e2433; }
.ds-help__search { display: flex; align-items: center; gap: 0.5rem; padding: 0.4rem 0.4rem 0.4rem 0.9rem; border-radius: 1rem; background: var(--h-card); box-shadow: 0 0 0 1px var(--h-line), 0 6px 20px -12px rgb(14 36 51 / 0.35); }
.ds-help__search:focus-within { box-shadow: 0 0 0 2px var(--ds-signal), 0 6px 20px -12px rgb(14 36 51 / 0.35); }
.ds-help__search-icon { color: var(--h-muted); display: flex; }
.ds-help__search input { flex: 1; min-width: 0; border: 0; background: transparent; font-size: 1rem; padding: 0.55rem 0; color: inherit; outline: none; box-shadow: none; }
.ds-help__search input::-webkit-search-cancel-button { display: none; }
.ds-help__clear { width: 2rem; height: 2rem; border-radius: 50%; color: var(--h-muted); font-size: 1.2rem; }
.ds-help__ask { padding: 0.6rem 1.1rem; border-radius: 0.75rem; font-weight: 800; background: var(--ds-navy); color: #fff; white-space: nowrap; }
.dark .ds-help__ask { background: var(--ds-signal); color: #0e2433; }
.ds-help__tries { display: flex; flex-wrap: wrap; align-items: center; gap: 0.4rem; margin: -0.25rem 0 0; font-size: 0.85rem; color: var(--h-muted); }
.ds-help__tries button { padding: 0.3rem 0.7rem; border-radius: 999px; background: var(--h-soft); box-shadow: inset 0 0 0 1px var(--h-line); color: var(--h-ink); }
.ds-help__tries button:hover { box-shadow: inset 0 0 0 1px var(--ds-signal); }
.ds-help__ai { display: flex; gap: 0.85rem; align-items: flex-start; padding: 1rem 1.1rem; border-radius: 1rem; background: linear-gradient(120deg, rgb(246 190 0 / 0.16), rgb(246 190 0 / 0.04)); box-shadow: inset 0 0 0 1px rgb(246 190 0 / 0.45); }
.ds-help__ai.is-off { background: var(--h-soft); box-shadow: inset 0 0 0 1px var(--h-line); }
.ds-help__ai-icon { font-size: 1.4rem; line-height: 1; }
.ds-help__ai strong { display: block; font-weight: 800; }
.ds-help__ai p { margin: 0.2rem 0 0; color: var(--h-muted); font-size: 0.9rem; }
.ds-help__answer { padding: 1rem 1.1rem; border-radius: 1rem; background: var(--h-card); box-shadow: 0 0 0 1px var(--h-line); }
.ds-help__answer.is-ai { box-shadow: inset 4px 0 0 var(--ds-signal), 0 0 0 1px var(--h-line); }
.ds-help__answer small { font-size: 0.75rem; font-weight: 800; color: var(--h-muted); }
.ds-help__answer p { margin: 0.35rem 0 0.6rem; font-size: 1.02rem; line-height: 1.5; }
.ds-help__answer-open { font-weight: 800; color: var(--ds-navy); text-decoration: underline; text-underline-offset: 3px; text-align: left; }
.dark .ds-help__answer-open { color: var(--ds-signal); }
.ds-help__results, .ds-help__related { display: flex; flex-direction: column; gap: 0.4rem; }
.ds-help h3 { font-size: 0.85rem; font-weight: 800; color: var(--h-muted); margin: 0.25rem 0; }
.ds-help__muted { color: var(--h-muted); font-size: 0.9rem; margin: 0; }
.ds-help__row { display: flex; align-items: center; gap: 0.8rem; width: 100%; padding: 0.75rem 0.9rem; border-radius: 0.9rem; background: var(--h-card); box-shadow: 0 0 0 1px var(--h-line); text-align: left; color: inherit; }
.ds-help__row:hover { box-shadow: 0 0 0 1px var(--ds-signal); }
.ds-help__row-icon { width: 2.25rem; height: 2.25rem; display: grid; place-items: center; border-radius: 0.7rem; background: var(--h-soft); flex: none; font-size: 1.1rem; }
.ds-help__row-text { flex: 1; min-width: 0; display: flex; flex-direction: column; gap: 0.1rem; }
.ds-help__row-text strong { font-weight: 750; }
.ds-help__row-text small { color: var(--h-muted); font-size: 0.82rem; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.ds-help__row-n { font-size: 0.75rem; color: var(--h-muted); white-space: nowrap; }
.ds-help__chev { color: var(--h-muted); font-size: 1.2rem; }
.ds-help__topics { display: grid; grid-template-columns: repeat(auto-fill, minmax(16rem, 1fr)); gap: 0.75rem; }
.ds-help__topic { padding: 1rem; border-radius: 1rem; background: var(--h-card); box-shadow: 0 0 0 1px var(--h-line); }
.ds-help__topic h3 { display: flex; align-items: center; gap: 0.45rem; color: var(--h-ink); font-size: 0.95rem; margin: 0 0 0.5rem; }
.ds-help__topic h3 small { margin-left: auto; font-size: 0.75rem; color: var(--h-muted); font-weight: 700; }
.ds-help__topic ul { list-style: none; margin: 0; padding: 0; display: flex; flex-direction: column; }
.ds-help__topic li button { width: 100%; text-align: left; padding: 0.35rem 0; font-size: 0.9rem; color: inherit; border-top: 1px solid var(--h-line); }
.ds-help__topic li:first-child button { border-top: 0; }
.ds-help__topic li button:hover { color: #b48800; }
.dark .ds-help__topic li button:hover { color: var(--ds-signal); }
.ds-help__bar { display: flex; align-items: center; gap: 0.6rem; }
.ds-help__bar > .ds-help__lang { margin-left: auto; }
.ds-help__bar-title { font-size: 1.15rem; font-weight: 800; }
.ds-help__back { font-weight: 800; color: var(--h-ink); padding: 0.35rem 0.2rem; }
.ds-help__x { width: 2.2rem; height: 2.2rem; border-radius: 50%; background: var(--h-soft); font-size: 1.3rem; line-height: 1; color: var(--h-ink); }
.ds-help__guide { display: flex; flex-direction: column; gap: 1rem; }
.ds-help__ghead { display: flex; align-items: flex-start; gap: 0.9rem; flex-wrap: wrap; }
.ds-help__ghead > div { flex: 1; min-width: 14rem; }
.ds-help__gicon { width: 3rem; height: 3rem; display: grid; place-items: center; border-radius: 0.9rem; font-size: 1.5rem; background: rgb(246 190 0 / 0.18); flex: none; }
.ds-help__ghead h2 { font-size: 1.45rem; font-weight: 800; letter-spacing: -0.015em; line-height: 1.2; margin: 0; }
.ds-help__ghead p { margin: 0.3rem 0 0; color: var(--h-muted); line-height: 1.5; }
.ds-help__doit { padding: 0.6rem 1rem; border-radius: 0.75rem; background: var(--ds-signal); color: #0e2433; font-weight: 800; white-space: nowrap; }
.ds-help__when, .ds-help__result { margin: 0; padding: 0.75rem 0.9rem; border-radius: 0.8rem; background: var(--h-soft); line-height: 1.5; }
.ds-help__when strong, .ds-help__result strong { display: block; font-size: 0.8rem; color: var(--h-muted); }
.ds-help__result { background: rgb(23 137 94 / 0.1); }
.ds-help__result strong { color: var(--ds-ok); }
.ds-help__steps { list-style: none; margin: 0; padding: 0; display: flex; flex-direction: column; gap: 0; }
.ds-help__steps li { display: flex; gap: 0.9rem; padding-bottom: 1.1rem; position: relative; }
.ds-help__steps li:not(:last-child)::before { content: ''; position: absolute; left: 0.95rem; top: 2.1rem; bottom: 0.2rem; width: 2px; background: var(--h-line); }
.ds-help__n { width: 1.9rem; height: 1.9rem; flex: none; display: grid; place-items: center; border-radius: 50%; background: var(--ds-navy); color: #fff; font-weight: 800; font-size: 0.9rem; }
.dark .ds-help__n { background: var(--ds-signal); color: #0e2433; }
.ds-help__steps strong { display: block; font-weight: 800; margin-top: 0.2rem; }
.ds-help__steps p { margin: 0.2rem 0 0; line-height: 1.55; max-width: 40rem; }
.ds-help__shot { display: block; width: fit-content; margin-top: 0.6rem; max-width: min(100%, 26rem); border-radius: 0.8rem; overflow: hidden; box-shadow: 0 0 0 1px var(--h-line), 0 8px 24px -14px rgb(0 0 0 / 0.5); }
.ds-help__shot img { display: block; max-width: 100%; max-height: 30rem; width: auto; height: auto; }
.ds-help__problems details { border-radius: 0.8rem; background: var(--h-card); box-shadow: 0 0 0 1px var(--h-line); margin-bottom: 0.4rem; }
.ds-help__problems summary { padding: 0.7rem 0.9rem; font-weight: 700; cursor: pointer; }
.ds-help__problems details p { margin: 0; padding: 0 0.9rem 0.8rem; line-height: 1.5; color: var(--h-muted); }
.ds-help__vote { display: flex; align-items: center; gap: 0.5rem; flex-wrap: wrap; padding-top: 0.75rem; border-top: 1px solid var(--h-line); font-size: 0.9rem; color: var(--h-muted); }
.ds-help__vote button { padding: 0.35rem 0.8rem; border-radius: 999px; background: var(--h-soft); box-shadow: inset 0 0 0 1px var(--h-line); color: var(--h-ink); font-weight: 700; }
.ds-help__center-link { margin-top: auto; padding-top: 0.75rem; font-weight: 800; font-size: 0.9rem; color: var(--h-muted); }
/* "?" in the top bar */
.ds-help-q { width: 2.1rem; height: 2.1rem; border-radius: 50%; display: grid; place-items: center; font-weight: 900; font-size: 1rem; color: var(--ds-navy); background: rgb(246 190 0 / 0.25); box-shadow: inset 0 0 0 1px rgb(246 190 0 / 0.7); margin-right: 0.35rem; }
.ds-help-q:hover { background: var(--ds-signal); }
.dark .ds-help-q { color: var(--ds-signal); background: rgb(246 190 0 / 0.12); }
/* the panel that "?" opens */
.ds-help-drawer { position: fixed; inset: 0; z-index: 60; display: flex; justify-content: flex-end; }
.ds-help-drawer__shade { position: absolute; inset: 0; background: rgb(6 16 24 / 0.45); border: 0; }
.ds-help-drawer__panel { position: relative; width: min(30rem, 100%); max-width: none; height: 100%; overflow-y: auto; box-sizing: border-box; padding: 1.1rem 1.2rem 1.5rem; background: #f7f9fa; box-shadow: -20px 0 50px -20px rgb(0 0 0 / 0.45); animation: help-in .22s ease-out; }
.dark .ds-help-drawer__panel { background: #0b1c28; }
@keyframes help-in { from { transform: translateX(24px); opacity: 0; } to { transform: none; opacity: 1; } }
.ds-help-drawer__panel .ds-help__topics { grid-template-columns: 1fr; }
.ds-help-drawer__panel .ds-help__shot { max-width: 100%; }
/* Scan app and Driver app: the whole phone screen, dark like the apps */
.ds-help-drawer.is-phone .ds-help-drawer__panel { width: 100%; max-width: 34rem; margin: 0 auto; box-shadow: none; animation: sa-up .25s ease-out;
    padding: calc(env(safe-area-inset-top) + 1rem) 1.2rem calc(env(safe-area-inset-bottom) + 1.5rem);
    --h-ink: #eef3f6; --h-muted: #8fa3b1; --h-card: rgb(255 255 255 / 0.05); --h-line: rgb(255 255 255 / 0.08); --h-soft: rgb(255 255 255 / 0.05); }
.ds-help-drawer.is-phone { background: radial-gradient(120% 70% at 0% 0%, #15293a 0%, #0a1219 55%); justify-content: center; }
.ds-help-drawer.is-phone .ds-help-drawer__panel { background: transparent; }
.ds-help-drawer.is-phone .ds-help__lang button.is-on, .ds-help-drawer.is-phone .ds-help__ask, .ds-help-drawer.is-phone .ds-help__n { background: var(--ds-signal); color: #0a1219; }
.ds-help-drawer.is-phone .ds-help__answer-open { color: var(--ds-signal); }
.ds-help-drawer.is-phone .ds-help__search { box-shadow: inset 0 0 0 1px rgb(255 255 255 / 0.12); }
.ds-help-drawer.is-phone .ds-help__row, .ds-help-drawer.is-phone .ds-help__topic li button { min-height: 2.75rem; }
.ds-help-drawer.is-phone .ds-help__topic li button:hover { color: var(--ds-signal); }
.ds-help-drawer.is-phone .ds-help__row-text small { white-space: normal; }
.ds-sa__help { display: grid; place-items: center; width: 2.5rem; height: 2.5rem; border-radius: 50%; flex: none; font-weight: 900; font-size: 1.05rem; color: var(--sa-gold); background: rgb(246 190 0 / 0.12); box-shadow: inset 0 0 0 1px rgb(246 190 0 / 0.35); }
.ds-sa__hello .ds-sa__help { margin-left: auto; margin-right: -0.4rem; }
.ds-sa__title--help { flex-direction: row; align-items: center; justify-content: space-between; }
.ds-sa__title--help > span { display: flex; flex-direction: column; gap: 0.25rem; }
@media (max-width: 40rem) { .ds-help__row-n { display: none; } .ds-help__hero h1 { font-size: 1.45rem; } }
@media (prefers-reduced-motion: reduce) { .ds-help-drawer__panel { animation: none !important; } }

/* ------------------------------------------------------------------ Fuel (office) */
.ds-fu { display: flex; flex-direction: column; gap: 1rem; }
.ds-fu__top { display: flex; flex-wrap: wrap; align-items: center; justify-content: space-between; gap: 0.75rem; }
.ds-fu__month, .ds-fu__form select, .ds-fu__form input[type=text], .ds-fu__tr select, .ds-fu__tr input { height: 2.25rem; padding: 0 0.7rem; border-radius: 0.55rem; border: 1px solid #d5dde3; background: #fff; font-size: 0.85rem; color: inherit; }
.dark .ds-fu__month, .dark .ds-fu__form select, .dark .ds-fu__form input[type=text], .dark .ds-fu__tr select, .dark .ds-fu__tr input { background: #0b1d2a; border-color: rgb(255 255 255 / .12); }
.ds-fu .ds-tm__stats em { display: block; }
.ds-fu .is-bad { color: #c8372d; }
.ds-fu .is-ok { color: #17895e; }
.dark .ds-fu .is-bad { color: #ff8a7e; }
.dark .ds-fu .is-ok { color: #4fd3a0; }
.ds-fu__alertbar { text-align: left; padding: 0.7rem 1rem; border-radius: 0.75rem; background: #fff4e0; color: #7a4a00; font-weight: 700; font-size: 0.88rem; }
.dark .ds-fu__alertbar { background: rgb(240 169 59 / .14); color: #f6c46b; }
.ds-fu__table { padding: 0.25rem 0; overflow-x: auto; }
.ds-fu__tr { display: grid; gap: 0.75rem; align-items: center; width: 100%; padding: 0.65rem 1rem; text-align: left; font-size: 0.88rem; border-top: 1px solid rgb(0 0 0 / .06); min-width: 40rem; }
.dark .ds-fu__tr { border-color: rgb(255 255 255 / .07); }
.ds-fu__tr.is-head { border-top: 0; font-size: 0.72rem; font-weight: 700; color: #6b7b88; }
button.ds-fu__tr:hover { background: rgb(0 0 0 / .025); }
.dark button.ds-fu__tr:hover { background: rgb(255 255 255 / .03); }
.ds-fu__tr small { display: block; font-size: 0.74rem; color: #6b7b88; }
.ds-fu__tr.is-trucks { grid-template-columns: 2fr 1fr 1fr 1.2fr 1fr 1.6fr; }
.ds-fu__tr.is-weeks { grid-template-columns: 1fr 1fr 1fr; min-width: 0; }
.ds-fu__tr.is-vat { grid-template-columns: 0.7fr 2fr 1fr 1fr 1fr 1fr 1fr; }
.ds-fu__tr.is-set { grid-template-columns: 2fr 1fr 1fr 1fr; }
.ds-fu__chg { margin-left: 0.35rem; font-style: normal; font-size: 0.74rem; font-weight: 700; color: #6b7b88; }
.ds-fu__filter { margin: 0; font-size: 0.88rem; }
.ds-fu__filter button, .ds-fu__link { text-decoration: underline; color: #1d6fb8; }
.ds-fu__fills { display: flex; flex-direction: column; gap: 0.6rem; }
.ds-fu__fill { display: grid; grid-template-columns: 4.5rem 1fr auto; gap: 1rem; align-items: center; padding: 0.75rem 1rem; }
.ds-fu__photo { width: 4.5rem; height: 4.5rem; border-radius: 0.6rem; overflow: hidden; background: #eef2f5; display: grid; place-items: center; font-size: 0.7rem; color: #8a99a5; }
.dark .ds-fu__photo { background: rgb(255 255 255 / .05); }
.ds-fu__photo img { width: 100%; height: 100%; object-fit: cover; }
.ds-fu__fillmain { display: flex; flex-direction: column; gap: 0.2rem; min-width: 0; }
.ds-fu__fillmain small { color: #6b7b88; font-size: 0.78rem; }
.ds-fu__chips { display: flex; flex-wrap: wrap; gap: 0.3rem; margin-top: 0.2rem; }
.ds-fu__chips em, .ds-fu__line em { font-style: normal; font-size: 0.72rem; font-weight: 700; padding: 0.15rem 0.5rem; border-radius: 999px; background: #eef2f5; color: #3d4f5c; }
.dark .ds-fu__chips em, .dark .ds-fu__line em { background: rgb(255 255 255 / .06); color: #c9d5de; }
.ds-fu__chips em.is-bad, .ds-fu__line em.is-bad { background: #fde8e6; }
.ds-fu__chips em.is-ok, .ds-fu__line em.is-ok { background: #e2f5ec; }
.dark .ds-fu__chips em.is-bad, .dark .ds-fu__line em.is-bad { background: rgb(255 107 94 / .14); }
.dark .ds-fu__chips em.is-ok, .dark .ds-fu__line em.is-ok { background: rgb(52 195 143 / .14); }
.ds-fu__fillnums { display: flex; flex-direction: column; align-items: flex-end; gap: 0.1rem; font-size: 0.8rem; color: #6b7b88; }
.ds-fu__fillnums b { font-size: 1.05rem; color: inherit; }
.ds-fu__fillnums b { color: #0e2433; }
.dark .ds-fu__fillnums b { color: #e6edf3; }
.ds-fu__alerts { display: flex; flex-direction: column; gap: 0.5rem; }
.ds-fu__alert { display: grid; grid-template-columns: 2.25rem 1fr auto; gap: 0.75rem; align-items: start; padding: 0.8rem 1rem; border-radius: 0.8rem; background: #fff8ec; box-shadow: inset 3px 0 0 #f0a93b; }
.ds-fu__alert.is-red { background: #fff1ef; box-shadow: inset 3px 0 0 #e0473b; }
.dark .ds-fu__alert { background: rgb(240 169 59 / .08); }
.dark .ds-fu__alert.is-red { background: rgb(255 107 94 / .09); }
.ds-fu__alert b { display: block; font-size: 0.9rem; }
.ds-fu__alert small { display: block; font-size: 0.8rem; color: #5b6b78; margin-top: 0.15rem; }
.dark .ds-fu__alert small { color: #a9b8c3; }
.ds-fu__alerticon { font-size: 1.25rem; line-height: 1.5rem; }
.ds-fu__when { white-space: nowrap; font-size: 0.74rem; color: #8a99a5; }
.ds-fu__two { display: grid; grid-template-columns: minmax(0, 1fr) minmax(0, 1.4fr); gap: 1rem; align-items: start; }
.ds-fu__two > section, .ds-fu__steps > section { padding: 1rem 1.15rem; display: flex; flex-direction: column; gap: 0.7rem; }
.ds-fu h3 { margin: 0; font-size: 0.98rem; font-weight: 800; }
.ds-fu__where { margin: 0; padding-left: 1.1rem; font-size: 0.82rem; list-style: disc; display: flex; flex-direction: column; gap: 0.2rem; }
.ds-fu__form { display: flex; flex-wrap: wrap; gap: 0.5rem; align-items: center; }
.ds-fu__form input[type=file] { font-size: 0.8rem; max-width: 100%; }
.ds-fu__form.is-stack { flex-direction: column; align-items: stretch; }
.ds-fu__form.is-stack label { display: flex; flex-direction: column; gap: 0.2rem; font-size: 0.78rem; color: #6b7b88; }
.ds-fu__err { margin: 0; color: #c8372d; font-size: 0.8rem; }
.ds-fu__counts { display: flex; flex-wrap: wrap; gap: 0.3rem; }
.ds-fu__counts button { padding: 0.25rem 0.65rem; border-radius: 999px; font-size: 0.75rem; font-weight: 700; background: #eef2f5; color: #3d4f5c; }
.ds-fu__counts button.is-on { background: #0e2433; color: #fff; }
.dark .ds-fu__counts button { background: rgb(255 255 255 / .06); color: #c9d5de; }
.dark .ds-fu__counts button.is-on { background: #e6edf3; color: #0e2433; }
.ds-fu__lines { display: flex; flex-direction: column; max-height: 32rem; overflow-y: auto; }
.ds-fu__line { display: grid; grid-template-columns: 1fr auto auto; gap: 0.75rem; align-items: center; padding: 0.5rem 0; border-top: 1px solid rgb(0 0 0 / .06); font-size: 0.84rem; }
.dark .ds-fu__line { border-color: rgb(255 255 255 / .07); }
.ds-fu__line small { color: #6b7b88; font-size: 0.75rem; }
.ds-fu__prices { display: grid; grid-template-columns: 1fr 1fr; gap: 0.6rem; }
.ds-fu__prices span { display: flex; flex-direction: column; padding: 0.75rem; border-radius: 0.7rem; background: #f3f6f8; }
.dark .ds-fu__prices span { background: rgb(255 255 255 / .04); }
.ds-fu__prices small, .ds-fu__prices em { font-size: 0.74rem; color: #6b7b88; font-style: normal; }
.ds-fu__prices b { font-size: 1.4rem; }
.ds-fu__vat { display: grid; grid-template-columns: repeat(3, minmax(0, 1fr)) auto; gap: 0.6rem; align-items: stretch; }
.ds-fu__vat > span { padding: 0.7rem 0.9rem; display: flex; flex-direction: column; gap: 0.1rem; }
.ds-fu__vat small, .ds-fu__vat em { font-size: 0.74rem; color: #6b7b88; font-style: normal; }
.ds-fu__vat b { font-size: 1.2rem; }
.ds-fu__vat > span.is-ok b { color: #17895e; }
.ds-fu__vat > span.is-bad b { color: #c8372d; }
.ds-fu__export { display: grid; place-items: center; padding: 0 1.1rem; border-radius: 0.75rem; background: #17895e; color: #fff; font-weight: 800; font-size: 0.88rem; }
.ds-fu__steps { display: grid; grid-template-columns: repeat(4, minmax(0, 1fr)); gap: 0.8rem; align-items: start; }
.ds-fu__num { display: inline-grid; place-items: center; width: 1.5rem; height: 1.5rem; margin-right: 0.35rem; border-radius: 50%; background: #0e2433; color: #fff; font-size: 0.75rem; }
.dark .ds-fu__num { background: #e6edf3; color: #0e2433; }
.ds-fu__calc { display: grid; grid-template-columns: auto 1fr; gap: 0.35rem 0.75rem; margin: 0; font-size: 0.84rem; }
.ds-fu__calc dt { color: #6b7b88; }
.ds-fu__calc dd { margin: 0; text-align: right; }
.ds-fu__calc small { display: block; font-size: 0.7rem; color: #8a99a5; }
.ds-fu__big { margin: 0; font-size: 1.9rem; font-weight: 800; letter-spacing: -0.02em; }
.ds-fu__hint { margin: 0; padding: 0.5rem 0.7rem; border-radius: 0.6rem; background: #eef5fb; font-size: 0.8rem; }
.dark .ds-fu__hint { background: rgb(90 168 255 / .1); }
@media (max-width: 1100px) { .ds-fu__two, .ds-fu__steps { grid-template-columns: 1fr; } .ds-fu__vat { grid-template-columns: 1fr 1fr; } }
@media (max-width: 640px) { .ds-fu__fill { grid-template-columns: 3.5rem 1fr; } .ds-fu__fillnums { grid-column: 2; align-items: flex-start; } .ds-fu__photo { width: 3.5rem; height: 3.5rem; } }

/* ------------------------------------------------------------------ Fuel (Driver app) */
.ds-fd__home { display: grid; grid-template-columns: 2.6rem 1fr auto; gap: 0.8rem; align-items: center; padding: 0.85rem 1rem; border-radius: 1.2rem; background: var(--sa-glass); box-shadow: inset 0 0 0 1px var(--sa-line); color: var(--sa-text); }
.ds-fd__home > span:first-child { display: grid; place-items: center; width: 2.6rem; height: 2.6rem; border-radius: 0.8rem; background: rgb(246 190 0 / .14); font-size: 1.3rem; }
.ds-fd__home b { display: block; font-size: 1rem; }
.ds-fd__home small { color: var(--sa-muted); font-size: 0.8rem; }
.ds-fd__top { display: grid; grid-template-columns: 2.5rem 1fr auto; gap: 0.75rem; align-items: center; }
.ds-fd__top > span:nth-child(2) { display: flex; flex-direction: column; }
.ds-fd__top small { color: var(--sa-muted); font-size: 0.8rem; }
.ds-fd__top strong { font-size: 1.5rem; font-weight: 700; letter-spacing: -0.02em; }
.ds-fd__back { display: grid; place-items: center; width: 2.5rem; height: 2.5rem; border-radius: 50%; background: rgb(255 255 255 / .06); color: var(--sa-text); font-size: 1.6rem; line-height: 1; }
.ds-fd__dots { display: flex; gap: 0.3rem; }
.ds-fd__dots i { width: 0.5rem; height: 0.5rem; border-radius: 50%; background: rgb(255 255 255 / .15); }
.ds-fd__dots i.is-done { background: var(--sa-ok); }
.ds-fd__dots i.is-on { background: var(--sa-gold); width: 1.3rem; border-radius: 999px; }
.ds-fd__cash { padding: 0.75rem 0.95rem; border-radius: 1rem; background: rgb(52 195 143 / .1); font-size: 0.9rem; }
.ds-fd__cash small { display: block; color: var(--sa-muted); font-size: 0.76rem; margin-top: 0.15rem; }
.ds-fd__intro { display: flex; flex-direction: column; align-items: center; text-align: center; gap: 0.5rem; margin-top: 1.5rem; }
.ds-fd__intro strong { font-size: 1.35rem; }
.ds-fd__intro p { margin: 0; color: var(--sa-muted); font-size: 0.92rem; max-width: 26rem; }
.ds-fd__big { display: grid; place-items: center; width: 5rem; height: 5rem; border-radius: 50%; background: rgb(255 255 255 / .06); font-size: 2.3rem; }
.ds-fd__big.is-ok { background: rgb(52 195 143 / .16); color: var(--sa-ok); font-weight: 800; }
.ds-fd__tin { padding: 0.6rem 0.8rem; border-radius: 0.8rem; background: rgb(246 190 0 / .1); color: var(--sa-text) !important; }
.ds-fd__actions { display: flex; flex-direction: column; gap: 0.6rem; margin-top: auto; }
.ds-fd__actions .ds-sa__primary, .ds-fd__actions .ds-sa__secondary { width: 100%; }
.ds-fd__thumb { display: grid; grid-template-columns: 4rem 1fr; gap: 0.8rem; align-items: center; padding: 0.5rem; border-radius: 1rem; background: var(--sa-glass); color: var(--sa-muted); font-size: 0.85rem; }
.ds-fd__thumb img { width: 4rem; height: 4rem; object-fit: cover; border-radius: 0.65rem; }
.ds-fd__odo { width: 100%; max-height: 14rem; object-fit: cover; border-radius: 1rem; }
.ds-fd__warn { padding: 0.7rem 0.9rem; border-radius: 0.9rem; background: rgb(240 169 59 / .14); color: #f6c46b; font-size: 0.88rem; }
.ds-fd__warn.is-bad { background: rgb(255 107 94 / .15); color: #ff9d93; }
.ds-fd__seg { display: grid; grid-auto-flow: column; grid-auto-columns: 1fr; gap: 0.3rem; padding: 0.3rem; border-radius: 1rem; background: rgb(255 255 255 / .05); }
.ds-fd__seg button { height: 2.9rem; border-radius: 0.75rem; color: var(--sa-muted); font-weight: 700; }
.ds-fd__seg button.is-on { background: var(--sa-gold); color: #0a1219; }
.ds-fd__seg.is-small button { height: 2.3rem; padding: 0 0.8rem; font-size: 0.85rem; }
.ds-fd__form { display: grid; grid-template-columns: 1fr 1fr; gap: 0.6rem; }
.ds-fd__form label { display: flex; flex-direction: column; gap: 0.25rem; }
.ds-fd__form label.is-wide, .ds-fd__form .ds-sa__err { grid-column: 1 / -1; }
.ds-fd__form small { font-size: 0.76rem; color: var(--sa-muted); }
.ds-fd__form input { height: 3rem; padding: 0 0.85rem; border-radius: 0.85rem; border: 0; background: rgb(255 255 255 / .07); color: var(--sa-text); font-size: 1rem; color-scheme: dark; }
.ds-fd__form input:focus { outline: 2px solid var(--sa-gold); }
.ds-fd__form .is-total input { height: 3.4rem; font-size: 1.35rem; font-weight: 700; }
.ds-fd__ask { display: flex; align-items: center; justify-content: space-between; gap: 0.75rem; font-size: 0.9rem; }
.ds-fd__kml { display: grid; grid-template-columns: 1fr 1fr; border-radius: 1rem; background: var(--sa-glass); box-shadow: inset 0 0 0 1px var(--sa-line); }
.ds-fd__kml span { display: flex; flex-direction: column; padding: 0.8rem 1rem; }
.ds-fd__kml span + span { box-shadow: inset 1px 0 0 var(--sa-line); }
.ds-fd__kml small { color: var(--sa-muted); font-size: 0.76rem; }
.ds-fd__kml b { font-size: 1.4rem; }
.ds-fd__btn { display: grid; place-items: center; margin-top: auto; }
DISPATCH_FILE_END_25

# ---------------------------------------------------------------- resources/views/filament/delivery/pages/driver-app.blade.php
mkdir -p 'resources/views/filament/delivery/pages'
cat > 'resources/views/filament/delivery/pages/driver-app.blade.php' <<'DISPATCH_FILE_END_26'
@php
    $ring = fn (int $done, int $total, int $len = 289) => $len - ($total > 0 ? round($len * min($done, $total) / $total) : 0);
    $p = $progress ?? ['total' => 0, 'delivered' => 0, 'notDelivered' => 0, 'left' => 0];
    $user = auth()->user();
    $initials = mb_strtoupper(mb_substr($user?->first_name ?? '', 0, 1).mb_substr($user?->last_name ?? '', 0, 1)) ?: '·';
    $photoJs = "{ busy: false, failed: false, pct: 0,
        take() { this.failed = false; this.\$refs.file.value = ''; this.\$refs.file.click() },
        async send(e) {
            const files = [...e.target.files]; if (! files.length) return;
            for (const file of files) {
                this.busy = true; this.pct = 0; let out = file;
                out = window.dsShrinkPhoto ? await window.dsShrinkPhoto(file) : file;
                await new Promise(done => \$wire.upload('upload', out, () => \$wire.savePhoto().then(done), () => { this.failed = true; done() }, (ev) => { this.pct = ev.detail.progress }));
            }
            this.busy = false;
        } }";
@endphp
<x-filament-panels::page>
<div class="ds-sa ds-dr" x-data x-on:driver-app-buzz.window="if (navigator.vibrate) navigator.vibrate($event.detail.ok ? 60 : [80, 60, 80])">
    {{-- Signal bar: drawn by driver-offline.js (shows "No signal", "waiting to send", "needs attention"). --}}
    <div id="ds-net" class="dso-net" wire:ignore aria-live="polite"></div>

    {{-- Truck tracking: location during trips, after the driver agrees once. --}}
    @include('filament.delivery.partials.tracking', ['tracking' => $tracking])

    {{-- ============================== today ============================== --}}
    @if ($screen === 'home')
        <section class="ds-sa__screen" wire:key="home">
            <header class="ds-sa__hello">
                <span>
                    <small>{{ $trip ? 'Trip '.$trip->trip_number.($trip->truck?->plate_no ? ' · Truck '.$trip->truck->plate_no : '') : now()->format('l, F j') }}</small>
                    <strong>{{ $greeting }}, {{ $user?->first_name }}</strong>
                </span>
                <button type="button" class="ds-sa__help" x-on:click="$dispatch('open-help')" aria-label="Help">?</button>
                <span class="ds-sa__avatar is-green">{{ $initials }}</span>
            </header>

            @if (\App\Support\Fuel\Fuel::ready())
                <a href="{{ \App\Filament\Delivery\Pages\Fuel::getUrl() }}" class="ds-fd__home"><span aria-hidden="true">⛽</span><span><b>Add fuel</b><small>Photo of the receipt and the odometer</small></span><span class="ds-sa__chev">›</span></a>
            @endif

            @if (! $trip)
                <div class="ds-sa__empty">
                    <span class="ds-sa__empty-icon">@include('filament.scan.icon', ['name' => 'truck'])</span>
                    <strong>You're not on a trip right now</strong>
                    <p>When the office puts you on a truck, today's boxes show up here. Pull down or reopen the app to refresh.</p>
                </div>
            @else
                @if ($finished)
                    <div class="ds-dr__celebrate">
                        <span class="ds-sa__ring is-big"><svg viewBox="0 0 110 110"><circle cx="55" cy="55" r="48" class="is-track"/><circle cx="55" cy="55" r="48" class="is-fill is-ok" style="stroke-dasharray: 302; stroke-dashoffset: 0"/></svg><span><i><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.6" stroke-linecap="round" stroke-linejoin="round"><path d="m5 12.5 4.5 4.5L19 7.5"/></svg></i></span></span>
                        <strong>All {{ $p['total'] }} boxes delivered</strong>
                        <p>Great work. The office can see every delivery and photo.</p>
                    </div>
                @else
                    <div class="ds-sa__today">
                        <span class="ds-sa__ring is-mid">
                            <svg viewBox="0 0 110 110"><circle cx="55" cy="55" r="46" class="is-track"/><circle cx="55" cy="55" r="46" class="is-fill is-green" style="stroke-dashoffset: {{ $ring($p['delivered'], $p['total']) }}"/></svg>
                            <span><strong>{{ $p['delivered'] }}</strong><small>of {{ $p['total'] }} delivered</small></span>
                        </span>
                        <dl>
                            <dt>Delivered</dt><dd class="is-ok">{{ $p['delivered'] }}</dd>
                            <dt>Still on the truck</dt><dd>{{ $p['left'] }} left</dd>
                            <dt>Not delivered</dt><dd class="is-warn">{{ $p['notDelivered'] }}</dd>
                        </dl>
                    </div>

                    <button type="button" class="ds-sa__primary ds-dr__scanbtn" wire:click="go('scan')">
                        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round"><path d="M4 8V5a1 1 0 0 1 1-1h3M16 4h3a1 1 0 0 1 1 1v3M20 16v3a1 1 0 0 1-1 1h-3M8 20H5a1 1 0 0 1-1-1v-3M7 12h10"/></svg>
                        Scan a box to deliver
                    </button>
                @endif

                @if ($priority->isNotEmpty())
                    <p class="ds-sa__label">Priority boxes</p>
                    <div class="ds-sa__list">
                        @foreach ($priority as $b)
                            <button type="button" class="ds-sa__row" wire:click="scan(@js($b['invoice']))"><span class="ds-sa__rowtext"><strong>{{ $b['invoice'] }} · {{ $b['name'] }}</strong><small>{{ $b['address'] }}</small></span><span class="ds-sa__chev">›</span></button>
                        @endforeach
                    </div>
                @endif

                @if ($problems->isNotEmpty())
                    <p class="ds-sa__label">Check before handing over</p>
                    <div class="ds-sa__list is-warn">
                        @foreach ($problems as $b)
                            <button type="button" class="ds-sa__row" wire:click="scan(@js($b['invoice']))"><span class="ds-sa__rowtext"><strong>{{ $b['invoice'] }} · {{ $b['issue'] }}</strong><small>{{ $b['name'] }}{{ $b['remarks'] ? ' · '.$b['remarks'] : '' }}</small></span><span class="ds-sa__chev">›</span></button>
                        @endforeach
                    </div>
                @endif

                @if ($stops->isNotEmpty())
                    @include('filament.delivery.partials.stops', ['stops' => $stops])
                @elseif ($areas->isNotEmpty())
                    <div class="ds-dr__labelrow"><p class="ds-sa__label">Where to go next</p><button type="button" wire:click="go('list')">All boxes ›</button></div>
                    <div class="ds-sa__list">
                        @foreach ($areas->take(6) as $a)
                            <button type="button" class="ds-sa__row" wire:click="area(@js($a['barangay'] ?: $a['city']))">
                                <span class="ds-sa__rowtext"><strong>{{ $a['barangay'] ? $a['barangay'].', ' : '' }}{{ $a['city'] }}</strong><small>{{ $a['boxes'] }} {{ str('box')->plural($a['boxes']) }} · {{ $a['stops']->count() }} {{ str('stop')->plural($a['stops']->count()) }}</small></span>
                                <span class="ds-sa__chev">›</span>
                            </button>
                        @endforeach
                    </div>
                @endif

                @if ($delivered->isNotEmpty())
                    <p class="ds-sa__label">Delivered today</p>
                    <div class="ds-sa__list">
                        @foreach ($delivered as $d)
                            <div class="ds-sa__row ds-dr__done">
                                @if ($d['photo'])<img src="{{ $d['photo'] }}" alt="" class="ds-dr__thumb">@endif
                                <span class="ds-sa__rowtext"><strong>{{ $d['invoice'] }} · {{ $d['name'] }}</strong><small>{{ $d['time'] }}</small></span>
                                @if ($d['undoMinutesLeft'])
                                    <button type="button" class="ds-dr__undo" wire:click="mountAction('undoDelivery', { tripinvoice: {{ $d['id'] }} })">Undo · {{ $d['undoMinutesLeft'] }} min left</button>
                                @else
                                    <span class="ds-dr__office">Office only</span>
                                @endif
                            </div>
                        @endforeach
                    </div>
                @endif

                @if ($crew->isNotEmpty())
                    <div class="ds-dr__crew">
                        @foreach ($crew as $c)
                            <span><i>{{ mb_strtoupper(mb_substr($c['name'], 0, 2)) }}</i>With {{ $c['name'] }}{{ $c['role'] ? ' ('.strtolower($c['role']).')' : '' }}</span>
                        @endforeach
                    </div>
                @endif
            @endif

            <footer class="ds-sa__foot">
                <span class="ds-sa__online"><i></i>Online · every delivery is saved</span>
                <span class="ds-sa__footlinks">
                    <button type="button" class="ds-pwa-install" onclick="window.dsInstallApp && window.dsInstallApp()">Install app</button>
                    <form method="POST" action="{{ filament()->getLogoutUrl() }}">@csrf<button type="submit">Sign out</button></form>
                </span>
            </footer>
        </section>
    @endif

    {{-- ============================== boxes ============================== --}}
    @if ($screen === 'list')
        <section class="ds-sa__screen" wire:key="list">
            <div class="ds-dr__listhead">
                <button type="button" class="ds-sa__back" wire:click="go('home')" aria-label="Back">‹</button>
                <strong>Boxes</strong>
                <button type="button" class="ds-dr__scanmini" wire:click="go('scan')" aria-label="Scan a box"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round"><path d="M4 8V5a1 1 0 0 1 1-1h3M16 4h3a1 1 0 0 1 1 1v3M20 16v3a1 1 0 0 1-1 1h-3M8 20H5a1 1 0 0 1-1-1v-3M7 12h10"/></svg></button>
            </div>
            <label class="ds-dr__search"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><circle cx="11" cy="11" r="7"/><path d="m20 20-3.5-3.5"/></svg>
                <input type="search" wire:model.live.debounce.350ms="search" placeholder="Name, box number or barangay" aria-label="Search boxes">
            </label>
            @php($tabs = ['todo' => 'To deliver', 'delivered' => 'Delivered', 'missed' => 'Not delivered'])
            @php($ti = array_search($tab, array_keys($tabs), true) ?: 0)
            <div class="ds-sa__seg is-3">
                <span class="ds-sa__segthumb is-light" style="left: calc(4px + {{ $ti }} * (100% - 8px) / 3)"></span>
                @foreach ($tabs as $k => $l)
                    <button type="button" wire:click="setTab('{{ $k }}')" @class(['is-on' => $tab === $k])>{{ $l }} · {{ $counts[$k] ?? 0 }}</button>
                @endforeach
            </div>
            <div class="ds-dr__rows">
                @forelse ($rows as $r)
                    @php($inv = $r->invdata)
                    <div class="ds-dr__card" wire:key="r-{{ $r->id }}">
                        <button type="button" class="ds-dr__cardmain" @if (! $r->is_delivered) wire:click="openBox({{ $r->id }})" @endif>
                            <span class="ds-dr__cardtop"><strong>{{ $r->invoice }}</strong>
                                @if ($r->is_delivered)
                                    <em class="is-ok">{{ ($r->delivered_at ?? $r->updated_at)?->format('g:i A') }}</em>
                                @elseif ($r->latestDeliveryAttempt)
                                    <em class="is-warn">{{ $r->latestDeliveryAttempt->reason->getLabel() }}</em>
                                @else
                                    <em>To deliver</em>
                                @endif
                            </span>
                            <span class="ds-dr__name">{{ \Illuminate\Support\Str::title($inv?->receiver_name) }}</span>
                            <small>{{ collect([$inv?->receiver_address, $inv?->receiver_barangay, $inv?->receiver_city])->filter()->map(fn ($x) => \Illuminate\Support\Str::title($x))->join(', ') }}</small>
                        </button>
                        @if ($inv?->receiver_mobile_no)
                            <a class="ds-dr__call" href="tel:{{ preg_replace('/[^0-9+]/', '', $inv->receiver_mobile_no) }}" aria-label="Call {{ $inv->receiver_name }}"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M5 4h4l2 5-2.5 1.5a11 11 0 0 0 5 5L15 13l5 2v4a2 2 0 0 1-2 2A16 16 0 0 1 3 6a2 2 0 0 1 2-2"/></svg></a>
                        @endif
                    </div>
                @empty
                    <div class="ds-sa__note">{{ $search !== '' ? 'No boxes match “'.$search.'”.' : 'Nothing here.' }}</div>
                @endforelse
            </div>
        </section>
    @endif

    {{-- ============================== scan ============================== --}}
    @if ($screen === 'scan')
        <section class="ds-sa__screen ds-sa__scan" wire:key="scan">
            <div class="ds-sa__cam" wire:ignore
                 x-data="barcodeScanner(@js(['method' => 'scan', 'formats' => ['code_128', 'code_39', 'ean_13', 'ean_8', 'upc_a', 'itf', 'qr_code'], 'autoStart' => true, 'continuous' => true, 'cooldown' => 3000, 'beep' => true]))">
                <video x-ref="video" playsinline muted autoplay></video>
                <div class="ds-sa__frame" x-bind:class="{ 'is-hit': flash }"><i></i><i></i><i></i><i></i><span x-show="scanning" class="ds-sa__sweep"></span></div>
                <p class="ds-sa__camtext" x-show="loading" x-cloak>Starting camera…</p>
                <p class="ds-sa__camtext" x-show="! scanning && ! loading && ! error">Camera is off · tap the round button</p>
                <p class="ds-sa__camtext is-error" x-show="error" x-text="error" x-cloak></p>
                <p class="ds-sa__camtext is-hint" x-show="hint && ! error" x-text="hint" x-cloak></p>
                <div class="ds-sa__controls">
                    <label class="ds-sa__type">
                        <input type="text" x-model="manualCode" x-on:keydown.enter.prevent="submitManual()" placeholder="Type a box number" autocomplete="off" autocapitalize="characters" spellcheck="false" enterkeyhint="go" aria-label="Box number">
                        <button type="button" x-on:click="submitManual()" aria-label="Find">→</button>
                    </label>
                    <div class="ds-sa__buttons">
                        <button type="button" class="ds-sa__round" x-show="torchSupported && scanning" x-on:click="toggleTorch()" x-bind:class="{ 'is-on': torchOn }" aria-label="Flashlight" x-cloak><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M9 2h6l-1 6h-4zM10 8h4v12a2 2 0 0 1-4 0z"/></svg></button>
                        <button type="button" class="ds-sa__shutter" x-on:click="toggle()" x-bind:aria-label="scanning ? 'Stop camera' : 'Start camera'"><span x-bind:class="{ 'is-live': scanning }"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><path d="M4 8V5a1 1 0 0 1 1-1h3M16 4h3a1 1 0 0 1 1 1v3M20 16v3a1 1 0 0 1-1 1h-3M8 20H5a1 1 0 0 1-1-1v-3M7 12h10"/></svg></span></button>
                        <button type="button" class="ds-sa__round is-text" wire:click="go('list')" aria-label="Boxes"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"><path d="M8 6h12M8 12h12M8 18h12M4 6h.01M4 12h.01M4 18h.01"/></svg></button>
                    </div>
                </div>
            </div>

            <header class="ds-sa__bar">
                <button type="button" class="ds-sa__back" wire:click="go('home')" aria-label="Back">‹</button>
                <span class="ds-sa__bartext"><small>Deliver</small><strong>{{ $trip ? 'Trip '.$trip->trip_number : 'No trip' }}</strong></span>
                <span class="ds-sa__ring is-tiny"><svg viewBox="0 0 110 110"><circle cx="55" cy="55" r="46" class="is-track"/><circle cx="55" cy="55" r="46" class="is-fill is-green" style="stroke-dashoffset: {{ $ring($p['delivered'], $p['total']) }}"/></svg></span>
                <span class="ds-sa__count"><strong>{{ $p['delivered'] }}</strong><small>of {{ $p['total'] }}</small></span>
            </header>

            @if ($just)
                <div class="ds-dr__toast" wire:key="toast-{{ $just->id }}" x-data="{ left: 15 }" x-init="const t = setInterval(() => { left--; if (left <= 0) { clearInterval(t); $wire.set('justDelivered', null) } }, 1000)">
                    <span class="ds-sa__mark is-ok"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="3" stroke-linecap="round" stroke-linejoin="round"><path d="m5 12.5 4.5 4.5L19 7.5"/></svg></span>
                    <span><strong>{{ $just->invoice }} delivered</strong><small>{{ $justPhotos }} {{ str('photo')->plural($justPhotos) }} saved · undo for <span x-text="left"></span> s</small></span>
                    <button type="button" wire:click="undoJust"><svg viewBox="0 0 40 40"><circle cx="20" cy="20" r="18" class="is-track"/><circle cx="20" cy="20" r="18" class="is-fill"/></svg>Undo</button>
                </div>
            @endif

            @if ($sheet === 'found' && $box)
                @php($inv = $box->invdata)
                @php($addr = collect([$inv?->receiver_address, $inv?->receiver_barangay, $inv?->receiver_city, $inv?->receiver_province])->filter()->map(fn ($x) => \Illuminate\Support\Str::title($x))->join(', '))
                <div class="ds-sa__sheet" wire:key="found-{{ $box->id }}">
                    <span class="ds-sa__grab"></span>
                    <div class="ds-dr__tags"><span class="ds-dr__ontruck">On your truck</span><strong>{{ $box->invoice }}</strong>@if ($inv?->boxtype)<em>{{ $inv->boxtype }}</em>@endif</div>
                    <div class="ds-dr__receiver"><strong>{{ \Illuminate\Support\Str::title($inv?->receiver_name) }}</strong><span>{{ $addr }}</span></div>
                    <div class="ds-dr__two">
                        @if ($inv?->receiver_mobile_no)
                            <a href="tel:{{ preg_replace('/[^0-9+]/', '', $inv->receiver_mobile_no) }}"><svg viewBox="0 0 24 24" fill="none" stroke="#34c38f" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M5 4h4l2 5-2.5 1.5a11 11 0 0 0 5 5L15 13l5 2v4a2 2 0 0 1-2 2A16 16 0 0 1 3 6a2 2 0 0 1 2-2"/></svg>Call</a>
                        @endif
                        <a href="https://www.google.com/maps/search/?api=1&query={{ urlencode($addr.', Philippines') }}" target="_blank" rel="noopener"><svg viewBox="0 0 24 24" fill="none" stroke="#5aa8ff" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="m3 11 18-8-8 18-2-8z"/></svg>Directions</a>
                    </div>
                    <span class="ds-dr__meta">From {{ \Illuminate\Support\Str::title($inv?->sender_name) ?: 'sender' }}@if ($household && $household['count'] > 1) · {{ $household['count'] }} boxes for this house, {{ $household['delivered'] }} delivered @endif</span>
                    @if ($box->latestDeliveryAttempt)
                        <span class="ds-dr__prev">Tried before: {{ $box->latestDeliveryAttempt->reason->getLabel() }} · {{ $box->latestDeliveryAttempt->created_at->diffForHumans() }}</span>
                    @endif
                    @if ($risk && $risk['score'] >= 50)
                        <span class="ds-dr__risk"><b>Heads up · may not be delivered</b>{{ implode(' · ', $risk['reasons']) }}. {{ $inv?->receiver_mobile_no ? 'Call before you go.' : '' }}</span>
                    @endif
                    <button type="button" class="ds-sa__primary is-green" wire:click="startDeliver">Deliver this box</button>
                    <button type="button" class="ds-sa__secondary" wire:click="startMiss">Can't deliver</button>
                </div>
            @endif

            @if ($sheet === 'deliver' && $box)
                <div class="ds-sa__sheet" wire:key="deliver-{{ $box->id }}">
                    <span class="ds-sa__grab"></span>
                    <span class="ds-dr__sheethead"><small>{{ $box->invoice }} · {{ \Illuminate\Support\Str::title($box->invdata?->receiver_name) }}</small><strong>Proof of delivery</strong><span>Take as many photos as you need: the house, the box at the door, the receiver.</span></span>
                    <div class="ds-dr__grid" x-data="{{ $photoJs }}">
                        <input type="file" accept="image/*" capture="environment" x-ref="file" class="hidden" x-on:change="send($event)">
                        @foreach ($photoUrls as $i => $url)
                            <span class="ds-dr__proof" wire:key="ph-{{ $i }}-{{ md5($url) }}"><img src="{{ $url }}" alt="Photo {{ $i + 1 }}"><b>{{ $i + 1 }}</b><button type="button" wire:click="removePhoto({{ $i }})" aria-label="Remove photo {{ $i + 1 }}">✕</button></span>
                        @endforeach
                        <button type="button" class="ds-dr__add" x-on:click="take()" x-bind:disabled="busy">
                            <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M4 8h3l2-3h6l2 3h3v11H4z"/><circle cx="12" cy="13" r="3.5"/></svg>
                            <span x-show="! busy">{{ $photoUrls ? 'Add another' : 'Take photo' }}</span>
                            <span x-show="busy" x-cloak>Saving… <span x-text="pct + '%'"></span></span>
                        </button>
                        <p class="ds-sa__err" x-show="failed" x-cloak>The photo did not upload. Try again.</p>
                    </div>
                    <button type="button" @class(['ds-sa__primary', 'is-green' => $photoUrls, 'is-off' => ! $photoUrls]) wire:click="confirmDelivered" @disabled(! $photoUrls)>
                        {{ $photoUrls ? 'Delivered · '.count($photoUrls).' '.str('photo')->plural(count($photoUrls)) : 'Take at least 1 photo' }}
                    </button>
                    <button type="button" class="ds-dr__link" wire:click="backToBox">Back</button>
                </div>
            @endif

            @if ($sheet === 'miss' && $box)
                <div class="ds-sa__sheet is-warn" wire:key="miss-{{ $box->id }}">
                    <span class="ds-sa__grab"></span>
                    <span class="ds-dr__sheethead is-warn"><small>{{ $box->invoice }} · {{ \Illuminate\Support\Str::title($box->invdata?->receiver_name) }}</small><strong>Why couldn't you deliver it?</strong></span>
                    <div class="ds-dr__chips" role="group" aria-label="Reason">
                        @foreach ($reasons as $r)
                            <button type="button" wire:click="$set('reason', '{{ $r->value }}')" @class(['is-on' => $reason === $r->value])>{{ $r->getLabel() }}</button>
                        @endforeach
                    </div>
                    @if ($voiceOn)
                        <div class="ds-dr__voice" x-data="{
                            ok: !! (window.SpeechRecognition || window.webkitSpeechRecognition), on: false, busy: false, heard: '',
                            start() {
                                const R = window.SpeechRecognition || window.webkitSpeechRecognition; if (! R) return;
                                const r = new R(); r.lang = 'fil-PH'; r.interimResults = true; r.continuous = false;
                                this.heard = ''; this.on = true;
                                r.onresult = (e) => { this.heard = Array.from(e.results).map(x => x[0].transcript).join(' ') };
                                r.onerror = () => { this.on = false };
                                r.onend = () => { this.on = false; if (this.heard.trim()) { this.busy = true; $wire.voiceFill(this.heard).then(() => this.busy = false) } };
                                r.start(); this.rec = r;
                            },
                            stop() { this.rec && this.rec.stop() }
                        }" x-show="ok" x-cloak>
                            <button type="button" x-on:click="on ? stop() : start()" x-bind:class="{ 'is-on': on }" x-bind:disabled="busy" aria-label="Say what happened">
                                <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><rect x="9" y="3" width="6" height="11" rx="3"/><path d="M5 11a7 7 0 0 0 14 0M12 18v3"/></svg>
                            </button>
                            <span>
                                <b x-text="on ? 'Listening… tap to stop' : (busy ? 'Filling in…' : 'Say what happened')"></b>
                                <small x-text="heard || 'Tagalog, Bisaya or English. The reason and note are filled in for you.'"></small>
                            </span>
                        </div>
                    @endif
                    <input type="text" class="ds-sa__note-in" wire:model.blur="note" maxlength="500" placeholder="{{ $reasonCase?->notePrompt() ?? 'Note' }}{{ $reasonCase?->requiresNote() ? '' : ' (optional)' }}" aria-label="Note">
                    <div class="ds-sa__photos" x-data="{{ $photoJs }}">
                        <input type="file" accept="image/*" capture="environment" x-ref="file" class="hidden" x-on:change="send($event)">
                        @foreach ($photoUrls as $i => $url)
                            <span class="ds-sa__shot ds-dr__proof is-small"><img src="{{ $url }}" alt=""><button type="button" wire:click="removePhoto({{ $i }})" aria-label="Remove photo">✕</button></span>
                        @endforeach
                        @if (count($photoUrls) < 3)
                            <button type="button" class="ds-sa__addphoto" x-on:click="take()" x-bind:disabled="busy">
                                <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M4 8h3l2-3h6l2 3h3v11H4z"/><circle cx="12" cy="13" r="3.5"/></svg>
                                <span x-show="! busy">{{ $reasonCase?->requiresPhoto() ? 'Add photo (needed)' : 'Add photo' }}</span><span x-show="busy" x-cloak>Saving…</span>
                            </button>
                        @endif
                    </div>
                    <button type="button" class="ds-sa__primary is-amber" wire:click="saveMissed">Keep it on the truck</button>
                    <button type="button" class="ds-dr__link" wire:click="backToBox">Back</button>
                </div>
            @endif

            @if ($sheet === 'wrong')
                <div class="ds-sa__sheet is-bad" wire:key="wrong-{{ md5((string) $wrongText) }}">
                    <span class="ds-sa__grab"></span>
                    <div class="ds-sa__hit is-shake">
                        <span class="ds-sa__mark is-bad"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="3" stroke-linecap="round"><path d="M6 6l12 12M18 6 6 18"/></svg></span>
                        <span><strong>Not this box</strong><small>Check the label</small></span>
                    </div>
                    <p class="ds-sa__msg">{{ $wrongText }}</p>
                    <button type="button" class="ds-sa__secondary" wire:click="closeSheet">Scan another box</button>
                </div>
            @endif
        </section>
    @endif
</div>
<x-filament-actions::modals />
</x-filament-panels::page>
DISPATCH_FILE_END_26

# ---------------------------------------------------------------- resources/views/filament/delivery/pages/fuel.blade.php
mkdir -p 'resources/views/filament/delivery/pages'
cat > 'resources/views/filament/delivery/pages/fuel.blade.php' <<'DISPATCH_FILE_END_27'
@php
    $peso = fn ($n, $d = 2) => '₱'.number_format((float) $n, $d);
    $photoJs = "{ busy: false, failed: false, pct: 0,
        take() { this.failed = false; this.\$refs.file.value = ''; this.\$refs.file.click() },
        async send(e) {
            const file = e.target.files[0]; if (! file) return;
            this.busy = true; this.pct = 0;
            const out = window.dsShrinkPhoto ? await window.dsShrinkPhoto(file) : file;
            await new Promise(done => \$wire.upload('upload', out, () => \$wire.savePhoto().then(done), () => { this.failed = true; done() }, (ev) => { this.pct = ev.detail.progress }));
            this.busy = false;
        } }";
    $placeJs = "{ init() { if (navigator.geolocation) navigator.geolocation.getCurrentPosition(p => \$wire.setPlace(p.coords.latitude, p.coords.longitude), () => {}, { enableHighAccuracy: true, timeout: 15000, maximumAge: 120000 }) } }";
@endphp
<x-filament-panels::page>
<div class="ds-sa ds-dr ds-fd" x-data="{{ $placeJs }}">
    <section class="ds-sa__screen" wire:key="fuel-{{ $step }}">
        <header class="ds-fd__top">
            <a href="{{ \App\Filament\Delivery\Pages\Dashboard::getUrl() }}" class="ds-fd__back" aria-label="Back to today">‹</a>
            <span><small>{{ $truck ? 'Truck '.$truck->plate_no.($truck->fuel_type ? ' · '.ucfirst($truck->fuel_type) : '') : 'No truck yet' }}</small><strong>Add fuel</strong></span>
            <span class="ds-fd__dots" aria-hidden="true">
                @foreach (['receipt', 'check', 'odometer'] as $s)<i @class(['is-on' => $step === $s, 'is-done' => array_search($step, ['receipt', 'check', 'odometer', 'done']) > $loop->index])></i>@endforeach
            </span>
        </header>

        @if ($cash && ! $cash->settled_at)
            <div class="ds-fd__cash">💵 Fuel cash for this trip <b>{{ $peso($cash->given, 0) }}</b> · left <b>{{ $peso($cash->left(), 0) }}</b><small>Use the fuel card first. Cash only if the card can't be used.</small></div>
        @endif

        {{-- ============ 1. receipt ============ --}}
        @if ($step === 'receipt')
            <div class="ds-fd__intro">
                <span class="ds-fd__big" aria-hidden="true">🧾</span>
                <strong>Take a photo of the receipt</strong>
                <p>Lay it flat, all of it in the photo: station, liters, price, total, VAT.{{ $aiOn ? ' The numbers are read for you.' : '' }}</p>
                @if ($companyTin)<p class="ds-fd__tin">For ₱1,000 and up, show the cashier the company card so they write <b>{{ $companyName ?: 'the company name' }}</b> and <b>TIN {{ $companyTin }}</b> on the receipt.</p>@endif
            </div>
            <div x-data="{{ $photoJs }}" class="ds-fd__actions">
                <input type="file" accept="image/*" capture="environment" x-ref="file" class="hidden" x-on:change="send($event)">
                <button type="button" class="ds-sa__primary" x-on:click="take()" x-bind:disabled="busy">
                    <span x-show="! busy">📷 Take receipt photo</span>
                    <span x-show="busy" x-cloak>{{ $aiOn ? 'Reading the receipt…' : 'Saving…' }} <span x-text="pct < 100 ? pct + '%' : ''"></span></span>
                </button>
                <p class="ds-sa__err" x-show="failed" x-cloak>The photo did not upload. Try again.</p>
                @error('upload')<p class="ds-sa__err">{{ $message }}</p>@enderror
                <button type="button" class="ds-dr__link" wire:click="noReceiptPhoto">No receipt · type it in</button>
            </div>
        @endif

        {{-- ============ 2. check ============ --}}
        @if ($step === 'check')
            @if ($receiptUrl)
                <a href="{{ $receiptUrl }}" target="_blank" rel="noopener" class="ds-fd__thumb"><img src="{{ $receiptUrl }}" alt="Receipt"><span>{{ $aiRead ? '✨ Read from the photo · check it' : 'Type what the receipt says' }}</span></a>
            @endif
            @if ($wrongFuel)
                <div class="ds-fd__warn is-bad">⛽ This truck uses <b>{{ $truck->fuel_type }}</b>, the receipt says <b>{{ $f['fuel_type'] }}</b>. Check the receipt, or tell the office right away.</div>
            @endif
            @foreach ($problems as $p)<div class="ds-fd__warn">⚠ {{ $p }} Check the numbers.</div>@endforeach

            <div class="ds-fd__seg" role="radiogroup" aria-label="Fuel">
                @foreach (\App\Support\Fuel\Fuel::TYPES as $k => $label)
                    <button type="button" role="radio" aria-checked="{{ $f['fuel_type'] === $k ? 'true' : 'false' }}" wire:click="$set('f.fuel_type', '{{ $k }}')" @class(['is-on' => $f['fuel_type'] === $k])>{{ $label }}</button>
                @endforeach
            </div>
            @error('f.fuel_type')<p class="ds-sa__err">{{ $message }}</p>@enderror

            <div class="ds-fd__form">
                <label class="is-wide"><small>Station</small><input type="text" wire:model.blur="f.station" placeholder="Petron Imus"></label>
                <label class="is-wide"><small>Product</small><input type="text" wire:model.blur="f.product" placeholder="Diesel Max"></label>
                <label><small>Liters</small><input type="text" inputmode="decimal" wire:model.live.debounce.600ms="f.liters" placeholder="0.00"></label>
                <label><small>Price per liter</small><input type="text" inputmode="decimal" wire:model.live.debounce.600ms="f.price_per_liter" placeholder="₱"></label>
                <label class="is-wide is-total"><small>Total</small><input type="text" inputmode="decimal" wire:model.live.debounce.600ms="f.total" placeholder="₱"></label>
                @error('f.liters')<p class="ds-sa__err">{{ $message }}</p>@enderror
                @error('f.total')<p class="ds-sa__err">{{ $message }}</p>@enderror
                <label><small>VATable sales</small><input type="text" inputmode="decimal" wire:model.blur="f.vatable" placeholder="₱"></label>
                <label><small>VAT 12%</small><input type="text" inputmode="decimal" wire:model.blur="f.vat" placeholder="₱"></label>
                <label><small>Invoice no.</small><input type="text" wire:model.blur="f.invoice_no"></label>
                <label><small>Date and time</small><input type="datetime-local" wire:model.blur="f.filled_at"></label>
            </div>

            @if ($needTin)
                <div class="ds-fd__ask">
                    <span>Is <b>TIN {{ $companyTin }}</b> written on the receipt?</span>
                    <span class="ds-fd__seg is-small">
                        <button type="button" wire:click="$set('f.buyer_tin_ok', '1')" @class(['is-on' => $f['buyer_tin_ok'] === '1'])>Yes</button>
                        <button type="button" wire:click="$set('f.buyer_tin_ok', '0')" @class(['is-on' => $f['buyer_tin_ok'] === '0'])>No</button>
                    </span>
                </div>
            @endif

            <div class="ds-fd__ask">
                <span>Paid with</span>
                <span class="ds-fd__seg is-small">
                    <button type="button" wire:click="$set('f.paid_with', 'card')" @class(['is-on' => $f['paid_with'] === 'card'])>💳 Fuel card</button>
                    <button type="button" wire:click="$set('f.paid_with', 'cash')" @class(['is-on' => $f['paid_with'] === 'cash'])>💵 Cash</button>
                </span>
            </div>
            @if ($f['paid_with'] === 'cash' && $cash && (float) $f['total'] > $cash->left() + 0.5)
                <div class="ds-fd__warn">This is more than the fuel cash left ({{ $peso($cash->left(), 0) }}).</div>
            @endif

            <button type="button" class="ds-sa__primary" wire:click="toOdometer">Next · odometer</button>
            <button type="button" class="ds-dr__link" wire:click="back">Take the receipt photo again</button>
        @endif

        {{-- ============ 3. odometer ============ --}}
        @if ($step === 'odometer')
            <div class="ds-fd__intro">
                <span class="ds-fd__big" aria-hidden="true">🚚</span>
                <strong>Photo of the odometer</strong>
                <p>The total km on the dashboard (not the trip meter). It shows how far the truck goes on a liter.</p>
            </div>
            <div x-data="{{ $photoJs }}" class="ds-fd__actions">
                <input type="file" accept="image/*" capture="environment" x-ref="file" class="hidden" x-on:change="send($event)">
                @if ($odometerUrl)<img src="{{ $odometerUrl }}" alt="Odometer" class="ds-fd__odo">@endif
                <button type="button" class="{{ $odometerUrl ? 'ds-sa__secondary' : 'ds-sa__primary' }}" x-on:click="take()" x-bind:disabled="busy">
                    <span x-show="! busy">📷 {{ $odometerUrl ? 'Take again' : 'Take odometer photo' }}</span>
                    <span x-show="busy" x-cloak>Saving… <span x-text="pct < 100 ? pct + '%' : ''"></span></span>
                </button>
                <p class="ds-sa__err" x-show="failed" x-cloak>The photo did not upload. Try again.</p>
            </div>
            <div class="ds-fd__form">
                <label class="is-wide is-total"><small>Odometer (km)</small><input type="text" inputmode="numeric" wire:model.live.debounce.600ms="f.odometer" placeholder="{{ $prevOdo ? 'last fill '.number_format($prevOdo) : '123456' }}"></label>
                @error('f.odometer')<p class="ds-sa__err">Type the km as a number.</p>@enderror
            </div>
            @if ($kmSince)
                <div class="ds-fd__kml"><span><small>Since the last fill</small><b>{{ number_format($kmSince) }} km</b></span><span><small>km per liter</small><b>{{ $kml }}</b></span></div>
            @elseif ($prevOdo && (int) $f['odometer'] > 0)
                <div class="ds-fd__warn">The last fill was at {{ number_format($prevOdo) }} km. Check the number.</div>
            @endif
            <button type="button" class="ds-sa__primary is-green" wire:click="save" wire:loading.attr="disabled">Save fill</button>
            <button type="button" class="ds-dr__link" wire:click="back">Back</button>
        @endif

        {{-- ============ done ============ --}}
        @if ($step === 'done' && $saved)
            <div class="ds-fd__intro">
                <span class="ds-fd__big is-ok" aria-hidden="true">✓</span>
                <strong>Fill saved</strong>
                <p>{{ rtrim(rtrim(number_format($saved->liters, 2), '0'), '.') }} L {{ $saved->fuel_type }} · {{ $peso($saved->total) }} · {{ $saved->paid_with === 'cash' ? 'cash' : 'fuel card' }}{{ $saved->km_per_liter ? ' · '.$saved->km_per_liter.' km/L' : '' }}</p>
                <p>Keep the paper receipt and give it to the office.</p>
            </div>
            <a href="{{ \App\Filament\Delivery\Pages\Dashboard::getUrl() }}" class="ds-sa__primary ds-fd__btn">Back to today</a>
            <button type="button" class="ds-dr__link" wire:click="another">Add another fill</button>
        @endif
    </section>
</div>
</x-filament-panels::page>
DISPATCH_FILE_END_27

# ---------------------------------------------------------------- resources/views/filament/fuel/page.blade.php
mkdir -p 'resources/views/filament/fuel'
cat > 'resources/views/filament/fuel/page.blade.php' <<'DISPATCH_FILE_END_28'
@php
    $peso = fn ($n, $d = 0) => '₱'.number_format((float) $n, $d);
    $lit = fn ($n) => rtrim(rtrim(number_format((float) $n, 2), '0'), '.').' L';
    $t = $totals;
@endphp
<x-filament-panels::page>
<div class="ds-fu">
    <div class="ds-fu__top">
        <span class="ds-tm__tabs" role="tablist">
            @foreach (['trucks' => 'Trucks', 'fills' => 'Fills', 'alerts' => 'Alerts'.(count($alerts) ? ' · '.count($alerts) : ''), 'cards' => 'Fuel cards', 'prices' => 'Prices', 'vat' => 'VAT'] as $k => $label)
                <button type="button" wire:click="setTab('{{ $k }}')" @class(['is-on' => $tab === $k]) role="tab" aria-selected="{{ $tab === $k ? 'true' : 'false' }}">{{ $label }}</button>
            @endforeach
        </span>
        <select wire:model.live="month" class="ds-fu__month" aria-label="Month">
            @foreach ($months as $k => $label)<option value="{{ $k }}">{{ $label }}</option>@endforeach
        </select>
    </div>

    <div class="ds-tm__stats is-five">
        <span class="ds-board__panel"><small>Spent</small><b>{{ $peso($t['spent']) }}</b><em>{{ $t['fills'] }} {{ str('fill')->plural($t['fills']) }}</em></span>
        <span class="ds-board__panel"><small>Liters</small><b>{{ $lit($t['liters']) }}</b><em>Diesel {{ $lit($t['diesel']) }} · Gasoline {{ $lit($t['gasoline']) }}</em></span>
        <span class="ds-board__panel"><small>VAT 12% on fuel</small><b>{{ $peso($t['vat']) }}</b><em @class(['is-bad' => $t['vatNoTin'] > 0])>{{ $t['vatNoTin'] > 0 ? '⚠ '.$peso($t['vatNoTin'], 2).' without your TIN' : 'from the receipts' }}</em></span>
        <span class="ds-board__panel"><small>Paid with</small><b>{{ 100 - $t['cashPct'] }}% card</b><em>{{ $t['cashPct'] }}% cash{{ $t['unsettled'] ? ' · '.$t['unsettled'].' cash not settled' : '' }}</em></span>
        <span class="ds-board__panel"><small>Fuel per box delivered</small><b>{{ $t['perBox'] ? $peso($t['perBox'], 2) : '—' }}</b><em>{{ number_format($t['boxes']) }} boxes · {{ $t['kml'] ? $t['kml'].' km/L' : 'km/L after 2 fills with odometer' }}</em></span>
    </div>

    {{-- ============================== trucks ============================== --}}
    @if ($tab === 'trucks')
        @if (count($alerts))
            <button type="button" class="ds-fu__alertbar" wire:click="setTab('alerts')">⚠ {{ count($alerts) }} {{ str('thing')->plural(count($alerts)) }} to check · {{ $alerts[0]['title'] }} <span aria-hidden="true">›</span></button>
        @endif
        <section class="ds-board__panel ds-fu__table">
            <div class="ds-fu__tr is-head is-trucks"><span>Truck</span><span>Liters</span><span>Spent</span><span>km per liter</span><span>₱ per km</span><span>Last fill</span></div>
            @forelse ($rows as $r)
                <button type="button" class="ds-fu__tr is-trucks" wire:click="showTruck({{ $r['truck']->id }})" wire:key="tr-{{ $r['truck']->id }}">
                    <span><b>{{ $r['truck']->plate_no }}</b> <small>{{ $r['truck']->description ?: $r['truck']->category }}{{ $r['truck']->fuel_type ? ' · '.$r['truck']->fuel_type : '' }}</small></span>
                    <span>{{ $r['fills'] ? $lit($r['liters']) : '—' }}</span>
                    <span>{{ $r['fills'] ? $peso($r['spent']) : '—' }}</span>
                    <span><b>{{ $r['kml'] ?? '—' }}</b>@if ($r['change'] !== null && abs($r['change']) >= 3) <em @class(['ds-fu__chg', 'is-bad' => $r['change'] <= -10])>{{ $r['change'] > 0 ? '▲' : '▼' }} {{ abs($r['change']) }}%</em>@endif</span>
                    <span>{{ $r['perKm'] ? $peso($r['perKm'], 2) : '—' }}</span>
                    <span><small>{{ $r['last'] ?? 'no fills this month' }}</small></span>
                </button>
            @empty
                <p class="ds-board__muted">No fills this month yet. Drivers add each fill in the Driver app: ⛽ Add fuel.</p>
            @endforelse
        </section>
    @endif

    {{-- ============================== fills ============================== --}}
    @if ($tab === 'fills')
        @if ($truckName)
            <p class="ds-fu__filter">Showing <b>{{ $truckName }}</b> · <button type="button" wire:click="$set('truck', null)">show all trucks</button></p>
        @endif
        <section class="ds-fu__fills">
            @forelse ($fills as $f)
                <article class="ds-board__panel ds-fu__fill" wire:key="fill-{{ $f->id }}">
                    @if ($f->receiptUrl())<a href="{{ $f->receiptUrl() }}" target="_blank" rel="noopener" class="ds-fu__photo"><img src="{{ $f->receiptUrl() }}" alt="Receipt" loading="lazy"></a>@else<span class="ds-fu__photo is-none">no photo</span>@endif
                    <span class="ds-fu__fillmain">
                        <b>{{ $f->truck?->plate_no }} · {{ $f->station ?: 'Station not read' }}</b>
                        <small>{{ $f->filled_at->format('M j, g:i A') }} · {{ $f->driver?->full_name ?? '—' }}{{ $f->trip ? ' · trip '.$f->trip->trip_number : '' }}</small>
                        <span class="ds-fu__chips">
                            <em @class(['is-bad' => $f->truck?->fuel_type && $f->fuel_type && $f->truck->fuel_type !== $f->fuel_type])>⛽ {{ $f->fuel_type ? ucfirst($f->fuel_type) : 'fuel ?' }}{{ $f->product ? ' · '.$f->product : '' }}</em>
                            <em>{{ $f->paid_with === 'cash' ? '💵 cash' : '💳 card'.($f->card_last4 ? ' ****'.$f->card_last4 : '') }}</em>
                            @if ($f->gps_ok === true)<em class="is-ok">📍 with the truck</em>@elseif ($f->gps_ok === false)<em class="is-bad">📍 {{ number_format($f->gps_distance_m / 1000, 1) }} km from the truck</em>@endif
                            @if ($f->km_per_liter)<em>{{ $f->km_since }} km · {{ $f->km_per_liter }} km/L</em>@endif
                            @if ($f->buyer_tin_ok === false)<em class="is-bad">⚠ your TIN missing</em>@elseif ($f->buyer_tin_ok === true)<em class="is-ok">✓ your TIN</em>@endif
                            @if ($f->ai_read)<em>✨ read by AI</em>@endif
                        </span>
                    </span>
                    <span class="ds-fu__fillnums">
                        <b>{{ $peso($f->total, 2) }}</b>
                        <small>{{ $lit($f->liters) }} × {{ $f->price_per_liter ? $peso($f->price_per_liter, 2) : '—' }}</small>
                        @if ($f->vat !== null)<small>VAT {{ $peso($f->vat, 2) }}</small>@endif
                        @if ($f->odometer)<small>Odo {{ number_format($f->odometer) }}</small>@endif
                    </span>
                </article>
            @empty
                <p class="ds-board__muted">No fills this month.</p>
            @endforelse
        </section>
    @endif

    {{-- ============================== alerts ============================== --}}
    @if ($tab === 'alerts')
        <section class="ds-fu__alerts">
            @forelse ($alerts as $a)
                <div @class(['ds-fu__alert', 'is-red' => $a['kind'] === 'red']) wire:key="al-{{ $loop->index }}">
                    <span class="ds-fu__alerticon" aria-hidden="true">{{ $a['icon'] }}</span>
                    <span><b>{{ $a['title'] }}</b><small>{{ $a['text'] }}</small></span>
                    <small class="ds-fu__when">{{ $a['when'] }}</small>
                </div>
            @empty
                <p class="ds-board__muted">Nothing to check this month. 👍</p>
            @endforelse
        </section>
    @endif

    {{-- ============================== fuel cards ============================== --}}
    @if ($tab === 'cards')
        <div class="ds-fu__two">
            <section class="ds-board__panel ds-fu__import">
                <h3>Import the fuel card statement</h3>
                <p class="ds-board__muted">Download the transactions from your fuel card website as <b>CSV</b> (Excel: File → Save As → CSV) and add the file here. Each charge is matched to a fill in the Driver app: same truck (by the card's last 4 digits or the plate), within 3 hours, same liters.</p>
                <ul class="ds-fu__where">
                    <li><b>Petron Fleet Card</b> · fleet.petron.com → statements</li>
                    <li><b>Shell Fleet Card</b> · Shell Fleet Hub → transactions</li>
                    <li><b>Caltex StarCard</b> · StarCard Online → reports</li>
                    <li><b>SEAOIL</b> · PriceLOCQ for Business → export</li>
                </ul>
                <form wire:submit="importStatement" class="ds-fu__form">
                    <select wire:model="provider" aria-label="Fuel card">
                        @foreach (\App\Support\Fuel\Fuel::PROVIDERS as $k => $label)<option value="{{ $k }}">{{ $label }}</option>@endforeach
                    </select>
                    <input type="file" wire:model="statementFile" accept=".csv,text/csv,text/plain">
                    <x-filament::button type="submit" wire:loading.attr="disabled" wire:target="statementFile,importStatement">Import</x-filament::button>
                </form>
                @error('statementFile')<p class="ds-fu__err">{{ $message }}</p>@enderror
                <p class="ds-board__muted">Set each truck's card (last 4 digits) in {{ $isAdmin ? 'Settings → Fuel' : 'Admin → Settings → Fuel' }}, so charges find their truck.</p>
            </section>
            <section class="ds-board__panel">
                @if ($statement)
                    <h3>{{ \App\Support\Fuel\Fuel::PROVIDERS[$statement->provider] ?? 'Statement' }} · {{ $statement->from?->format('M j') }}–{{ $statement->to?->format('M j') }} · {{ $statement->lines }} charges</h3>
                    <span class="ds-fu__counts">
                        <button type="button" wire:click="$set('lineStatus', '')" @class(['is-on' => $lineStatus === ''])>All</button>
                        @foreach (\App\Support\Fuel\FuelStatements::STATUS as $k => $label)
                            @if (($lineCounts[$k] ?? 0) > 0)
                                <button type="button" wire:click="$set('lineStatus', '{{ $k }}')" @class(['is-on' => $lineStatus === $k, 'is-bad' => $k !== 'matched'])>{{ $label }} · {{ $lineCounts[$k] }}</button>
                            @endif
                        @endforeach
                    </span>
                    <div class="ds-fu__lines">
                        @foreach ($lines as $l)
                            <div class="ds-fu__line" wire:key="ln-{{ $l->id }}">
                                <span><b>{{ $l->truck?->plate_no ?? ($l->plate ?: $l->card ?: '—') }}</b> <small>{{ $l->charged_at?->format('M j g:i A') }} · {{ $l->station }} · {{ $l->product }}</small></span>
                                <span>{{ $l->liters ? $lit($l->liters) : '' }} · {{ $peso($l->amount, 2) }}</span>
                                <em @class(['is-ok' => $l->status === 'matched', 'is-bad' => $l->status !== 'matched'])>{{ \App\Support\Fuel\FuelStatements::STATUS[$l->status] ?? $l->status }}{{ $l->status === 'liters_differ' && $l->fuelFill ? ' (app '.$lit($l->fuelFill->liters).')' : '' }}</em>
                            </div>
                        @endforeach
                    </div>
                    @if ($statements->count() > 1)
                        <p class="ds-board__muted">Earlier: @foreach ($statements as $s)@if ($s->id !== $statement->id)<button type="button" class="ds-fu__link" wire:click="$set('statementId', {{ $s->id }})">{{ $s->created_at->format('M j') }} ({{ $s->lines }})</button> @endif @endforeach</p>
                    @endif
                @else
                    <h3>No statement imported yet</h3>
                    <p class="ds-board__muted">After the first import, the charges and how they matched show here.</p>
                @endif
            </section>
        </div>
    @endif

    {{-- ============================== prices ============================== --}}
    @if ($tab === 'prices')
        <div class="ds-fu__two">
            <section class="ds-board__panel">
                <h3>This week's price · from {{ \App\Support\Fuel\Fuel::weekStart()->format('M j') }}</h3>
                <p class="ds-board__muted">The middle price of the receipts your drivers sent this week. Prices change every Tuesday. Used for the fuel cash estimate of a trip.</p>
                <div class="ds-fu__prices">
                    @foreach (['diesel' => 'Diesel', 'gasoline' => 'Gasoline'] as $k => $label)
                        <span><small>{{ $label }}</small><b>{{ $prices[$k]['price'] ? $peso($prices[$k]['price'], 2) : '—' }}</b><em>{{ $prices[$k]['from'] }}</em></span>
                    @endforeach
                </div>
                @if ($isAdmin)
                    <form wire:submit="savePrices" class="ds-fu__form">
                        <input type="text" inputmode="decimal" wire:model="priceDiesel" placeholder="Diesel ₱/L" aria-label="Diesel price">
                        <input type="text" inputmode="decimal" wire:model="priceGasoline" placeholder="Gasoline ₱/L" aria-label="Gasoline price">
                        <x-filament::button type="submit" color="gray">Set this week's price</x-filament::button>
                    </form>
                    <p class="ds-board__muted">Only needed when there are no receipts yet this week. Leave a box empty to use the receipts again.</p>
                @endif
            </section>
            <section class="ds-board__panel ds-fu__table">
                <div class="ds-fu__tr is-head is-weeks"><span>Week of</span><span>Diesel</span><span>Gasoline</span></div>
                @foreach ($weeks as $i => $w)
                    @php($prev = $weeks[$i + 1] ?? null)
                    <div class="ds-fu__tr is-weeks">
                        <span><b>{{ $w['week']->format('M j') }}</b></span>
                        @foreach (['diesel', 'gasoline'] as $k)
                            <span>{{ $w[$k] ? $peso($w[$k], 2) : '—' }}@if ($w[$k] && $prev && $prev[$k] && abs($w[$k] - $prev[$k]) >= 0.01) <em @class(['ds-fu__chg', 'is-bad' => $w[$k] > $prev[$k], 'is-ok' => $w[$k] < $prev[$k]])>{{ $w[$k] > $prev[$k] ? '▲' : '▼' }} {{ number_format(abs($w[$k] - $prev[$k]), 2) }}</em>@endif</span>
                        @endforeach
                    </div>
                @endforeach
            </section>
        </div>
    @endif

    {{-- ============================== VAT ============================== --}}
    @if ($tab === 'vat')
        @php($noTin = $fills->filter(fn ($f) => $f->buyer_tin_ok === false))
        <div class="ds-fu__vat">
            <span class="ds-board__panel"><small>VAT on fuel</small><b>{{ $peso($fills->sum('vat'), 2) }}</b><em>{{ $fills->whereNotNull('vat')->count() }} receipts · VATable {{ $peso($fills->sum('vatable'), 2) }}</em></span>
            <span class="ds-board__panel is-ok"><small>Can be claimed</small><b>{{ $peso($fills->sum('vat') - $noTin->sum('vat'), 2) }}</b><em>{{ $companyTin ? 'your company TIN on the receipt (or under ₱1,000)' : 'set your company TIN in Settings → Fuel' }}</em></span>
            <span @class(['ds-board__panel', 'is-bad' => $noTin->isNotEmpty()])><small>Company TIN missing</small><b>{{ $peso($noTin->sum('vat'), 2) }}</b><em>{{ $noTin->count() }} receipts of ₱1,000+ without your TIN</em></span>
            <a href="{{ $vatUrl }}" class="ds-fu__export">⬇ Excel for the accountant</a>
        </div>
        <section class="ds-board__panel ds-fu__table">
            <div class="ds-fu__tr is-head is-vat"><span>Date</span><span>Station · TIN</span><span>Invoice no.</span><span>VATable</span><span>VAT 12%</span><span>Total</span><span>Your TIN</span></div>
            @forelse ($fills as $f)
                <div class="ds-fu__tr is-vat" wire:key="vat-{{ $f->id }}">
                    <span>{{ $f->filled_at->format('M j') }}</span>
                    <span><b>{{ $f->station ?: '—' }}</b><small>{{ $f->station_tin ? 'TIN '.$f->station_tin : '' }}</small></span>
                    <span>{{ $f->invoice_no ?: '—' }}</span>
                    <span>{{ $f->vatable !== null ? $peso($f->vatable, 2) : '—' }}</span>
                    <span><b>{{ $f->vat !== null ? $peso($f->vat, 2) : '—' }}</b></span>
                    <span>{{ $peso($f->total, 2) }}</span>
                    <span>@if ($f->buyer_tin_ok === true)<em class="is-ok">✓ on receipt</em>@elseif ($f->buyer_tin_ok === false)<em class="is-bad">⚠ missing</em>@else<small>{{ $f->total < 1000 ? 'not needed' : '—' }}</small>@endif</span>
                </div>
            @empty
                <p class="ds-board__muted">No receipts this month.</p>
            @endforelse
        </section>
        <p class="ds-board__muted">Keep the paper receipts: card statements alone are not enough to claim VAT. Check the rules with your accountant.</p>
    @endif
</div>
</x-filament-panels::page>
DISPATCH_FILE_END_28

# ---------------------------------------------------------------- resources/views/filament/fuel/settings.blade.php
mkdir -p 'resources/views/filament/fuel'
cat > 'resources/views/filament/fuel/settings.blade.php' <<'DISPATCH_FILE_END_29'
<x-filament-panels::page>
<form wire:submit="save" class="ds-mp">
    <div class="ds-mp__two">
        <section class="ds-board__panel ds-tm__form">
            <div class="ds-board__panel-head"><h2>Your company on the receipt</h2></div>
            <label><span>Company name (as registered)</span><input type="text" wire:model="values.company_name" maxlength="120"></label>
            <label><span>Company TIN</span><input type="text" wire:model="values.company_tin" placeholder="123-456-789-000" inputmode="numeric"></label>
            @error('values.company_tin')<p class="ds-fu__err">{{ $message }}</p>@enderror
            <p class="ds-board__muted">To claim the 12% VAT on fuel, receipts of ₱1,000 and up need your company name and TIN. Give each driver a small card with both to show the cashier. The Fuel page flags receipts without it.</p>
        </section>
        <section class="ds-board__panel ds-tm__form">
            <div class="ds-board__panel-head"><h2>Fuel card and cash</h2></div>
            <label><span>Fuel card you use</span><select wire:model="values.card_brand">@foreach (\App\Support\Fuel\Fuel::PROVIDERS as $k => $n)<option value="{{ $k }}">{{ $n }}</option>@endforeach</select></label>
            <label><span>Give fuel cash for trips from (km)</span><input type="number" wire:model="values.cash_min_km" min="0"></label>
            <label><span>Buffer on the cash estimate (%)</span><input type="number" wire:model="values.buffer_pct" min="0" max="50"></label>
            <label><span>km per liter for a truck with no fills yet</span><input type="number" step="0.1" wire:model="values.default_kml" min="1"></label>
            <p class="ds-board__muted">The fleet card is used first. Cash is a backup for long trips or stations that don't take the card.
                Reading receipts with AI: {!! $aiOn ? '<b class="is-ok">on</b>' : '<b>off</b> · switch on "Read fuel receipts" in Settings → AI' !!}.</p>
        </section>
    </div>
    <section class="ds-board__panel">
        <div class="ds-board__panel-head"><h2>Trucks</h2></div>
        <div class="ds-fu__tr is-head is-set"><span>Truck</span><span>Fuel</span><span>Tank (L)</span><span>Fuel card · last 4</span></div>
        @foreach ($list as $t)
            <div class="ds-fu__tr is-set" wire:key="ft-{{ $t->id }}">
                <span><b>{{ $t->plate_no }}</b> <small>{{ $t->description ?: $t->category }}</small></span>
                <span><select wire:model="trucks.{{ $t->id }}.fuel_type" aria-label="Fuel for {{ $t->plate_no }}"><option value="">—</option><option value="diesel">Diesel</option><option value="gasoline">Gasoline</option></select></span>
                <span><input type="number" wire:model="trucks.{{ $t->id }}.tank_liters" min="10" aria-label="Tank liters"></span>
                <span><input type="text" wire:model="trucks.{{ $t->id }}.fuel_card_last4" maxlength="4" inputmode="numeric" placeholder="1234" aria-label="Card last 4"></span>
            </div>
            @error('trucks.'.$t->id.'.fuel_card_last4')<p class="ds-fu__err">{{ $t->plate_no }}: {{ $message }}</p>@enderror
        @endforeach
        <p class="ds-board__muted">Fuel: the Driver app and Fuel page warn when a receipt says the other fuel. Tank: a fill bigger than the tank is flagged. Card: matches the fuel card statement to the truck.</p>
    </section>
    <div><x-filament::button type="submit">Save</x-filament::button></div>
</form>
</x-filament-panels::page>
DISPATCH_FILE_END_29

# ---------------------------------------------------------------- resources/views/filament/fuel/trip.blade.php
mkdir -p 'resources/views/filament/fuel'
cat > 'resources/views/filament/fuel/trip.blade.php' <<'DISPATCH_FILE_END_30'
@php
    $peso = fn ($n, $d = 2) => '₱'.number_format((float) $n, $d);
    $lit = fn ($n) => rtrim(rtrim(number_format((float) $n, 1), '0'), '.').' L';
    $cardFills = $fills->where('paid_with', 'card');
    $cashFills = $fills->where('paid_with', 'cash');
@endphp
<x-filament-panels::page>
<div class="ds-fu">
    <div class="ds-fu__steps">
        {{-- 1. the estimate --}}
        <section class="ds-board__panel ds-fu__step">
            <h3><span class="ds-fu__num">1</span> Estimate</h3>
            <dl class="ds-fu__calc">
                <dt>Trip</dt><dd>{{ $est['km'] ? rtrim(rtrim(number_format($est['km'], 1), '0'), '.').' km' : 'not known yet' }}</dd>
                <dt>Truck</dt><dd>{{ $est['kml'] }} km/L <small>{{ $est['kmlFrom'] }}</small></dd>
                <dt>Liters</dt><dd>{{ $est['liters'] ? $lit($est['liters']) : '—' }}</dd>
                <dt>{{ ucfirst($est['type']) }} this week</dt><dd>{{ $est['price'] ? $peso($est['price']).'/L' : '—' }} <small>{{ $est['priceFrom'] }}</small></dd>
                <dt>Buffer</dt><dd>+{{ $est['buffer'] }}%</dd>
            </dl>
            <p class="ds-fu__big">{{ $est['amount'] ? $peso($est['amount'], 0) : '—' }}</p>
            @if (! $est['km'])
                <p class="ds-board__muted">Open <b>Stops &amp; loading</b> first so the route (km) is worked out.</p>
            @elseif (! $est['price'])
                <p class="ds-board__muted">No {{ $est['type'] }} price yet this week. Set it in Fuel → Prices, or wait for the first receipt.</p>
            @endif
            @if ($est['short'])
                <p class="ds-fu__hint">Short trip (under {{ $minKm }} km): the fuel card should be enough. Cash is a backup.</p>
            @endif
        </section>

        {{-- 2. give the cash --}}
        <section class="ds-board__panel ds-fu__step">
            <h3><span class="ds-fu__num">2</span> Cash given</h3>
            @if ($cash)
                <p class="ds-fu__big">{{ $peso($cash->given, 0) }}</p>
                <p class="ds-board__muted">{{ $cash->given_at->format('M j, g:i A') }} · by {{ $cash->givenBy?->full_name ?? '—' }}{{ $cash->estimate && abs($cash->estimate - $cash->given) >= 1 ? ' · estimate was '.$peso($cash->estimate, 0) : '' }}</p>
                @if ($cash->note)<p class="ds-board__muted">“{{ $cash->note }}”</p>@endif
                @if (! $cash->settled_at && $cash->given_at->gt(now()->subHour()))
                    <x-filament::button color="gray" size="sm" wire:click="undoCash" wire:confirm="Remove this fuel cash?">Undo</x-filament::button>
                @endif
            @else
                <form wire:submit="giveCash" class="ds-fu__form is-stack">
                    <label><small>Amount</small><input type="text" inputmode="decimal" wire:model="give" placeholder="₱" aria-label="Cash amount"></label>
                    <label><small>Note (optional)</small><input type="text" wire:model="note" maxlength="200" placeholder="e.g. toll and fuel"></label>
                    <x-filament::button type="submit">Give cash</x-filament::button>
                </form>
                <p class="ds-board__muted">The driver sees the cash in the Driver app and pays with it only when the card can't be used.</p>
            @endif
        </section>

        {{-- 3. fills on the trip --}}
        <section class="ds-board__panel ds-fu__step">
            <h3><span class="ds-fu__num">3</span> Fills on this trip</h3>
            @forelse ($fills as $f)
                <div class="ds-fu__line">
                    <span><b>{{ $f->filled_at->format('g:i A') }} · {{ $f->station ?: 'Station' }}</b> <small>{{ $lit($f->liters) }} {{ $f->product }}</small></span>
                    <span>{{ $peso($f->total) }}</span>
                    <em>{{ $f->paid_with === 'cash' ? '💵 cash' : '💳 card' }}</em>
                </div>
            @empty
                <p class="ds-board__muted">No fills yet. The driver adds each fill in the Driver app: ⛽ Add fuel.</p>
            @endforelse
            @if ($fills->isNotEmpty())
                <p class="ds-board__muted">Card {{ $peso($cardFills->sum('total')) }} · Cash {{ $peso($cashFills->sum('total')) }}</p>
            @endif
        </section>

        {{-- 4. settle --}}
        <section class="ds-board__panel ds-fu__step">
            <h3><span class="ds-fu__num">4</span> Settle</h3>
            @if (! $cash)
                <p class="ds-board__muted">No cash given for this trip.</p>
            @else
                <dl class="ds-fu__calc">
                    <dt>Given</dt><dd>{{ $peso($cash->given) }}</dd>
                    <dt>Cash receipts</dt><dd>− {{ $peso($cash->spent()) }}</dd>
                    <dt><b>Change to return</b></dt><dd><b>{{ $peso($cash->left()) }}</b></dd>
                </dl>
                @if ($cash->settled_at)
                    @php($short = round($cash->given - $cash->spent() - $cash->returned, 2))
                    <p @class(['ds-fu__hint', 'is-ok' => abs($short) < 1, 'is-bad' => abs($short) >= 1])>
                        ✓ Settled {{ $cash->settled_at->format('M j, g:i A') }} · {{ $peso($cash->returned) }} returned
                        @if (abs($short) >= 1)· {{ $short > 0 ? $peso($short).' missing' : $peso(-$short).' over' }}@endif
                    </p>
                @else
                    <form wire:submit="settle" class="ds-fu__form is-stack">
                        <label><small>Change returned by the driver</small><input type="text" inputmode="decimal" wire:model="returned" placeholder="{{ number_format($cash->left(), 2) }}"></label>
                        <x-filament::button type="submit" color="success">Settle</x-filament::button>
                    </form>
                @endif
            @endif
        </section>
    </div>
</div>
</x-filament-panels::page>
DISPATCH_FILE_END_30

# ---------------------------------------------------------------- routes/web.php
mkdir -p 'routes'
cat > 'routes/web.php' <<'DISPATCH_FILE_END_31'
<?php

use App\Http\Controllers\AiChatController;
use App\Http\Controllers\BoxPhotoController;
use App\Http\Controllers\DriverOfflineController;
use App\Http\Controllers\FuelController;
use App\Http\Controllers\InstallQrController;
use App\Http\Controllers\InvoiceController;
use App\Http\Controllers\LoadingListController;
use App\Http\Controllers\PwaController;
use App\Http\Controllers\TrackController;
use Illuminate\Foundation\Http\Middleware\ValidateCsrfToken;
use Illuminate\Foundation\Http\Middleware\VerifyCsrfToken;
use Illuminate\Support\Facades\Route;

// Printable delivery receipt. Only signed-in users (any panel) may print.
Route::get('/tripinv/{invoice}/printpdf', [InvoiceController::class, 'tripinvoice'])
    ->middleware('auth')
    ->whereNumber('invoice')
    ->name('invoicepdf');

// Several receipts at once (at most 15), one per page: /tripinv/print?ids=1,2,3
Route::get('/tripinv/print', [InvoiceController::class, 'bulk'])
    ->middleware('auth')
    ->name('invoicepdf.bulk');

// Install the Delivery panel as an app (PWA): manifest, icons, service worker and offline page.
Route::controller(PwaController::class)->group(function () {
    Route::get('/sw.js', 'serviceWorker')->name('pwa.sw');
    Route::get('/pwa/offline', 'offline')->name('pwa.offline');
    Route::get('/pwa/{panel}/manifest.webmanifest', 'manifest')->whereIn('panel', ['delivery', 'scan'])->name('pwa.manifest');
    Route::get('/pwa/{panel}/icon-{size}.png', 'icon')->whereIn('panel', ['delivery', 'scan'])->whereNumber('size')->name('pwa.icon');
});

Route::middleware('web')->group(function () {
    Route::get('/box-photos/{photo}.jpg', [BoxPhotoController::class, 'show'])->whereNumber('photo')->name('box-photos.show');
    Route::get('/box-photos/{photo}/download', [BoxPhotoController::class, 'download'])->whereNumber('photo')->name('box-photos.download');
});

// Driver app without signal: today's boxes for the phone, sending what was saved offline, and the offline page.
Route::middleware('web')->group(function () {
    Route::get('/delivery-offline/trip', [DriverOfflineController::class, 'trip'])->name('driver-offline.trip');
    Route::post('/delivery-offline/sync', [DriverOfflineController::class, 'sync'])->name('driver-offline.sync');
    Route::get('/delivery-offline', [DriverOfflineController::class, 'shell'])->name('driver-offline.shell');
});

// Customer chat: receivers ask about their own box (only while "Customer chat" is on in Admin → Settings → AI).
Route::middleware(['web', 'throttle:30,60'])->controller(AiChatController::class)->group(function () {
    Route::get('/ask-box', 'show')->name('ai-chat.show');
    Route::post('/ask-box', 'start')->name('ai-chat.start');
    Route::get('/ask-box/{token}', 'chat')->name('ai-chat.chat');
    Route::post('/ask-box/{token}', 'ask')->name('ai-chat.ask');
});

// Install QR codes for the phone apps (signed-in staff only): download, poster, stickers.
Route::middleware(['web', 'auth'])->controller(InstallQrController::class)->group(function () {
    Route::get('/install-qr/{app}.png', 'png')->whereIn('app', ['scan', 'driver'])->name('install-qr.png');
    Route::get('/install-qr/{app}/poster', 'poster')->whereIn('app', ['scan', 'driver'])->name('install-qr.poster');
    Route::get('/install-qr/{app}/stickers', 'stickers')->whereIn('app', ['scan', 'driver'])->name('install-qr.stickers');
});

// Maps & routes: printed loading list of a trip (FRONT → MIDDLE → BACK).
Route::middleware(['web', 'auth'])->get('/trip-loading/{trip}', [LoadingListController::class, 'show'])
    ->whereNumber('trip')->name('trip.loading-list');

// Truck tracking: the Driver app sends locations during a trip; GPS trackers send to a secret link.
Route::middleware(['web', 'auth', 'throttle:120,1'])->post('/delivery-track', [TrackController::class, 'driver'])->name('track.driver');
Route::middleware(['throttle:600,1'])->match(['get', 'post'], '/track/in/{token}', [TrackController::class, 'tracker'])
    ->withoutMiddleware([ValidateCsrfToken::class, VerifyCsrfToken::class, 'Illuminate\Foundation\Http\Middleware\PreventRequestForgery'])
    ->name('track.tracker');

// Fuel › VAT: the month's fuel receipts for the accountant (signed-in staff, their own hub).
Route::get('/fuel/vat-export', [FuelController::class, 'vatExport'])->middleware(['web', 'auth'])->name('fuel.vat-export');
DISPATCH_FILE_END_31

# ---------------------------------------------------------------- tests/Feature/FuelTest.php
mkdir -p 'tests/Feature'
cat > 'tests/Feature/FuelTest.php' <<'DISPATCH_FILE_END_32'
<?php

use App\Filament\Delivery\Pages\Dashboard as DriverDashboard;
use App\Filament\Delivery\Pages\Fuel as DriverFuel;
use App\Filament\Pages\Fuel as AdminFuel;
use App\Filament\Pages\FuelSettings;
use App\Filament\Pages\TripFuel as AdminTripFuel;
use App\Filament\Warehouse\Pages\Fuel as WarehouseFuel;
use App\Models\Deliverylog;
use App\Models\Fuel\FuelCash;
use App\Models\Fuel\FuelFill;
use App\Models\Fuel\FuelStatementLine;
use App\Models\Logistichub;
use App\Models\Maps\TripRoute;
use App\Models\Tracking\TruckPosition;
use App\Models\Truck;
use App\Models\Truckcrew;
use App\Models\User;
use App\Support\Fuel\Fuel;
use App\Support\Fuel\FuelReader;
use App\Support\Fuel\FuelReport;
use App\Support\Fuel\FuelStatements;
use Database\Seeders\DemoSeeder;
use Filament\Facades\Filament;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Illuminate\Http\UploadedFile;
use Illuminate\Support\Facades\Storage;
use Livewire\Livewire;

uses(RefreshDatabase::class);

beforeEach(function () {
    $this->seed(DemoSeeder::class);
    $this->admin = User::where('email', 'admin@example.com')->firstOrFail();
    $this->driver = User::where('email', 'driver@example.com')->firstOrFail();
    $this->hub = $this->driver->logistichub_id;
    Deliverylog::query()->update(['is_active' => false]);
    $this->truck = Truck::create(['plate_no' => 'FUE 123', 'logistichub_id' => $this->hub, 'is_active' => true, 'is_assigned' => true, 'capacity' => 40, 'category' => 'Truck', 'description' => '6-wheeler', 'registration_no' => 'RF', 'user_id' => $this->admin->id, 'date_registered' => now(), 'date_expired' => now()->addYear(), 'fuel_type' => 'diesel', 'tank_liters' => 100, 'fuel_card_last4' => '4321']);
    Truckcrew::create(['truck_id' => $this->truck->id, 'crew' => $this->driver->id, 'user_id' => $this->admin->id]);
    $this->trip = Deliverylog::create(['truck_id' => $this->truck->id, 'logistichub_id' => $this->hub, 'assigned_to' => $this->hub, 'user_id' => $this->admin->id, 'trip_day' => 1, 'eta' => today(), 'departure_date' => today(), 'is_active' => true]);
    $this->actingAs($this->admin);
    Filament::setCurrentPanel(Filament::getPanel('admin'));
});

function fill(array $over = []): FuelFill
{
    $t = test();

    return Fuel::save(array_merge(['filled_at' => now()->subHour(), 'station' => 'Petron Imus', 'product' => 'Diesel Max', 'liters' => 40, 'total' => 2400, 'vat' => 257.14, 'paid_with' => 'card'], $over), $t->truck, $t->driver, $t->trip);
}

it('knows diesel from gasoline by the product name', function () {
    expect(Fuel::typeOf('Diesel Max'))->toBe('diesel')
        ->and(Fuel::typeOf('V-Power Diesel'))->toBe('diesel')
        ->and(Fuel::typeOf('Shell V-Power'))->toBe('gasoline')
        ->and(Fuel::typeOf('XCS'))->toBe('gasoline')
        ->and(Fuel::typeOf('Petron Turbo Diesel'))->toBe('diesel')
        ->and(Fuel::typeOf('Milk tea'))->toBeNull();
});

it('works out price per liter, km per liter and VAT when a fill is saved', function () {
    $a = fill(['odometer' => 10000, 'filled_at' => now()->subDays(2)]);
    expect($a->price_per_liter)->toBe(60.0)->and($a->vatable)->toBe(2142.86)->and($a->km_since)->toBeNull();
    $b = fill(['odometer' => 10300, 'liters' => 50, 'total' => 3000]);
    expect($b->km_since)->toBe(300)->and($b->km_per_liter)->toBe(6.0);
});

it('checks the company TIN only for ₱1,000 and up', function () {
    Fuel::put('company_tin', '123-456-789-000');
    expect(Fuel::buyerTinOk('123456789000', 2400))->toBeTrue()
        ->and(Fuel::buyerTinOk(null, 2400))->toBeFalse()
        ->and(Fuel::buyerTinOk(null, 800))->toBeNull();
});

it('checks the phone against the truck GPS', function () {
    TruckPosition::insert(['truck_id' => $this->truck->id, 'deliverylog_id' => $this->trip->id, 'lat' => 14.40, 'lng' => 120.94, 'speed' => 0, 'source' => 'app', 'recorded_at' => now()->subMinutes(62)]);
    $near = fill(['lat' => 14.401, 'lng' => 120.941]);
    $far = fill(['lat' => 14.60, 'lng' => 121.00, 'filled_at' => now()->subMinutes(58)]);
    expect($near->gps_ok)->toBeTrue()->and($far->gps_ok)->toBeFalse()->and($far->gps_distance_m)->toBeGreaterThan(5000);
});

it('takes this week\'s price from the receipts, or the office price', function () {
    fill(['liters' => 40, 'total' => 2400]);
    fill(['liters' => 10, 'total' => 620]);
    fill(['liters' => 10, 'total' => 610]);
    expect(Fuel::price('diesel')['price'])->toBe(61.0)->and(Fuel::price('gasoline')['price'])->toBeNull();
    Fuel::put('price.gasoline', ['week' => Fuel::weekStart()->toDateString(), 'price' => 66.5]);
    expect(Fuel::price('gasoline'))->toMatchArray(['price' => 66.5, 'from' => 'set by the office']);
    expect(Fuel::weekStart(\Illuminate\Support\Carbon::parse('2026-11-16'))->toDateString())->toBe('2026-11-10'); // Monday → last Tuesday
});

it('estimates the fuel cash of a trip and settles it', function () {
    TripRoute::updateOrCreate(['deliverylog_id' => $this->trip->id], ['km' => 210]);
    Fuel::put('price.diesel', ['week' => Fuel::weekStart()->toDateString(), 'price' => 60]);
    $e = Fuel::estimate($this->trip);
    expect($e['liters'])->toBe(30.0)->and($e['amount'])->toBe(1980.0)->and($e['short'])->toBeFalse(); // 210 ÷ 7 × 60 + 10%

    Livewire::test(AdminTripFuel::class, ['tripId' => $this->trip->id])->assertSee('₱1,980')->set('give', '2000')->call('giveCash');
    $cash = FuelCash::firstOrFail();
    expect($cash->given)->toBe(2000.0)->and($cash->driver_id)->toBe($this->driver->id);

    fill(['paid_with' => 'cash', 'liters' => 25, 'total' => 1500]);
    expect($cash->fresh()->left())->toBe(500.0);
    Livewire::test(AdminTripFuel::class, ['tripId' => $this->trip->id])->set('returned', '500')->call('settle');
    expect($cash->fresh()->settled_at)->not->toBeNull()->and($cash->fresh()->returned)->toBe(500.0);
});

it('lets the driver add a fill from the Driver app', function () {
    Storage::fake('public');
    $this->actingAs($this->driver);
    Filament::setCurrentPanel(Filament::getPanel('delivery'));
    Livewire::test(DriverDashboard::class)->assertSee('Add fuel');

    Livewire::test(DriverFuel::class)
        ->set('upload', UploadedFile::fake()->image('receipt.jpg', 800, 1200))->call('savePhoto')
        ->assertSet('step', 'check')
        ->set('f.fuel_type', 'gasoline')->assertSee('This truck uses')
        ->set('f.fuel_type', 'diesel')->set('f.liters', '45.5')->set('f.total', '2,730.00')->set('f.vat', '292.50')
        ->call('toOdometer')->assertHasNoErrors()->assertSet('step', 'odometer')
        ->set('f.odometer', '55210')->call('save')->assertSet('step', 'done')->assertSee('Fill saved');

    $f = FuelFill::firstOrFail();
    expect($f->truck_id)->toBe($this->truck->id)->and($f->deliverylog_id)->toBe($this->trip->id)->and($f->price_per_liter)->toBe(60.0)
        ->and($f->receipt_path)->toStartWith('fuel/')->and($f->odometer)->toBe(55210);
    Storage::disk('public')->assertExists($f->receipt_path);
});

it('does not let the driver point the photo at another file', function () {
    $this->actingAs($this->driver);
    Filament::setCurrentPanel(Filament::getPanel('delivery'));
    Livewire::test(DriverFuel::class)->set('receiptPath', 'other/secret.jpg');
})->throws(\Livewire\Features\SupportLockedProperties\CannotUpdateLockedPropertyException::class);

it('flags wrong fuel, over the tank, two fills close together and the TIN missing', function () {
    Fuel::put('company_tin', '123-456-789-000');
    fill(['product' => 'XCS', 'liters' => 20, 'total' => 1300, 'filled_at' => now()->subMinutes(100)]);
    fill(['liters' => 120, 'total' => 7200, 'filled_at' => now()->subMinutes(30)]);
    $alerts = collect((new FuelReport(null))->alerts())->pluck('title')->join(' | ');
    expect($alerts)->toContain('(diesel) · gasoline on the receipt')->toContain('120 L in one fill')->toContain('two fills in 70 minutes')->toContain('without your company TIN');
});

it('imports a fuel card statement and matches it to the fills', function () {
    $a = fill(['filled_at' => now()->subHours(5), 'liters' => 40]);
    fill(['filled_at' => now()->subHours(2), 'liters' => 30, 'total' => 1800]);
    $at = fn ($h) => now()->subHours($h)->format('m/d/Y H:i');
    $csv = tempnam(sys_get_temp_dir(), 'st');
    file_put_contents($csv, "Petron Fleet Card Statement\nAccount: 0001\n"
        ."Transaction Date,Card Number,Plate No,Station Name,Product,Liters,Amount\n"
        .$at(5).",7000 1234 5678 4321,,Petron Imus,Diesel Max,40.00,\"2,400.00\"\n"
        .$at(2).",7000 1234 5678 4321,,Petron Imus,Diesel Max,36.00,\"2,160.00\"\n"
        .$at(30).",7000 1234 5678 4321,,Petron Bacoor,Diesel Max,50.00,\"3,000.00\"\n"
        .$at(3).",7000 1234 5678 9999,ZZZ 999,Petron Kawit,XCS,10.00,650.00\n");
    $s = FuelStatements::import($csv, 'petron', $this->admin->id, null, 'statement.csv');
    $by = FuelStatementLine::where('fuel_statement_id', $s->id)->orderBy('charged_at')->pluck('status')->all();
    expect($s->lines)->toBe(4)->and($by)->toBe(['no_fill', 'matched', 'no_truck', 'liters_differ'])
        ->and(FuelStatementLine::where('status', 'matched')->value('fuel_fill_id'))->toBe($a->id);
});

it('shows the Fuel page in Admin with every tab, and in Warehouse only its own trucks', function () {
    fill(['station' => 'Petron Imus']);
    $other = Truck::create(['plate_no' => 'OTH 1', 'logistichub_id' => Logistichub::where('id', '!=', $this->hub)->value('id'), 'is_active' => true, 'is_assigned' => false, 'capacity' => 40, 'category' => 'Truck', 'description' => 'x', 'registration_no' => 'RO', 'user_id' => $this->admin->id, 'date_registered' => now(), 'date_expired' => now()->addYear()]);
    Fuel::save(['liters' => 10, 'total' => 600, 'station' => 'Shell Far Away'], $other, null, null);

    $this->get(AdminFuel::getUrl())->assertOk()->assertSee('FUE 123')->assertSee('OTH 1');
    foreach (['fills', 'alerts', 'cards', 'prices', 'vat'] as $tab) {
        Livewire::test(AdminFuel::class)->call('setTab', $tab)->assertOk();
    }
    Livewire::test(AdminFuel::class)->call('setTab', 'fills')->assertSee('Shell Far Away');
    $this->get(route('fuel.vat-export', ['month' => now()->format('Y-m'), 'panel' => 'admin']))->assertOk()->assertHeader('content-type', 'text/csv; charset=UTF-8');

    $wh = User::where('email', 'warehouse@example.com')->firstOrFail();
    $this->actingAs($wh);
    Filament::setCurrentPanel(Filament::getPanel('warehouse'));
    $this->get(WarehouseFuel::getUrl())->assertOk()->assertSee('FUE 123')->assertDontSee('OTH 1');
    Livewire::test(WarehouseFuel::class)->call('setTab', 'fills')->assertSee('Petron Imus')->assertDontSee('Shell Far Away')->call('savePrices')->assertForbidden();
    $csv = $this->get(route('fuel.vat-export', ['panel' => 'warehouse']))->streamedContent();
    expect($csv)->toContain('Petron Imus')->not->toContain('Shell Far Away');
});

it('saves the fuel settings for each truck', function () {
    $this->get(FuelSettings::getUrl())->assertOk()->assertSee('FUE 123');
    Livewire::test(FuelSettings::class)->set('values.company_tin', '123-456-789-000')->set("trucks.{$this->truck->id}.fuel_type", 'gasoline')
        ->set("trucks.{$this->truck->id}.fuel_card_last4", '12')->call('save')->assertHasErrors(["trucks.{$this->truck->id}.fuel_card_last4"])
        ->set("trucks.{$this->truck->id}.fuel_card_last4", '1111')->call('save')->assertHasNoErrors();
    expect($this->truck->fresh()->fuel_type)->toBe('gasoline')->and(Fuel::companyTin())->toBe('123-456-789-000');
});

it('checks the receipt numbers add up', function () {
    expect(FuelReader::problems(['liters' => 40, 'price_per_liter' => 60, 'total' => 2400]))->toBe([])
        ->and(FuelReader::problems(['liters' => 40, 'price_per_liter' => 60, 'total' => 2600]))->toHaveCount(1)
        ->and(FuelReader::problems(['total' => 2400, 'vatable' => 2000, 'vat' => 257.14]))->toHaveCount(1);
});
DISPATCH_FILE_END_32

echo "▶ Updating the database (keeps your data)"
php artisan migrate --force

echo "▶ Rebuilding the design"
npm run build

echo "▶ Clearing caches"
php artisan optimize:clear

echo "▶ Running the tests"
php artisan test || echo "Some tests failed — send the red text for help."

echo
echo "✓ Done. Backup: $BACKUP"
echo "  Start the app with:  PHP_CLI_SERVER_WORKERS=4 php artisan serve   (or open https://dispatchsystem.test in Herd)"
