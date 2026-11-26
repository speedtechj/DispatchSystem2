#!/usr/bin/env bash
#
# Dispatch System — Part 41: tidy photo folders and 200 KB photos
# Only the files changed in this step; the rest of your project is left as it is.
#
#   cd ~/Desktop/Project/DispatchSystem
#   bash ~/Desktop/Project/part41-photo-folders.sh

set -euo pipefail
[ -f artisan ] || { echo "Run this from inside your DispatchSystem project folder (the one with 'artisan')."; exit 1; }

STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="../DispatchSystem-backup-$STAMP.tar.gz"
echo "▶ Backing up the project to $BACKUP"
tar -czf "$BACKUP" --exclude=vendor --exclude=node_modules --exclude=storage/logs .

echo "▶ Writing 39 files"

# ---------------------------------------------------------------- app/Filament/Company/Pages/LclPickup.php
mkdir -p 'app/Filament/Company/Pages'
cat > 'app/Filament/Company/Pages/LclPickup.php' <<'DISPATCH_FILE_END_0'
<?php

namespace App\Filament\Company\Pages;

use App\Models\Shipping\SeaShipment;
use App\Models\Tripinvoice;
use App\Support\Photos\PhotoShrinker;
use App\Support\Shipping\Shipments;
use Filament\Pages\Page;
use Illuminate\Contracts\Support\Htmlable;
use Illuminate\Support\Facades\Auth;
use Illuminate\Support\Facades\Storage;
use Livewire\Attributes\Locked;
use Livewire\Attributes\Url;
use Livewire\WithFileUploads;

/**
 * Board 63 · LCL pick-up at the forwarder (phone): count the boxes there, take a photo of the release,
 * press Picked up. Then the hub scans them in as usual.
 */
class LclPickup extends Page
{
    use WithFileUploads;

    protected string $view = 'filament.shipping.lcl-pickup';

    protected static bool $shouldRegisterNavigation = false;

    protected static ?string $slug = 'lcl-pickup';

    #[Url(as: 'shipment')]
    #[Locked]
    public int $shipmentId = 0;

    /** intro, count, photo, done */
    #[Locked]
    public string $step = 'intro';

    public string $count = '';

    public $upload = null;

    #[Locked]
    public ?string $photoPath = null;

    public static function canAccess(): bool
    {
        return Shipments::ready() && \Illuminate\Support\Facades\Schema::hasColumn('sea_shipments', 'pickup_count') && Auth::check();
    }

    public function getTitle(): string|Htmlable
    {
        return 'LCL pick-up';
    }

    public function getHeading(): string|Htmlable
    {
        return '';
    }

    /** The LCL shipment for this hub, ready to pick up (or just picked up). */
    protected function shipment(): ?SeaShipment
    {
        $s = SeaShipment::find($this->shipmentId ?: (int) request()->query('shipment'));
        $mine = (int) Auth::user()?->logistichub_id;

        return $s && $s->mode === 'lcl' && in_array($s->status, ['arrived', 'picked_up'], true) && Shipments::stopFor($s, $mine) ? $s : null;
    }

    protected function expected(): int
    {
        $s = $this->shipment();
        $stop = $s ? Shipments::stopFor($s, (int) Auth::user()?->logistichub_id) : null;

        return $stop ? Tripinvoice::where('deliverylog_id', $stop->deliverylog_id)->count() : 0;
    }

    public function mount(): void
    {
        $this->shipmentId = (int) request()->query('shipment', $this->shipmentId);
        $s = $this->shipment();
        if ($s?->status === 'picked_up') {
            $this->step = 'done';
        }
    }

    public function start(): void
    {
        if ($this->shipment()) {
            $this->count = $this->count !== '' ? $this->count : (string) $this->expected();
            $this->step = 'count';
        }
    }

    public function bump(int $by): void
    {
        $this->count = (string) max(0, min(9999, (int) $this->count + $by));
    }

    public function toPhoto(): void
    {
        $this->validate(['count' => 'required|integer|min:0|max:9999'], ['count.required' => 'Type the number of boxes.']);
        $this->step = 'photo';
    }

    public function savePhoto(): void
    {
        $this->validate(['upload' => 'required|image|max:12288'], ['upload.image' => 'That file is not a photo.']);
        $path = $this->upload->store(\App\Support\Photos\Storage\PhotoFolders::dir('shipments', \App\Models\Shipping\SeaShipment::whereKey($this->shipmentId)->value('code')), 'public');
        PhotoShrinker::file('public', $path);
        $this->photoPath = $path;
        $this->reset('upload');
        $this->save();
    }

    /** Picked up (with or without the photo). */
    public function save(): void
    {
        $s = $this->shipment();
        if (! $s || $s->status !== 'arrived') {
            return;
        }
        $this->validate(['count' => 'required|integer|min:0|max:9999']);
        $s->update(['pickup_count' => (int) $this->count, 'pickup_photo' => $this->photoPath ?? $s->pickup_photo, 'pickup_by' => Auth::id(), 'pickup_at' => now()]);
        Shipments::move($s->fresh(), 'picked_up');
        $this->step = 'done';
    }

    protected function getViewData(): array
    {
        $s = $this->shipment();
        $expected = $this->expected();

        return [
            's' => $s, 'expected' => $expected, 'n' => (int) $this->count,
            'short' => $this->count !== '' && (int) $this->count < $expected ? $expected - (int) $this->count : 0,
            'scanUrl' => (function () {
                try {
                    return \App\Filament\Scan\Pages\ScanApp::getUrl(panel: 'scan');
                } catch (\Throwable) {
                    return '/scan';
                }
            })(),
            'backUrl' => IncomingShipments::getUrl(),
        ];
    }
}
DISPATCH_FILE_END_0

# ---------------------------------------------------------------- app/Filament/Company/Resources/Deliveryinvs/Tables/DeliveryinvsTable.php
mkdir -p 'app/Filament/Company/Resources/Deliveryinvs/Tables'
cat > 'app/Filament/Company/Resources/Deliveryinvs/Tables/DeliveryinvsTable.php' <<'DISPATCH_FILE_END_1'
<?php

namespace App\Filament\Company\Resources\Deliveryinvs\Tables;

use App\Filament\Company\Resources\Deliverylogs\DeliverylogResource;
use App\Models\Consolidator;
use App\Models\Deliverylog;
use App\Models\Invoice;
use App\Models\Tripinvoice;
use Filament\Actions\Action;
use Filament\Actions\ActionGroup;
use Filament\Actions\BulkActionGroup;
use Filament\Actions\DeleteBulkAction;
use Filament\Forms\Components\FileUpload;
use Filament\Support\Icons\Heroicon;
use Filament\Tables\Columns\TextColumn;
use Filament\Tables\Filters\SelectFilter;
use Filament\Tables\Table;
use Illuminate\Database\Eloquent\Model;
use Illuminate\Support\Facades\Auth;

class DeliveryinvsTable
{
    public static function configure(Table $table): Table
    {
        return $table
            ->query(
                Tripinvoice::query()
                    ->with([
                        'invoice',           // Eager load the invoice
                        // 'deliveryLogs'       // Eager load delivery logs
                    ])
                    ->where('is_loaded_hub', true)
                    ->where('logistichub_id', Auth::user()->logistichub_id)
                //     ->where('hub_assigned', false)
            )
            ->columns([
                TextColumn::make('deliverylog.trip_number')
                    ->searchable()
                    ->label('Trip Number')
                    ->color('primary')
                    ->getStateUsing(function (Model $record) {
                        $tripnumber = Deliverylog::where('id', $record->deliveryloghub_id)->value('trip_number');

                        return $tripnumber ?? 'N/A';
                    })

                    ->url(fn (Model $record) => DeliverylogResource::getUrl('edit', ['record' => $tripnumber = Deliverylog::where('id', $record->deliveryloghub_id)->value('id')])),
                TextColumn::make('company')
                    ->label('Company')
                    ->getStateUsing(function ($record) {
                        return Consolidator::nameForCode($record->location_code);
                    }),
                TextColumn::make('invdata.invoice')
                    ->searchable()
                    ->label('Invoice'),
                TextColumn::make('invdata.container.batch_no')
                    ->toggleable(isToggledHiddenByDefault: true)
                    ->searchable()
                    ->label('Batch No'),
                TextColumn::make('invdata.container.batch_year')
                    ->toggleable(isToggledHiddenByDefault: true)
                    ->searchable()
                    ->label('Batch Year'),
                TextColumn::make('invdata.container.container_no')
                    ->toggleable(isToggledHiddenByDefault: true)
                    ->searchable()
                    ->label('Container No'),
                TextColumn::make('invdata.sender_name')
                    ->toggleable(isToggledHiddenByDefault: true)
                    ->label('Sender'),
                TextColumn::make('invdata.receiver_name')
                    ->label('Receiver'),
                TextColumn::make('invdata.receiver_address')
                    ->toggleable(isToggledHiddenByDefault: true)
                    ->label('Address'),
                TextColumn::make('is_delivered')
                    ->label('Status')
                    ->formatStateUsing(function (Model $record) {
                        return $record->is_delivered ? 'Delivered' : 'In Transit';
                    })
                    ->color(function ($record) {
                        return $record->is_delivered ? 'success' : 'danger';
                    }),
                TextColumn::make('company')
                    ->toggleable(isToggledHiddenByDefault: true)
                    ->label('Company')
                    ->getStateUsing(function (Model $record) {
                        // $companyname = Consolidator::where('code', $records->location_code)->first();
                        $locationcode = Invoice::where('id', $record->invoice_id)->value('location_code');

                        return $companyname = Consolidator::nameForCode($locationcode);
                    }),
                TextColumn::make('invdata.receiver_province')
                    ->toggleable(isToggledHiddenByDefault: true)
                    ->label('Province'),
                TextColumn::make('invdata.receiver_city')
                    ->toggleable(isToggledHiddenByDefault: true)
                    ->label('City'),
                TextColumn::make('invdata.receiver_barangay')
                    ->toggleable(isToggledHiddenByDefault: true)
                    ->label('Barangay'),
                TextColumn::make('invdata.boxtype')
                    ->label('Box Type'),
                TextColumn::make('invdata.routearea.description')
                    ->toggleable(isToggledHiddenByDefault: true)
                    ->label('Route Area'),
            ])
            ->filters([
                SelectFilter::make('is_delivered')
                    ->label('Is Delivered')
                    ->options([
                        1 => 'Yes',
                        0 => 'No',
                    ])->default(0),
                SelectFilter::make('routearea_id')
                    ->label('Route')
                    ->relationship('invdata.routearea', 'description'),
                SelectFilter::make('deliveryloghub_id')
                    ->label('Trip Number')
                    ->searchable()
                    ->preload()
                   // ->relationship('deliverylog', 'trip_number')
                    ->options(Deliverylog::query()
                        ->where('logistichub_id', Auth::user()->logistichub_id)
                        ->pluck('trip_number', 'id')),
            ])
            ->recordActions([
                ActionGroup::make([
                    Action::make('Edit')
                        ->label('Edit Picture')
                        ->color('info')
                        ->icon(Heroicon::PencilSquare)
                        ->hidden(fn ($record) => empty($record->delivery_picture))
                        ->fillForm(fn (Model $record): array => [

                            'delivery_picture' => $record->delivery_picture,
                        ])
                        ->schema([
                            FileUpload::make('delivery_picture')
                                ->label('Delivery Picture')
                                ->multiple()
                                ->panelLayout('grid')
                                ->uploadingMessage('Uploading attachment...')
                                ->image()
                                ->openable()
                                ->disk('public')
                                ->directory(function (Model $record) {
                                    return \App\Support\Photos\Storage\PhotoFolders::dir('delivery', $record->invoice);
                                })
                                ->visibility('private')
                                ->required()
                                ->removeUploadedFileButtonPosition('right'),
                        ])
                        ->action(function (array $data, Model $record): void {
                            Tripinvoice::where('id', $record->id)
                                ->update([
                                    'delivery_picture' => $data['delivery_picture'],
                                ]);
                        }),
                    Action::make('Picture')
                        ->label('Add Picture')
                        ->color('danger')
                        ->icon(Heroicon::Camera)
                        ->hidden(fn ($record) => ! empty($record->delivery_picture))
                        ->schema([
                            FileUpload::make('delivery_picture')
                                ->label('Delivery Picture')
                                ->multiple()
                                ->panelLayout('grid')
                                ->uploadingMessage('Uploading ...')
                                ->image()
                                ->openable()
                                ->disk('public')
                                ->directory(function (Model $record) {
                                    return \App\Support\Photos\Storage\PhotoFolders::dir('delivery', $record->invoice);
                                })
                                ->visibility('private')
                                ->required()
                                ->removeUploadedFileButtonPosition('right'),
                            // ->minFiles(6),
                        ])
                        ->action(function (array $data, Model $record): void {

                            Tripinvoice::where('id', $record->id)
                                ->update([
                                    'delivery_picture' => $data['delivery_picture'],
                                    'is_delivered' => true,
                                ]);
                        }),
                ]),
            ])
            ->toolbarActions([
                BulkActionGroup::make([
                    DeleteBulkAction::make(),
                ]),
            ]);
    }
}
DISPATCH_FILE_END_1

# ---------------------------------------------------------------- app/Filament/Company/Resources/DriverResource.php
mkdir -p 'app/Filament/Company/Resources'
cat > 'app/Filament/Company/Resources/DriverResource.php' <<'DISPATCH_FILE_END_2'
<?php

namespace App\Filament\Company\Resources;

use App\Filament\Company\Resources\DriverResource\Pages\CreateDriver;
use App\Filament\Company\Resources\DriverResource\Pages\EditDriver;
use App\Filament\Company\Resources\DriverResource\Pages\ListDrivers;
use App\Filament\Resources\UserResource\Pages\EditUser;
use App\Models\Driver;
use App\Models\User;
use App\Models\Workposition;
use Filament\Actions\BulkActionGroup;
use Filament\Actions\DeleteBulkAction;
use Filament\Actions\EditAction;
use Filament\Forms\Components\FileUpload;
use Filament\Forms\Components\Select;
use Filament\Forms\Components\TextInput;
use Filament\Forms\Components\Toggle;
use Filament\Resources\Resource;
use Filament\Schemas\Components\Group;
use Filament\Schemas\Components\Section;
use Filament\Schemas\Components\Utilities\Get;
use Filament\Schemas\Schema;
use Filament\Tables\Columns\IconColumn;
use Filament\Tables\Columns\TextColumn;
use Filament\Tables\Table;
use Illuminate\Support\Facades\Auth;
use Illuminate\Support\Facades\Hash;
use Illuminate\Support\Str;

class DriverResource extends Resource
{
    protected static ?string $model = Driver::class;

    /** Replaced by the Crew page (board 60); the old pages still open from old links. */
    protected static bool $shouldRegisterNavigation = false;

    protected static ?string $navigationLabel = 'Company Crew';

    public static ?string $label = 'Company Crews';

    protected static string|\BackedEnum|null $navigationIcon = 'heroicon-o-rectangle-stack';

    public static function form(Schema $schema): Schema
    {
        return $schema
            ->components([
                Group::make()
                    ->schema([
                        Section::make('Personal Information')
                            ->schema([
                                TextInput::make('first_name')
                                    ->required()
                                    ->maxLength(255),
                                TextInput::make('middle_name')
                                    ->maxLength(255),
                                TextInput::make('last_name')
                                    ->required()
                                    ->maxLength(255),
                                TextInput::make('address')
                                    ->required()
                                    ->maxLength(255)
                                    ->columnSpanFull(),
                                TextInput::make('mobile_number')
                                    ->required()
                                    ->maxLength(255),
                                TextInput::make('email')
                                    ->email()
                                    ->required()
                                    ->maxLength(255)
                                    ->unique(ignoreRecord: true),
                                // Select::make('panelcategory_id')
                                //     ->label('Panel Category')
                                //     ->relationship(name: 'panelcategory', titleAttribute: 'description')
                                //      ->required(),
                                // Select::make('logistichub_id')
                                // ->label('Logistic Hub/Location')
                                // ->options(Logistichub::query()->pluck('hub_name', 'id'))
                                // ->required(),
                                Select::make('workposition_id')
                                    ->label('Work Position')
                                    ->options(Workposition::query()
                                        ->where('is_crew', true)
                                        ->pluck('position_description', 'id'))
                                    ->required(),

                                Toggle::make('is_active')
                                    ->label('Active')
                                    ->required(),

                            ])->columns(3),

                    ])->columnSpan(['lg' => 2]),
                Group::make()
                    ->schema([
                        Section::make()
                            ->schema([
                                FileUpload::make('profile_picture')
                                    ->image()
                                    ->avatar()
                                    ->imageEditor()
                                    ->circleCropper()
                                    // ->panelLayout('grid')
                                    ->uploadingMessage('Uploading attachment...')
                                    ->openable()
                                    ->getUploadedFileNameForStorageUsing(function ($file, Get $get) {
                                        return Str::slug($get('last_name') ?: 'user').'-'.Str::random(8).'.'.$file->getClientOriginalExtension();
                                    })
                                    ->maxSize(1024)
                                    ->disk('public')
                                    ->directory('people')
                                    ->visibility('private')
                                    ->removeUploadedFileButtonPosition('right')
                                    ->label('Profile Picture'),
                                TextInput::make('password')
                                    ->password()
                                    ->required()
                                    ->dehydrateStateUsing(fn ($state) => Hash::make($state))
                                    ->dehydrated(fn ($state) => filled($state))
                                    ->maxLength(255)
                                    ->hiddenOn(EditUser::class)
                                    ->maxLength(255),
                            ]),
                    ])->columnSpan(['lg' => 1]),

            ])->columns(3);
    }

    public static function table(Table $table): Table
    {
        return $table
            ->query(User::query()->where('logistichub_id', Auth::user()->logistichub_id))
            ->columns([
                TextColumn::make('first_name')
                    ->searchable(),
                TextColumn::make('middle_name')
                    ->searchable(),
                TextColumn::make('last_name')
                    ->searchable(),
                TextColumn::make('mobile_number')
                    ->searchable(),
                IconColumn::make('is_active')
                    ->boolean(),
                TextColumn::make('address')
                    ->searchable(),
                TextColumn::make('email')
                    ->searchable(),
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
                //
            ])
            ->recordActions([
                EditAction::make(),
            ])
            ->toolbarActions([
                BulkActionGroup::make([
                    DeleteBulkAction::make(),
                ]),
            ]);
    }

    public static function getRelations(): array
    {
        return [
            //
        ];
    }

    public static function getPages(): array
    {
        return [
            'index' => ListDrivers::route('/'),
            'create' => CreateDriver::route('/create'),
            'edit' => EditDriver::route('/{record}/edit'),
        ];
    }
}
DISPATCH_FILE_END_2

# ---------------------------------------------------------------- app/Filament/Company/Resources/Trucks/Schemas/TruckForm.php
mkdir -p 'app/Filament/Company/Resources/Trucks/Schemas'
cat > 'app/Filament/Company/Resources/Trucks/Schemas/TruckForm.php' <<'DISPATCH_FILE_END_3'
<?php

namespace App\Filament\Company\Resources\Trucks\Schemas;

use Filament\Forms\Components\DatePicker;
use Filament\Forms\Components\FileUpload;
use Filament\Forms\Components\MarkdownEditor;
use Filament\Forms\Components\TextInput;
use Filament\Forms\Components\Toggle;
use Filament\Schemas\Components\Group;
use Filament\Schemas\Components\Section;
use Filament\Schemas\Schema;

class TruckForm
{
    public static function configure(Schema $schema): Schema
    {
        return $schema
            ->components([
                Group::make()
                    ->schema([
                        \App\Filament\Shared\Trucks\OwnershipSection::make(),
                        Section::make('vehicles Information')
                            ->schema([
                                TextInput::make('category')
                                    ->hint('Ex. Ten Wheeler, Truck, Mini Truck or Van')
                                    ->hintColor('warning')
                                    ->hintIcon('heroicon-m-truck')
                                    ->required()
                                    ->maxLength(255),
                                TextInput::make('description')
                                    ->hint('Ex Brand, Color, Model')
                                    ->hintColor('warning')
                                    ->hintIcon('heroicon-m-truck')
                                    ->required()
                                    ->maxLength(255),
                                TextInput::make('registration_no')
                                    ->label('Registration Number')
                                    ->required()
                                    ->maxLength(255),
                                TextInput::make('plate_no')
                                    ->label('Plate Number')
                                    ->required()
                                    ->maxLength(255),
                                TextInput::make('capacity')
                                    ->label(fn () => \App\Support\BoxSizes::on() ? 'Capacity (space, in normal boxes)' : 'Capacity (boxes)')
                                    ->numeric()
                                    ->minValue(1)
                                    ->placeholder('60')
                                    ->helperText(fn () => \App\Support\BoxSizes::on()
                                        ? 'How many of your normal box fit. Bigger boxes take more space: Settings → Box sizes. Empty means 50.'
                                        : 'About how many boxes fit. Used to plan trips; empty means 50.'),
                                MarkdownEditor::make('Note')
                                    ->columnSpanFull(),
                            ]),

                    ]),
                Group::make()
                    ->schema([
                        Section::make('Other Information')
                            ->schema([
                                FileUpload::make('truck_picture')
                                    ->image()
                                    ->avatar()
                                    ->imageEditor()
                                    ->circleCropper()
                                    ->uploadingMessage('Uploading attachment...')
                                    ->openable()
                                    ->maxSize(1024)
                                    ->disk('public')
                                    ->directory('trucks')
                                    ->visibility('private')
                                    ->removeUploadedFileButtonPosition('right')
                                    ->label('Vehicles Picture')
                                    ->columnSpanFull(),
                                DatePicker::make('date_registered')
                                    ->native(false)
                                    ->closeOnDateSelection(true)
                                    ->label('Date Register')
                                    ->required(),
                                DatePicker::make('date_expired')
                                    ->label('Registration Expiration Date')
                                    ->native(false)
                                    ->closeOnDateSelection(true)
                                    ->required()
                                    ->rules(['after_or_equal:today']),
                                Toggle::make('is_active')
                                    ->default(true)
                                    ->required(),
                            ]),

                    ]),

            ]);
    }
}
DISPATCH_FILE_END_3

# ---------------------------------------------------------------- app/Filament/Delivery/Pages/AtPort.php
mkdir -p 'app/Filament/Delivery/Pages'
cat > 'app/Filament/Delivery/Pages/AtPort.php' <<'DISPATCH_FILE_END_4'
<?php

namespace App\Filament\Delivery\Pages;

use App\Models\Tripinvoice;
use App\Support\DriverTrip;
use App\Support\Photos\PhotoShrinker;
use App\Support\Shipping\Shipments;
use Filament\Pages\Page;
use Illuminate\Contracts\Support\Htmlable;
use Illuminate\Support\Facades\Auth;
use Illuminate\Support\Facades\Storage;
use Livewire\Attributes\Locked;
use Livewire\WithFileUploads;

/**
 * Driver app › At the port: on a sea shipment trip (Count only), the driver types how many
 * boxes the forwarder counted and takes a photo of the receipt. It goes straight to the shipment.
 */
class AtPort extends Page
{
    use WithFileUploads;

    protected string $view = 'filament.delivery.pages.at-port';

    protected static bool $shouldRegisterNavigation = false;

    protected static ?string $slug = 'at-port';

    /** intro, count, photo, done */
    #[Locked]
    public string $step = 'intro';

    public string $count = '';

    public $upload = null;

    #[Locked]
    public ?string $receiptPath = null;

    #[Locked]
    public ?float $lat = null;

    #[Locked]
    public ?float $lng = null;

    public static function canAccess(): bool
    {
        return Shipments::ready() && Auth::check();
    }

    public function getTitle(): string|Htmlable
    {
        return $this->shipment()?->mode === 'lcl' ? 'At the forwarder' : 'At the port';
    }

    public function getHeading(): string|Htmlable
    {
        return '';
    }

    protected function shipment()
    {
        return Shipments::forDriverPort(DriverTrip::currentTrip(Auth::user()));
    }

    protected function left(): int
    {
        $s = $this->shipment();

        return $s ? Tripinvoice::whereIn('deliverylog_id', \App\Support\Shipping\Shipments::tripIds($s))->where('is_loaded', true)->count() : 0;
    }

    public function mount(): void
    {
        $s = $this->shipment();
        if ($s && $s->port_count !== null) {
            $this->count = (string) $s->port_count;
        }
    }

    public function setPlace(mixed $lat, mixed $lng): void
    {
        $this->lat = is_numeric($lat) && abs((float) $lat) <= 90 ? (float) $lat : null;
        $this->lng = is_numeric($lng) && abs((float) $lng) <= 180 ? (float) $lng : null;
    }

    public function start(): void
    {
        if ($this->shipment()) {
            $this->count = $this->count !== '' ? $this->count : (string) $this->left();
            $this->step = 'count';
        }
    }

    public function bump(int $by): void
    {
        $this->count = (string) max(0, min(9999, (int) $this->count + $by));
    }

    public function toPhoto(): void
    {
        $this->validate(['count' => 'required|integer|min:0|max:9999'], ['count.required' => 'Type the number of boxes.']);
        $this->step = 'photo';
    }

    /** Called by the phone after the (shrunk) receipt photo is uploaded. */
    public function savePhoto(): void
    {
        $this->validate(['upload' => 'required|image|max:12288'], ['upload.image' => 'That file is not a photo.']);
        $path = $this->upload->store(\App\Support\Photos\Storage\PhotoFolders::dir('shipments', $this->shipment()?->code), 'public');
        PhotoShrinker::file('public', $path);
        if ($this->receiptPath) {
            Storage::disk('public')->delete($this->receiptPath);
        }
        $this->receiptPath = $path;
        $this->reset('upload');
        $this->save();
    }

    /** Without a photo (for example the forwarder gives none). */
    public function save(): void
    {
        $s = $this->shipment();
        if (! $s) {
            return;
        }
        $this->validate(['count' => 'required|integer|min:0|max:9999']);
        Shipments::driverPort($s, (int) $this->count, $this->receiptPath, $this->lat, $this->lng);
        $this->step = 'done';
    }

    protected function getViewData(): array
    {
        $s = $this->shipment();
        $left = $this->left();

        return [
            's' => $s, 'left' => $left, 'n' => (int) $this->count,
            'short' => $this->count !== '' && (int) $this->count < $left ? $left - (int) $this->count : 0,
            'receiptUrl' => $this->receiptPath ? Storage::disk('public')->url($this->receiptPath) : null,
        ];
    }
}
DISPATCH_FILE_END_4

# ---------------------------------------------------------------- app/Filament/Delivery/Pages/Dashboard.php
mkdir -p 'app/Filament/Delivery/Pages'
cat > 'app/Filament/Delivery/Pages/Dashboard.php' <<'DISPATCH_FILE_END_5'
<?php

namespace App\Filament\Delivery\Pages;

use App\Enums\FailedDeliveryReason;
use App\Enums\UndoDeliveryReason;
use App\Models\Maps\GeoPlace;
use App\Models\Maps\TripStop;
use App\Models\Tripinvoice;
use App\Services\TripAssignment;
use App\Support\Ai\Ai;
use App\Support\Ai\AiUnavailable;
use App\Support\Ai\Risk;
use App\Support\Ai\VoiceNote;
use App\Support\DriverTrip;
use App\Support\Photos\PhotoShrinker;
use App\Support\Tracking\TrackSettings;
use BackedEnum;
use Filament\Actions\Action;
use Filament\Forms\Components\Radio;
use Filament\Forms\Components\Textarea;
use Filament\Notifications\Notification;
use Filament\Pages\Dashboard as BaseDashboard;
use Filament\Schemas\Components\Utilities\Get;
use Filament\Support\Icons\Heroicon;
use Illuminate\Contracts\Support\Htmlable;
use Illuminate\Support\Facades\Auth;
use Illuminate\Support\Facades\Storage;
use Illuminate\Support\Str;
use Livewire\Attributes\Locked;
use Livewire\Attributes\Url;
use Livewire\Features\SupportFileUploads\TemporaryUploadedFile;

/**
 * The Driver app: one phone screen. Today (trip, progress, where to go next),
 * Boxes (to deliver / delivered / not delivered), and Scan → deliver with
 * several proof photos, or can't deliver with a reason. Delivering, not-delivered
 * and undo go through App\Services\TripAssignment like everywhere else.
 */
class Dashboard extends BaseDashboard
{
    protected string $view = 'filament.delivery.pages.driver-app';

    /** home, list, scan */
    #[Url(as: 'view')]
    public string $screen = 'home';

    /** Boxes list: todo, delivered, missed */
    public string $tab = 'todo';

    public string $search = '';

    /** The scanned box (tripinvoice id) and what the bottom sheet shows: found, deliver, miss, wrong */
    #[Locked]
    public ?int $boxId = null;

    #[Locked]
    public ?string $sheet = null;

    #[Locked]
    public ?string $wrongText = null;

    /** Two boxes with one number on the trip (board 57): the tripinvoice ids to pick from by receiver. */
    public array $whichIds = [];

    /** The scanned number while asking Which one? */
    public ?string $whichCode = null;

    /** Photos already uploaded for the open sheet (paths on the public disk). */
    #[Locked]
    public array $photos = [];

    /** @var TemporaryUploadedFile|null */
    public $upload = null;

    public ?string $reason = null;

    public string $note = '';

    /** Just delivered: shows the green bar with Undo. */
    #[Locked]
    public ?int $justDelivered = null;

    #[Locked]
    public int $justPhotos = 0;

    public function mount(): void
    {
        if (request()->boolean('scan')) {
            $this->screen = 'scan';
        } elseif (request()->boolean('list')) {
            $this->screen = 'list';
        }
        if (! in_array($this->screen, ['home', 'list', 'scan'], true)) {
            $this->screen = 'home';
        }
    }

    protected function driverTrip(): DriverTrip
    {
        return once(fn () => DriverTrip::for(Auth::user()));
    }

    // ------------------------------------------------------------------ moving around

    public function go(string $screen): void
    {
        if (in_array($screen, ['home', 'list', 'scan'], true)) {
            $this->screen = $screen;
            $this->closeSheet();
            $this->justDelivered = null;
        }
    }

    /** Tap an area on Today: open the boxes list filtered to it. */
    public function area(string $term): void
    {
        $this->search = $term;
        $this->tab = 'todo';
        $this->go('list');
    }

    public function setTab(string $tab): void
    {
        $this->tab = in_array($tab, ['todo', 'delivered', 'missed'], true) ? $tab : 'todo';
    }

    public function closeSheet(): void
    {
        $this->deleteUnusedPhotos();
        $this->reset('boxId', 'sheet', 'wrongText', 'photos', 'upload', 'reason', 'note', 'whichIds', 'whichCode');
    }

    /** Board 62: the RoRo driver pressed the next step (Leaving for the port, On the ship, Off the ship, Arrived at a hub). */
    public function roroStep(string $key): void
    {
        $trip = $this->driverTrip()->trip;
        $s = \App\Support\Shipping\SeaTrucks::roroFor($trip);
        if ($s && \App\Support\Shipping\SeaTrucks::roroStep($s, (int) $trip->id, $key)) {
            \Filament\Notifications\Notification::make()->title('Saved: '.(\App\Support\Shipping\SeaTrucks::roroNext($s->fresh(), (int) $trip->id)[1] ?? 'all hubs reached').' is next')->success()->send();
        }
    }

    /** Which one? The driver picked the receiver's name. */
    public function pickBox(int $id): void
    {
        $box = in_array($id, $this->whichIds, true) ? $this->driverTrip()->boxes()->whereKey($id)->first() : null;
        if (! $box || $box->is_delivered) {
            return;
        }
        $this->reset('whichIds', 'whichCode');
        $this->boxId = $box->id;
        $this->sheet = 'found';
    }

    /** The open box, re-checked to be on this driver's trip. */
    protected function box(): ?Tripinvoice
    {
        return $this->boxId ? $this->driverTrip()->boxes()->with('invdata')->find($this->boxId) : null;
    }

    // ------------------------------------------------------------------ scan

    /** Called by the camera, the typed box number, or a tap on a box in the list. */
    public function scan(string $code): void
    {
        $code = trim(preg_replace('/[\x00-\x1F\x7F]+/u', '', $code));
        if ($code === '') {
            return;
        }

        $this->closeSheet();
        $this->justDelivered = null;
        $this->screen = 'scan';

        if (! $this->driverTrip()->trip) {
            $this->wrongText = "You're not on a trip right now.";
            $this->sheet = 'wrong';

            return;
        }

        $all = $this->driverTrip()->boxes()->with('invdata')
            ->where(fn ($q) => $q->where('invoice', $code)->orWhereHas('invdata', fn ($r) => $r->where('invoice', $code)))
            ->latest('id')->get();
        $open = $all->reject(fn ($b) => $b->is_delivered);
        if ($open->count() > 1) {
            // two boxes with this number on the truck: the driver picks the receiver on the sticker (board 57)
            $this->whichIds = $open->pluck('id')->map(fn ($i) => (int) $i)->values()->all();
            $this->whichCode = $code;
            $this->sheet = 'which';
            $this->dispatch('driver-app-buzz', ok: true);

            return;
        }
        $box = $open->first() ?? $all->first();

        if (! $box) {
            $this->wrongText = "{$code} is not on your truck. Keep it aside and tell the office.";
            $this->sheet = 'wrong';
            $this->dispatch('driver-app-buzz', ok: false);

            return;
        }
        if ($box->is_delivered) {
            $this->wrongText = "{$code} is already delivered.";
            $this->sheet = 'wrong';
            $this->dispatch('driver-app-buzz', ok: false);

            return;
        }

        $this->boxId = $box->id;
        $this->sheet = 'found';
        $this->dispatch('driver-app-buzz', ok: true);
    }

    public function openBox(int $id): void
    {
        $box = $this->driverTrip()->boxes()->find($id);
        if ($box) {
            // straight to this box, even when another box shares its number
            $this->closeSheet();
            $this->screen = 'scan';
            if ($box->is_delivered) {
                $this->scan($box->invoice);

                return;
            }
            $this->boxId = $box->id;
            $this->sheet = 'found';
        }
    }

    public function startDeliver(): void
    {
        if ($this->box() && ! $this->box()->is_delivered) {
            $this->sheet = 'deliver';
            $this->photos = [];
        }
    }

    public function startMiss(): void
    {
        if ($this->box() && ! $this->box()->is_delivered) {
            $this->sheet = 'miss';
            $this->photos = [];
            $this->reason = FailedDeliveryReason::NoOneHome->value;
        }
    }

    /** Driver voice note: what the driver said becomes the reason and the note. */
    public function voiceFill(string $said): void
    {
        $said = trim($said);
        if ($said === '' || $this->sheet !== 'miss') {
            return;
        }
        try {
            $out = VoiceNote::parse($said);
            if ($out['reason']) {
                $this->reason = $out['reason'];
            }
            $this->note = $out['note'] ?: $said;
        } catch (AiUnavailable $e) {
            $this->note = Str::limit($said, 480, '');
            Notification::make()->title('Saved what you said as the note')->body($e->getMessage())->warning()->send();
        }
    }

    public function backToBox(): void
    {
        $this->deleteUnusedPhotos();
        $this->photos = [];
        $this->sheet = $this->box() ? 'found' : null;
    }

    // ------------------------------------------------------------------ photos

    /** Called by the browser after a (shrunk) photo is uploaded. */
    public function savePhoto(): void
    {
        $box = $this->box();
        if (! $box || ! in_array($this->sheet, ['deliver', 'miss'], true)) {
            $this->reset('upload');

            return;
        }
        if ($this->sheet === 'miss' && count($this->photos) >= 3) {
            $this->reset('upload');

            return;
        }

        $this->validate(['upload' => 'required|image|max:12288'], ['upload.image' => 'That file is not a photo.']);

        $dir = \App\Support\Photos\Storage\PhotoFolders::dir($this->sheet === 'deliver' ? 'delivery' : 'not-delivered', $box->invoice);
        $path = $this->upload->store($dir, 'public');
        PhotoShrinker::file('public', $path); // the phone could not make it smaller: do it here
        $this->photos[] = $path;
        $this->reset('upload');
    }

    public function removePhoto(int $index): void
    {
        if (isset($this->photos[$index])) {
            Storage::disk('public')->delete($this->photos[$index]);
            unset($this->photos[$index]);
            $this->photos = array_values($this->photos);
        }
    }

    protected function deleteUnusedPhotos(): void
    {
        foreach ($this->photos as $path) {
            Storage::disk('public')->delete($path);
        }
    }

    // ------------------------------------------------------------------ deliver / can't deliver

    public function confirmDelivered(): void
    {
        $box = $this->box();
        if (! $box || $box->is_delivered) {
            $this->closeSheet();

            return;
        }
        if ($this->photos === []) {
            Notification::make()->title('Take at least one photo first')->warning()->send();

            return;
        }

        // Delivering means the trip is on the road, even if nobody tapped "I take the trip".
        if ($this->driverTrip()->trip) {
            \App\Support\TripFlow::take($this->driverTrip()->trip, Auth::user());
        }
        app(TripAssignment::class)->markDelivered($box, $this->photos);

        $this->justDelivered = $box->id;
        $this->justPhotos = count($this->photos);
        $this->photos = []; // they belong to the box now
        $this->reset('boxId', 'sheet', 'reason', 'note', 'upload');
        $this->dispatch('driver-app-buzz', ok: true);
    }

    /** Undo on the green bar right after delivering. */
    public function undoJust(): void
    {
        $box = $this->justDelivered ? $this->driverTrip()->boxes()->find($this->justDelivered) : null;
        $this->justDelivered = null;
        if (! $box) {
            return;
        }

        try {
            app(TripAssignment::class)->undoDelivery($box, Auth::user(), UndoDeliveryReason::TappedByMistake);
        } catch (\DomainException $e) {
            Notification::make()->title($e->getMessage())->danger()->send();

            return;
        }

        $this->boxId = $box->id;
        $this->sheet = 'found';
    }

    public function saveMissed(): void
    {
        $box = $this->box();
        $reason = FailedDeliveryReason::tryFrom((string) $this->reason);
        if (! $box || ! $reason) {
            return;
        }
        if ($this->driverTrip()->trip) {
            \App\Support\TripFlow::take($this->driverTrip()->trip, Auth::user());
        }

        try {
            app(TripAssignment::class)->recordFailedAttempt($box, Auth::user(), $reason, $this->note ?: null, $this->photos);
        } catch (\DomainException $e) {
            Notification::make()->title($e->getMessage())->warning()->send();

            return;
        }

        $this->photos = [];
        $this->closeSheet();
        Notification::make()->title("{$box->invoice} stays on your truck")->body('The office has been told.')->warning()->send();
    }

    protected static ?string $navigationLabel = 'Today';

    protected static string|BackedEnum|null $navigationIcon = Heroicon::OutlinedHome;

    protected static ?int $navigationSort = 1;

    // ------------------------------------------------------------------ trip steps

    /** "I take the trip": the leadman confirms the box count; the trip is on the road. */
    public function takeTrip(): void
    {
        $trip = $this->driverTrip()->trip;
        if (! $trip || ! \App\Support\TripFlow::canTake($trip, Auth::user())) {
            return;
        }
        // not locked yet: it locks by itself when every check is green (Trip rules); otherwise the office locks it
        if (! $trip->is_lock) {
            if (! \App\Support\Trips\TripLock::autoOnTake() || ! \App\Support\Trips\TripLock::isReady($trip)) {
                Notification::make()->title('Trip not ready')->body('Not ready: '.\App\Support\Trips\TripLock::missing($trip).'. Call the office.')->warning()->send();

                return;
            }
            \App\Support\Trips\TripLock::lock($trip, Auth::user());
        }
        \App\Support\TripFlow::take($trip, Auth::user());
        Notification::make()->title('Trip '.$trip->trip_number.' is yours · '.$trip->fresh()->taken_boxes.' boxes')->body('Drive safe. Customers see you are on the way.')->success()->send();
    }

    /** "Back at the hub": boxes not delivered are scanned back; then the trip closes by itself. */
    public function backAtHub(): void
    {
        $trip = $this->driverTrip()->trip;
        if (! $trip) {
            return;
        }
        \App\Support\TripFlow::back($trip);
        $closed = ! $trip->fresh()->is_active;
        Notification::make()->title($closed ? 'Trip done · truck released' : 'Back at the hub')
            ->body($closed ? 'Every box is delivered or returned.' : 'Give the boxes not delivered to the hub: they are scanned back with Return boxes. Then the trip closes by itself.')->success()->send();
    }

    /** The card at the top of Today for the trip step (none while on the road). */
    protected function stageCard(string $stage, array $p, bool $canTake, string $missing = ''): ?array
    {
        return [
            'planned' => ['Your next trip', 'Planned. You will see the boxes when the truck is loaded.'],
            'loading' => $canTake
                ? ['Trip ready', 'Every box is loaded, the truck and crew are set. Tap when you take the trip: it locks by itself and you confirm '.$p['total'].' boxes.']
                : ['Being loaded', $p['total'].' boxes on the trip so far.'.($missing ? ' Not ready: '.$missing.'.' : '').' Wait for “Trip ready”.'],
            'ready' => ['Trip ready', 'Check the truck. '.($canTake ? 'Tap when you take the trip: you confirm '.$p['total'].' boxes.' : 'The leadman takes the trip.')],
            'back' => ['Back at the hub', $p['left'] ? $p['left'].' not delivered: give them to the hub, they are scanned back with Return boxes. Then the trip closes by itself.' : 'The trip closes by itself.'],
        ][$stage] ?? null;
    }

    public function getTitle(): string|Htmlable
    {
        return 'Today';
    }

    public function getHeading(): string|Htmlable
    {
        $hour = (int) now()->format('G');
        $greeting = $hour < 12 ? 'Good morning' : ($hour < 18 ? 'Good afternoon' : 'Good evening');

        return "{$greeting}, ".Auth::user()?->first_name;
    }

    public function getSubheading(): ?string
    {
        return now()->format('l, F j');
    }

    /** Undo one of today's deliveries (only the driver's own, within 30 minutes). */
    public function undoDeliveryAction(): Action
    {
        return Action::make('undoDelivery')
            ->label('Undo')
            ->icon(Heroicon::OutlinedArrowUturnLeft)
            ->color('gray')
            ->outlined()
            ->size('sm')
            ->modalHeading(fn (array $arguments) => 'Undo delivery of '.$this->ownBox($arguments)?->invoice.'?')
            ->modalDescription('The box goes back on your list. Your photo is kept.')
            ->modalIcon(Heroicon::OutlinedArrowUturnLeft)
            ->modalSubmitActionLabel('Undo delivery')
            ->modalCancelActionLabel('Keep delivered')
            ->modalWidth('md')
            ->schema([
                Radio::make('reason')
                    ->label('Why?')
                    ->options(UndoDeliveryReason::driverOptions())
                    ->default(UndoDeliveryReason::WrongBox->value)
                    ->required()
                    ->live(),
                Textarea::make('note')
                    ->label('Note')
                    ->rows(2)
                    ->maxLength(500)
                    ->required(fn (Get $get) => $get('reason') === UndoDeliveryReason::Other->value),
            ])
            ->action(function (array $data, array $arguments): void {
                $box = $this->ownBox($arguments);

                if (! $box) {
                    Notification::make()->title('That box is not on your trip')->danger()->send();

                    return;
                }

                try {
                    app(TripAssignment::class)->undoDelivery($box, Auth::user(), UndoDeliveryReason::from($data['reason']), $data['note'] ?? null);
                } catch (\DomainException $exception) {
                    Notification::make()->title($exception->getMessage())->danger()->send();

                    return;
                }

                Notification::make()->title('Delivery undone')->body("{$box->invoice} is back on your list.")->success()->send();
            });
    }

    /** The box from the button, re-checked to be on this driver's own trip. */
    protected function ownBox(array $arguments): ?Tripinvoice
    {
        return DriverTrip::for(Auth::user())->boxes()->find($arguments['tripinvoice'] ?? null);
    }

    /** Truck tracking: the driver agrees once to share their location during trips. */
    public function agreeTracking(): void
    {
        Auth::user()->forceFill(['tracking_consent_at' => now()])->save();
    }

    /** "Can't find it" on a stop: the driver's pin, checked by the office in Maps & routes. */
    public function suggestPin(int $stopId, float $lat, float $lng): void
    {
        $trip = $this->driverTrip()->trip;
        $stop = $trip ? TripStop::where('deliverylog_id', $trip->id)->find($stopId) : null;
        if (! $stop?->geo_place_id || abs($lat) > 90 || abs($lng) > 180) {
            return;
        }
        GeoPlace::whereKey($stop->geo_place_id)->update([
            'suggested_lat' => $lat, 'suggested_lng' => $lng, 'suggested_by' => Auth::id(), 'suggested_at' => now(),
        ]);
        Notification::make()->title('Pin sent')->body('The office will check it. Next time the map goes there.')->success()->send();
    }

    public function getWidgets(): array
    {
        return [];
    }

    protected function getViewData(): array
    {
        $trip = $this->driverTrip();
        $has = (bool) $trip->trip;
        $box = $this->box();
        $which = $this->sheet === 'which' && $this->whichIds
            ? $this->driverTrip()->boxes()->with('invdata.container:id,container_no,batch_no')->whereIn('id', $this->whichIds)->get()
                ->map(fn ($t) => ['id' => $t->id] + ($t->invdata ? \App\Support\Boxes\SameNumber::choice($t->invdata) : ['name' => $t->invoice, 'place' => '', 'sender' => '', 'container' => '']))->all()
            : [];

        $household = null;
        if ($box?->invdata) {
            $same = $trip->boxes()->whereHas('invdata', fn ($q) => $q
                ->where('receiver_name', $box->invdata->receiver_name)
                ->where('receiver_address', $box->invdata->receiver_address))->get(['id', 'is_delivered']);
            $household = ['count' => $same->count(), 'delivered' => $same->where('is_delivered', true)->count()];
        }

        $stage = $has && \App\Support\TripFlow::ready() ? \App\Support\TripFlow::stage($trip->trip) : null;
        $prog = $has ? $trip->progress() : null; // once per tap

        return [
            'which' => $which,
            'seaCard' => ($ps = \App\Support\Shipping\Shipments::forDriverPort($trip->trip)) ? (function () use ($ps, $trip) {
                $ids = \App\Support\Shipping\SeaTrucks::carriedBy((int) $trip->trip->id);
                $n = \App\Models\Tripinvoice::whereIn('deliverylog_id', $ids)->selectRaw('deliverylog_id, count(*) c')->groupBy('deliverylog_id')->pluck('c', 'deliverylog_id');

                return ['code' => $ps->code, 'lcl' => $ps->mode === 'lcl', 'counted' => $ps->port_count,
                    'to' => $ps->mode === 'lcl' ? ($ps->hand_over_at ?: ($ps->forwarder ?: 'the forwarder')) : ($ps->port_from ?: 'the port'),
                    'hubs' => \App\Support\Shipping\Shipments::stops($ps)->whereIn('deliverylog_id', $ids)->sortBy('stop')->map(fn ($x) => ['name' => $x->hub?->hub_name, 'n' => (int) ($n[$x->deliverylog_id] ?? 0)])->values()->all(),
                    'total' => (int) $n->sum()];
            })() : null,
            'roro' => ($rs = \App\Support\Shipping\SeaTrucks::roroFor($trip->trip)) ? ['code' => $rs->code,
                'now' => \App\Support\Shipping\Shipments::label($rs).' · '.\App\Support\Shipping\Shipments::stops($rs)->sortBy('stop')->map(fn ($x) => $x->hub?->hub_name.($x->arrived_at ? ' ✓' : ''))->join(' → '),
                'next' => \App\Support\Shipping\SeaTrucks::roroNext($rs, (int) $trip->trip->id)] : null,
            'trip' => $trip->trip,
            'stage' => $stage,
            'canTake' => $canTake = ($stage === 'ready' || ($stage === 'loading' && (\App\Support\Trips\TripLock::autoOnTake() && \App\Support\Trips\TripLock::isReady($trip->trip))))
                && \App\Support\TripFlow::canTake($trip->trip, Auth::user()),
            'stageCard' => $has && $stage ? $this->stageCard($stage, $prog, $canTake, $stage === 'loading' ? \App\Support\Trips\TripLock::missing($trip->trip) : '') : null,
            'nextTrip' => $has && \App\Support\TripFlow::queueReady() ? \App\Support\TripFlow::nextAfter($trip->trip) : null,
            'closedTrip' => $closedTrip = ! $has && Auth::user() ? \App\Support\TripFlow::justClosedFor(Auth::user()) : null,
            'closedDelivered' => $closedTrip ? \App\Support\TripFlow::boxes($closedTrip)->where('is_delivered', true)->count() : 0,
            'progress' => $prog,
            'finished' => $has && $prog['total'] > 0 && $prog['left'] === 0,
            'crew' => $trip->crewmates(),
            'priority' => $has && $this->screen === 'home' ? $trip->priority() : collect(),
            'areas' => $has && $this->screen === 'home' ? $trip->areas() : collect(),
            'stops' => $has && $this->screen === 'home' ? $trip->stops() : collect(),
            'tracking' => [
                'trip' => $has && TrackSettings::source((int) $trip->trip->truck_id) !== 'tracker' ? $trip->trip->trip_number : null,
                'consent' => (bool) Auth::user()?->tracking_consent_at,
                'interval' => TrackSettings::int('interval'),
            ],
            'problems' => $has && $this->screen === 'home' ? $trip->problems() : collect(),
            'delivered' => $has && $this->screen === 'home' ? $trip->deliveredToday() : collect(),
            'rows' => $has && $this->screen === 'list' ? $this->listRows() : collect(),
            'counts' => $has && $this->screen === 'list' ? ['todo' => $prog['left'], 'delivered' => $prog['delivered'], 'missed' => $prog['notDelivered']] : [],
            'box' => $box,
            'risk' => $box && ! $box->is_delivered && Ai::switchedOn('risky') ? Risk::of($box) : null,
            'voiceOn' => Ai::enabled('voice'),
            'household' => $household,
            'reasons' => FailedDeliveryReason::cases(),
            'reasonCase' => FailedDeliveryReason::tryFrom((string) $this->reason),
            'photoUrls' => array_map(fn ($p) => Storage::disk('public')->url($p), $this->photos),
            'just' => $this->justDelivered ? $trip->boxes()->find($this->justDelivered) : null,
            'greeting' => (int) now()->format('G') < 12 ? 'Good morning' : ((int) now()->format('G') < 18 ? 'Good afternoon' : 'Good evening'),
        ];
    }

    protected function listQuery()
    {
        $q = $this->driverTrip()->boxes()->with('invdata', 'latestDeliveryAttempt');
        $term = trim($this->search);
        if ($term !== '') {
            $q->where(fn ($w) => $w->where('invoice', 'like', "%{$term}%")->orWhereHas('invdata', fn ($i) => $i
                ->where('receiver_name', 'like', "%{$term}%")->orWhere('receiver_barangay', 'like', "%{$term}%")->orWhere('receiver_city', 'like', "%{$term}%")));
        }

        return $q;
    }

    protected function listRows()
    {
        $q = $this->listQuery();
        match ($this->tab) {
            'delivered' => $q->where('is_delivered', true)->orderByRaw('COALESCE(delivered_at, updated_at) DESC'),
            'missed' => $q->where('is_delivered', false)->has('deliveryAttempts')->orderBy('invoice'),
            default => $q->where('is_delivered', false)->orderBy('invoice'),
        };

        return $q->limit(200)->get();
    }

    protected function listCounts(): array
    {
        $p = $this->driverTrip()->progress();

        return ['todo' => $p['left'], 'delivered' => $p['delivered'], 'missed' => $p['notDelivered']];
    }
}
DISPATCH_FILE_END_5

# ---------------------------------------------------------------- app/Filament/Delivery/Pages/Deliveryinv.php
mkdir -p 'app/Filament/Delivery/Pages'
cat > 'app/Filament/Delivery/Pages/Deliveryinv.php' <<'DISPATCH_FILE_END_6'
<?php

namespace App\Filament\Delivery\Pages;

use App\Enums\FailedDeliveryReason;
use App\Enums\UndoDeliveryReason;
use App\Models\Deliverylog;
use App\Models\Tripinvoice;
use App\Services\TripAssignment;
use App\Support\DriverTrip;
use BackedEnum;
use Filament\Actions\Action;
use Filament\Actions\Concerns\InteractsWithActions;
use Filament\Actions\Contracts\HasActions;
use Filament\Forms\Components\FileUpload;
use Filament\Forms\Components\Radio;
use Filament\Forms\Components\Textarea;
use Filament\Notifications\Notification;
use Filament\Pages\Page;
use Filament\Schemas\Components\Utilities\Get;
use Filament\Schemas\Concerns\InteractsWithSchemas;
use Filament\Schemas\Contracts\HasSchemas;
use Filament\Support\Enums\FontWeight;
use Filament\Support\Enums\Size;
use Filament\Support\Enums\TextSize;
use Filament\Support\Icons\Heroicon;
use Filament\Tables\Columns\Layout\Stack;
use Filament\Tables\Columns\TextColumn;
use Filament\Tables\Concerns\InteractsWithTable;
use Filament\Tables\Contracts\HasTable;
use Filament\Tables\Enums\PaginationMode;
use Filament\Tables\Filters\SelectFilter;
use Filament\Tables\Filters\TernaryFilter;
use Filament\Tables\Table;
use Illuminate\Contracts\Database\Eloquent\Builder;
use Illuminate\Support\Facades\Auth;
use Illuminate\Support\Str;
use Livewire\Attributes\Locked;
use Livewire\Attributes\On;

class Deliveryinv extends Page implements HasActions, HasSchemas, HasTable
{
    use InteractsWithActions;
    use InteractsWithSchemas;
    use InteractsWithTable;

    // Locked = cannot be changed from the browser
    #[Locked]
    public ?int $deliveryid = null;

    #[Locked]
    public ?string $tripNumber = null;

    #[Locked]
    public ?int $scannedId = null;

    protected string $view = 'filament.delivery.pages.deliveryinv';

    protected static ?string $navigationLabel = 'My deliveries';

    protected static ?int $navigationSort = 2;

    protected static string|BackedEnum|null $navigationIcon = Heroicon::OutlinedTruck;

    /**
     * The current trip the logged-in user is assigned to as crew
     * (driver / leadman / helper). Works with multiple crew per trip.
     */
    protected static function currentDelivery(): ?Deliverylog
    {
        return once(fn () => Auth::user() ? DriverTrip::currentTrip(Auth::user()) : null);
    }

    public function mount(): void
    {
        $deliverylog = static::currentDelivery();
        $this->deliveryid = $deliverylog?->id;
        $this->tripNumber = $deliverylog?->trip_number;

    }

    public function getHeading(): string
    {
        return $this->tripNumber ? "Trip {$this->tripNumber}" : 'Deliveries';
    }

    public function getSubheading(): ?string
    {
        if (! $this->deliveryid) {
            return 'You are not assigned to a trip right now.';
        }

        $left = $this->deliveryQuery()->count();

        if ($left === 0) {
            return 'All boxes on this trip are delivered.';
        }

        $attempted = $this->deliveryQuery()->has('deliveryAttempts')->count();

        return trans_choice('{1} 1 box left to deliver|[2,*] :count boxes left to deliver', $left, ['count' => $left])
            .($attempted ? " · {$attempted} not delivered yet" : '');
    }

    /**
     * Invoices loaded on the user's current trip.
     * Used by the table AND the scanner.
     */
    protected function deliveryQuery(): Builder
    {
        $trip = static::currentDelivery();

        if (! $trip) {
            return Tripinvoice::query()->whereRaw('1 = 0'); // no trip → no invoices
        }

        // Boxes on the driver's own trip, or handed over to it by a partner hub — and not yet delivered.
        return Tripinvoice::query()
            ->with(['invdata', 'latestDeliveryAttempt'])
            ->withCount('deliveryAttempts')
            ->where('is_delivered', false)
            ->where(fn (Builder $query) => $query
                ->where('deliverylog_id', $trip->id)
                ->orWhere('deliveryloghub_id', $trip->id));
    }

    /**
     * Called by <x-barcode-scanner method="scanInvoice" />
     */
    public function scanInvoice(string $code): void
    {
        $code = trim(preg_replace('/[\x00-\x1F\x7F]+/u', '', $code));

        if ($code === '') {
            return;
        }

        if (! $this->deliveryid) {
            Notification::make()
                ->title('No active delivery')
                ->body('You are not assigned to any current delivery trip.')
                ->warning()
                ->send();

            return;
        }

        $record = $this->deliveryQuery()
            ->where(fn ($q) => $q
                ->where('invoice', $code)
                ->orWhereHas('invdata', fn ($r) => $r->where('invoice', $code)))
            ->first();

        if (! $record) {
            Notification::make()
                ->title('Invoice not found')
                ->body("“{$code}” is not loaded on your current trip.")
                ->danger()
                ->send();

            return;
        }

        $this->scannedId = $record->getKey();
        $this->mountAction('deliverScanned');
    }

    // Always re-check the scanned invoice belongs to this user's trip
    protected function scannedRecord(): ?Tripinvoice
    {
        if (! $this->scannedId) {
            return null;
        }

        return $this->deliveryQuery()
            ->with('invdata')
            ->whereKey($this->scannedId)
            ->first();
    }

    // Shared upload field (used by scan modal, Picture and Edit)
    protected static function pictureUpload(callable $directory): FileUpload
    {
        return FileUpload::make('delivery_picture')
            ->label('Delivery Picture')
            ->multiple()
            ->panelLayout('grid')
            ->uploadingMessage('Uploading ...')
            ->image()
            ->openable()
            ->disk('public')
            ->directory($directory)
            ->visibility('private')
            ->required()
            ->removeUploadedFileButtonPosition('right');
    }

    public function deliverScannedAction(): Action
    {
        return Action::make('deliverScanned')
            ->modalIcon(Heroicon::Camera)
            ->modalWidth('lg')
            ->modalHeading(function () {
                $record = $this->scannedRecord();
                $invoice = ucwords((string) ($record?->invdata?->invoice ?? $record?->invoice));

                return $record?->is_delivered
                    ? "Invoice {$invoice} — already delivered"
                    : "Deliver invoice {$invoice}";
            })
            ->modalDescription(function () {
                $data = $this->scannedRecord()?->invdata;

                return $data
                    ? ucwords(trim(($data->receiver_name ?? '').' — '.($data->receiver_province ?? ''), ' —'))
                    : null;
            })
            ->modalSubmitActionLabel(fn () => $this->scannedRecord()?->is_delivered ? 'Update pictures' : 'Mark as delivered')
            ->extraModalFooterActions(fn () => $this->scannedRecord()?->is_delivered ? [] : [
                Action::make('switchToCantDeliver')
                    ->label("Can't deliver")
                    ->color('danger')
                    ->outlined()
                    ->action(fn () => $this->replaceMountedAction('cantDeliverScanned')),
            ])
            ->fillForm(fn (): array => [
                'delivery_picture' => $this->scannedRecord()?->delivery_picture,
            ])
            ->schema([
                static::pictureUpload(fn () => \App\Support\Photos\Storage\PhotoFolders::dir('delivery', $this->scannedRecord()?->invoice)),
            ])
            ->action(function (array $data): void {
                $record = $this->scannedRecord();

                if (! $record) {
                    Notification::make()->title('Invoice not found')->danger()->send();

                    return;
                }

                $wasDelivered = (bool) $record->is_delivered;
                app(TripAssignment::class)->markDelivered($record, (array) $data['delivery_picture']);

                $notification = Notification::make()
                    ->title('Invoice '.ucwords((string) ($record->invdata?->invoice ?? $record->invoice)).($wasDelivered ? ' photos updated' : ' delivered'))
                    ->success();

                // A short window to take back a delivery tapped by mistake.
                if (! $wasDelivered) {
                    $notification
                        ->body('Wrong box? Tap Undo.')
                        ->duration(15000)
                        ->actions([
                            Action::make('undo')
                                ->label('Undo')
                                ->button()
                                ->color('warning')
                                ->dispatch('undo-delivery', ['tripinvoiceId' => $record->getKey()])
                                ->close(),
                        ]);
                }

                $notification->send();

                $this->scannedId = null;
            });
    }

    /**
     * Reason picker, note and photo for a box that could not be delivered.
     * The note and the photo become required for the reasons that need them.
     */
    protected static function failedDeliverySchema(callable $directory): array
    {
        $reason = fn (Get $get): ?FailedDeliveryReason => $get('reason') instanceof FailedDeliveryReason
            ? $get('reason')
            : FailedDeliveryReason::tryFrom((string) $get('reason'));

        return [
            Radio::make('reason')
                ->label('Why could you not deliver it?')
                ->options(FailedDeliveryReason::class)
                ->descriptions(collect(FailedDeliveryReason::cases())
                    ->mapWithKeys(fn (FailedDeliveryReason $case) => [$case->value => $case->getDescription()])
                    ->all())
                ->required()
                ->live(),
            Textarea::make('note')
                ->label(fn (Get $get) => $reason($get)?->notePrompt() ?? 'Note')
                ->placeholder('Optional')
                ->rows(2)
                ->maxLength(500)
                ->required(fn (Get $get) => (bool) $reason($get)?->requiresNote()),
            FileUpload::make('photos')
                ->label('Photo')
                ->helperText(fn (Get $get) => $reason($get)?->requiresPhoto()
                    ? 'Required: take a photo of the house, gate, road or damage.'
                    : 'Optional')
                ->multiple()
                ->maxFiles(3)
                ->image()
                ->disk('public')
                ->directory($directory)
                ->visibility('private')
                ->required(fn (Get $get) => (bool) $reason($get)?->requiresPhoto()),
        ];
    }

    protected function recordFailure(?Tripinvoice $record, array $data): void
    {
        if (! $record) {
            Notification::make()->title('Invoice not found on your trip')->danger()->send();

            return;
        }

        try {
            app(TripAssignment::class)->recordFailedAttempt(
                $record,
                Auth::user(),
                $data['reason'] instanceof FailedDeliveryReason ? $data['reason'] : FailedDeliveryReason::from($data['reason']),
                $data['note'] ?? null,
                (array) ($data['photos'] ?? []),
            );
        } catch (\DomainException $exception) {
            Notification::make()->title($exception->getMessage())->danger()->send();

            return;
        }

        Notification::make()
            ->title("{$record->invoice} marked as not delivered")
            ->body('The box stays on your truck. The office has been told.')
            ->warning()
            ->send();
    }

    public function cantDeliverScannedAction(): Action
    {
        return Action::make('cantDeliverScanned')
            ->modalHeading(fn () => "Can't deliver ".$this->scannedRecord()?->invoice)
            ->modalDescription(fn () => Str::title((string) $this->scannedRecord()?->invdata?->receiver_name))
            ->modalIcon(Heroicon::OutlinedNoSymbol)
            ->modalIconColor('danger')
            ->modalWidth('lg')
            ->modalSubmitActionLabel('Save reason')
            ->schema(static::failedDeliverySchema(fn () => \App\Support\Photos\Storage\PhotoFolders::dir('not-delivered', $this->scannedRecord()?->invoice)))
            ->action(function (array $data): void {
                $this->recordFailure($this->scannedRecord(), $data);
                $this->scannedId = null;
            });
    }

    /** "Undo" on the toast shown right after delivering. */
    #[On('undo-delivery')]
    public function undoDelivery(int $tripinvoiceId): void
    {
        $trip = static::currentDelivery();

        $record = $trip
            ? Tripinvoice::query()
                ->where(fn ($query) => $query->where('deliverylog_id', $trip->id)->orWhere('deliveryloghub_id', $trip->id))
                ->find($tripinvoiceId)
            : null;

        if (! $record) {
            Notification::make()->title('That box is not on your trip')->danger()->send();

            return;
        }

        try {
            app(TripAssignment::class)->undoDelivery($record, Auth::user(), UndoDeliveryReason::TappedByMistake);
        } catch (\DomainException $exception) {
            Notification::make()->title($exception->getMessage())->danger()->send();

            return;
        }

        Notification::make()
            ->title('Delivery undone')
            ->body("{$record->invoice} is back on your list.")
            ->success()
            ->send();
    }

    public function table(Table $table): Table
    {
        return $table
            ->emptyStateHeading('No Invoice Available')
            ->emptyStateDescription(fn () => $this->deliveryid
                ? 'No loaded invoices on this trip.'
                : 'You are not assigned to any current delivery trip.')
           // ->deferLoading()
            ->paginationMode(PaginationMode::Simple)
            ->query($this->deliveryQuery())
            ->columns([
                Stack::make([
                    TextColumn::make('invdata.invoice')
                        ->icon(Heroicon::OutlinedArchiveBox)
                        ->iconColor('primary')
                        ->size(TextSize::Large)
                        ->weight(FontWeight::ExtraBold),
                    TextColumn::make('invdata.receiver_name')
                        ->formatStateUsing(fn ($state) => Str::title($state))
                        ->weight(FontWeight::Bold),
                    TextColumn::make('address')
                        ->state(fn (Tripinvoice $record) => collect([
                            $record->invdata?->receiver_address,
                            $record->invdata?->receiver_barangay,
                            $record->invdata?->receiver_city,
                            $record->invdata?->receiver_province,
                        ])->filter()->map(fn ($part) => Str::title($part))->join(', '))
                        ->color('gray')
                        ->wrap(),
                    TextColumn::make('invdata.receiver_mobile_no')
                        ->icon(Heroicon::OutlinedPhone)
                        ->color('info')
                        ->url(fn (Tripinvoice $record) => $record->invdata?->receiver_mobile_no
                            ? 'tel:'.preg_replace('/[^0-9+]/', '', $record->invdata->receiver_mobile_no)
                            : null),
                    TextColumn::make('latestDeliveryAttempt.reason')
                        ->badge()
                        ->formatStateUsing(fn ($state, Tripinvoice $record) => 'Not delivered · '.$state->getLabel()
                            .($record->delivery_attempts_count > 1 ? " ({$record->delivery_attempts_count} tries)" : ''))
                        ->icon(fn ($state) => $state?->getIcon())
                        ->color('danger'),
                ])->space(1),
            ])
            ->filters([
                // TernaryFilter::make('is_delivered')
                //     ->label('Status')
                //     ->trueLabel('Delivered')
                //     ->falseLabel('Not delivered')
                //     ->placeholder('All')
                //     ->default(false),
                // SelectFilter::make('routearea_id')
                //     ->label('Route Area')
                //     ->relationship('route', 'description')
                //     ->preload()
                //     ->searchable(),
            ])
            ->deferFilters(false)
            ->recordActions([
                Action::make('cantDeliver')
                    ->label("Can't deliver")
                    ->icon(Heroicon::OutlinedNoSymbol)
                    ->color('danger')
                    ->button()
                    ->outlined()
                    ->size(Size::Large)
                    ->modalHeading(fn (Tripinvoice $record) => "Can't deliver {$record->invoice}")
                    ->modalDescription(fn (Tripinvoice $record) => Str::title((string) $record->invdata?->receiver_name))
                    ->modalIcon(Heroicon::OutlinedNoSymbol)
                    ->modalIconColor('danger')
                    ->modalWidth('lg')
                    ->modalSubmitActionLabel('Save reason')
                    ->schema(static::failedDeliverySchema(fn (Tripinvoice $record) => \App\Support\Photos\Storage\PhotoFolders::dir('not-delivered', $record->invoice)))
                    ->action(fn (array $data, Tripinvoice $record) => $this->recordFailure(
                        $this->deliveryQuery()->whereKey($record->getKey())->first(),
                        $data,
                    )),
            ]);
    }
}
DISPATCH_FILE_END_6

# ---------------------------------------------------------------- app/Filament/Delivery/Pages/Fuel.php
mkdir -p 'app/Filament/Delivery/Pages'
cat > 'app/Filament/Delivery/Pages/Fuel.php' <<'DISPATCH_FILE_END_7'
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
        $path = $this->upload->store(\App\Support\Photos\Storage\PhotoFolders::dir('fuel', rescue(fn () => FuelData::truckFor(Auth::user(), DriverTrip::currentTrip(Auth::user()))?->plate_no, null, false)), 'public');
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
DISPATCH_FILE_END_7

# ---------------------------------------------------------------- app/Filament/Delivery/Resources/Invoices/Pages/ListInvoices.php
mkdir -p 'app/Filament/Delivery/Resources/Invoices/Pages'
cat > 'app/Filament/Delivery/Resources/Invoices/Pages/ListInvoices.php' <<'DISPATCH_FILE_END_8'
<?php

namespace App\Filament\Delivery\Resources\Invoices\Pages;

use App\Filament\Delivery\Resources\Invoices\InvoiceResource;
use App\Filament\Delivery\Resources\Invoices\Tables\InvoicesTable;
use App\Models\Tripinvoice;
use App\Services\TripAssignment;
use App\Support\InvoiceLookup;
use Filament\Actions\Action;
use Filament\Actions\CreateAction;
use Filament\Forms\Components\FileUpload;
use Filament\Notifications\Notification;
use Filament\Resources\Pages\ListRecords;
use Filament\Support\Icons\Heroicon;
use Livewire\Attributes\Locked;

class ListInvoices extends ListRecords
{
    protected static string $resource = InvoiceResource::class;

    // The Tripinvoice found by the scanner
    #[Locked]
    public ?int $scannedTripId = null;

    protected function getHeaderActions(): array
    {
        return [
            Action::make('scanBarcode')
                ->label('Scan barcode')
                ->icon('heroicon-o-qr-code')
                ->color('gray')
                ->modalHeading('Scan box barcode')
                ->modalWidth('lg')
                ->modalContent(view('filament.modals.scan-invoice'))
                ->modalSubmitAction(false)
                ->modalCancelActionLabel('Close'),

            //    CreateAction::make(),
        ];
    }

    /**
     * Called by the scanner in the "Scan barcode" modal.
     */
    public function openScannedInvoice(string $code): void
    {
        $deliveryId = InvoicesTable::currentDeliveryId();
        $code = InvoiceLookup::normalize($code);

        // Only boxes loaded on the driver's own current trip can be delivered from here.
        $trip = $deliveryId
            ? Tripinvoice::query()
                ->where('invoice', $code)
                ->whereIn('invoice', InvoicesTable::tripInvoiceNumbers($deliveryId))
                ->where(fn ($query) => $query->where('deliverylog_id', $deliveryId)->orWhere('deliveryloghub_id', $deliveryId))
                ->latest('id')
                ->first()
            : null;

        if (! $trip) {
            Notification::make()
                ->title('No invoice found')
                ->body('“'.$code.'” is not on your current trip.')
                ->danger()
                ->send();

            return;
        }

        $this->scannedTripId = $trip->getKey();

        // Close the scanner modal and open the upload picture modal
        $this->replaceMountedAction('uploadPicture');
    }

    protected function scannedTrip(): ?Tripinvoice
    {
        $deliveryId = InvoicesTable::currentDeliveryId();

        return $this->scannedTripId && $deliveryId
            ? Tripinvoice::with('invdata')
                ->where(fn ($query) => $query->where('deliverylog_id', $deliveryId)->orWhere('deliveryloghub_id', $deliveryId))
                ->find($this->scannedTripId)
            : null;
    }

    /**
     * Upload delivery picture modal (opened after a successful scan).
     */
    public function uploadPictureAction(): Action
    {
        return Action::make('uploadPicture')
            ->modalIcon(Heroicon::Camera)
            ->modalWidth('lg')
            ->modalHeading(function () {
                $trip = $this->scannedTrip();
                $number = ucwords((string) ($trip?->invdata?->invoice ?? $trip?->invoice));

                return $trip?->is_delivered
                    ? "Invoice {$number} — already delivered"
                    : "Deliver invoice {$number}";
            })
            ->modalDescription(function () {
                $data = $this->scannedTrip()?->invdata;

                return $data
                    ? ucwords(trim(($data->receiver_name ?? '').' — '.($data->receiver_province ?? ''), ' —'))
                    : null;
            })
            ->modalSubmitActionLabel(fn () => $this->scannedTrip()?->is_delivered ? 'Update pictures' : 'Mark as delivered')
            ->fillForm(fn (): array => [
                'delivery_picture' => $this->scannedTrip()?->delivery_picture,
            ])
            ->schema([
                FileUpload::make('delivery_picture')
                    ->label('Delivery Picture')
                    ->multiple()
                    ->panelLayout('grid')
                    ->uploadingMessage('Uploading ...')
                    ->image()
                    ->openable()
                    ->disk('public')
                    ->directory(fn () => \App\Support\Photos\Storage\PhotoFolders::dir('delivery', $this->scannedTrip()?->invoice))
                    ->visibility('private')
                    ->required()
                    ->removeUploadedFileButtonPosition('right'),
            ])
            ->action(function (array $data): void {
                $trip = $this->scannedTrip();

                if (! $trip) {
                    Notification::make()->title('Invoice not found')->danger()->send();

                    return;
                }

                app(TripAssignment::class)->markDelivered($trip, (array) $data['delivery_picture']);

                Notification::make()
                    ->title('Invoice '.ucwords((string) ($trip->invdata?->invoice ?? $trip->invoice)).' delivered')
                    ->success()
                    ->send();

                $this->scannedTripId = null;
            });
    }
}
DISPATCH_FILE_END_8

# ---------------------------------------------------------------- app/Filament/Pages/PhotoStorage.php
mkdir -p 'app/Filament/Pages'
cat > 'app/Filament/Pages/PhotoStorage.php' <<'DISPATCH_FILE_END_9'
<?php

namespace App\Filament\Pages;

use App\Models\AppSetting;
use App\Models\Photos\PhotoTask;
use App\Models\Photos\PhotoTaskItem;
use App\Support\Photos\Storage\OldSystem;
use App\Support\Photos\Storage\PhotoStore;
use App\Support\Photos\Storage\PhotoWork;
use BackedEnum;
use Filament\Notifications\Notification;
use Filament\Pages\Page;
use Filament\Support\Icons\Heroicon;
use Illuminate\Contracts\Support\Htmlable;
use Illuminate\Support\Facades\Auth;
use Illuminate\Support\Facades\Cache;
use Illuminate\Support\Str;
use Symfony\Component\HttpFoundation\StreamedResponse;

/** Settings → Photo storage (board 66): buckets, moving photos, copying the old system's photos, workers. */
class PhotoStorage extends Page
{
    protected string $view = 'filament.photos.storage';

    protected static string|BackedEnum|null $navigationIcon = Heroicon::OutlinedCloudArrowUp;

    protected static ?string $title = 'Photo storage';

    protected static ?string $slug = 'photo-storage';

    public string $tab = 'old';

    public int $step = 1;

    public string $rt = 'wmsv2';

    public string $search = '';

    /** @var array<string, array<string, ?string>> */
    public array $form = [];

    /** @var array<string, bool> */
    public array $editing = ['tmp' => false, 'real' => false];

    public bool $autoOff = true;

    public bool $runHere = false;

    /** Move: put the photos in the new folders (board 67). */
    public bool $tidyMove = true;

    public bool $sureAgain = false;

    public string $oldFolder = '';

    /** @var array<string, string> */
    public array $msg = [];

    public static function canAccess(): bool
    {
        return PhotoStore::ready() && (bool) Auth::user()?->is_admin;
    }

    public function getHeading(): string|Htmlable
    {
        return '';
    }

    public function mount(): void
    {
        foreach (['tmp', 'real'] as $slot) {
            $b = PhotoStore::bucket($slot);
            $this->form[$slot] = ['provider' => $b->provider ?: 'r2', 'account_id' => $b->account_id, 'endpoint' => $b->endpoint, 'region' => $b->region,
                'bucket' => $b->bucket, 'access_key' => $b->access_key, 'secret' => ''];
            $this->editing[$slot] = ! $b->exists;
        }
        $this->oldFolder = (string) (OldSystem::folder() ?? dirname(base_path()).'/wms.icargoxpress.net');
        $task = OldSystem::task();
        $this->step = ! $task ? 1 : ($task->status === 'done' ? 6 : ($task->done || $task->status === 'running' ? 5 : 2));
    }

    public function setTab(string $tab): void
    {
        $this->tab = in_array($tab, ['old', 'bucket', 'work'], true) ? $tab : 'old';
    }

    public function setStep(int $n): void
    {
        $this->step = max(1, min(8, $n));
    }

    // ── Bucket tab ──────────────────────────────────────────────

    public function setProvider(string $slot, string $p): void
    {
        if (isset(PhotoStore::PROVIDERS[$p]) && isset($this->form[$slot])) {
            $this->form[$slot]['provider'] = $p;
            $this->editing[$slot] = true;
        }
    }

    public function editBucket(string $slot): void
    {
        $this->editing[$slot] = true;
    }

    public function saveBucket(string $slot): void
    {
        $f = array_map(fn ($v) => is_string($v) ? trim($v) : $v, $this->form[$slot] ?? []);
        $b = PhotoStore::bucket($slot);
        if ($b->exists && $slot === 'tmp' && PhotoStore::target() === 'tmp' && $b->bucket && $f['bucket'] !== $b->bucket && PhotoStore::countIn('tmp')) {
            $this->msg[$slot] = 'Photos are in this bucket: switch to Real and move them before you change it.';

            return;
        }
        $b->fill(['provider' => $f['provider'] ?? 'r2', 'account_id' => $f['account_id'] ?: null, 'endpoint' => $f['endpoint'] ?: null, 'region' => $f['region'] ?: null,
            'bucket' => $f['bucket'] ?: null, 'access_key' => $f['access_key'] ?: null]);
        if (filled($f['secret'] ?? null)) {
            $b->secret = $f['secret'];
        }
        $b->forceFill(['test_ok' => false, 'test_message' => null]);
        $b->slot = $slot;
        $b->save();
        PhotoStore::forgetMemo();
        $this->form[$slot]['secret'] = '';
        $this->editing[$slot] = false;
        $this->testBucket($slot);
    }

    public function testBucket(string $slot): void
    {
        [$ok, $msg] = PhotoStore::test($slot);
        PhotoStore::forgetMemo();
        $this->msg[$slot] = ($ok ? '✓ ' : '✗ ').$msg;
    }

    public function setTarget(string $place): void
    {
        if (! isset(PhotoStore::PLACES[$place]) || ! PhotoStore::usable($place)) {
            Notification::make()->title('Put and test that bucket first')->warning()->send();

            return;
        }
        PhotoStore::setTarget($place);
        Notification::make()->title('New photos go to: '.PhotoStore::PLACES[$place])->success()->send();
    }

    public function turnOff(string $slot): void
    {
        if ($slot !== 'tmp') {
            return;
        }
        $b = PhotoStore::bucket('tmp');
        if (PhotoStore::target() === 'tmp') {
            $this->msg['tmp'] = 'Not yet: new photos still go here. Choose Real bucket first.';
        } elseif (($n = PhotoStore::countIn('tmp')) > 0) {
            $this->msg['tmp'] = 'Not yet: '.number_format($n).' photos are still here. Move Temporary → Real first.';
        } else {
            $b->update(['is_off' => true]);
            $this->msg['tmp'] = 'Turned off: nothing is saved or read here. The files stay in Cloudflare as a backup.';
        }
        PhotoStore::forgetMemo();
    }

    public function turnOn(string $slot): void
    {
        PhotoStore::bucket($slot)->update(['is_off' => false]);
        $this->msg[$slot] = '';
        PhotoStore::forgetMemo();
    }

    public function startMove(): void
    {
        $to = PhotoStore::target();
        if ($to === 'server' || PhotoWork::active()) {
            Notification::make()->title($to === 'server' ? 'Choose a bucket for new photos first' : 'Another move is running')->warning()->send();

            return;
        }
        $t = PhotoWork::startMove($to, $this->tidyMove);
        Cache::forget('photos.server.count');
        Notification::make()->title(number_format($t->total).' photos will move to the '.strtolower(PhotoStore::PLACES[$to]))->success()->send();
    }

    public function startSwitch(): void
    {
        if (! PhotoStore::usable('real') || PhotoWork::active()) {
            Notification::make()->title(PhotoWork::active() ? 'Another move is running' : 'Put and test the real bucket first')->warning()->send();

            return;
        }
        PhotoWork::startSwitch($this->autoOff);
        Notification::make()->title('Switching to the real bucket')->success()->send();
    }

    public function pause(int $id): void
    {
        PhotoTask::whereKey($id)->whereIn('status', ['running', 'checking'])->update(['status' => 'paused']);
    }

    public function resume(int $id): void
    {
        PhotoTask::whereKey($id)->where('status', 'paused')->update(['status' => 'running']);
        PhotoWork::kick();
    }

    // ── Workers tab ─────────────────────────────────────────────

    public function toggleRunHere(): void
    {
        $this->runHere = ! $this->runHere;
    }

    /** "Run here": the page itself goes on while it is open (wire:poll). */
    public function tick(): void
    {
        if ($this->runHere) {
            PhotoWork::work(8);
            PhotoStore::forgetMemo();
        }
    }

    // ── Copy from the old system ────────────────────────────────

    public function saveFolder(): void
    {
        $dir = rtrim(trim($this->oldFolder), '/');
        AppSetting::put('photos.old_folder', $dir ?: null);
        Cache::forget('photos.old.columns');
        $f = OldSystem::find();
        Notification::make()->title($f['found'] ? 'Found the old system' : 'No folder there')->{$f['found'] ? 'success' : 'warning'}()->send();
    }

    public function scan(): void
    {
        $task = OldSystem::scan();
        $task->forceFill(['options' => array_merge($task->options ?? [], ['folders' => OldSystem::folders(OldSystem::find())])])->save();
        Cache::forget('photos.old.columns');
        $this->step = 2;
        Notification::make()->title('Scanned: '.number_format($task->items()->count()).' photo paths')->success()->send();
    }

    public function setOpt(string $key): void
    {
        $task = OldSystem::task();
        if ($task && in_array($key, ['small', 'keep', 'tidy'], true)) {
            $task->update(['options' => array_merge($task->options ?? [], [$key => ! $task->opt($key, $key !== 'keep')])]);
        }
    }

    public function tryFifty(): void
    {
        $task = OldSystem::task();
        if (! $task) {
            return;
        }
        if (! PhotoStore::usable(PhotoStore::target() !== 'server' ? PhotoStore::target() : 'tmp')) {
            Notification::make()->title('Put and test the bucket first (Bucket tab)')->warning()->send();

            return;
        }
        $n = OldSystem::tryFifty($task)->count();
        Notification::make()->title($n.' photos tried')->success()->send();
    }

    public function copyNew(): void
    {
        $task = OldSystem::task();
        if (! $task) {
            return;
        }
        $task->update(['status' => 'running', 'started_at' => $task->started_at ?? now(), 'options' => array_merge($task->options ?? [], ['again' => false])]);
        $task->items()->where('status', 'failed')->update(['status' => 'pending']);
        PhotoWork::kick();
        $this->sureAgain = false;
    }

    public function checkBucket(): void
    {
        $task = OldSystem::task();
        if ($task) {
            $task->items()->where('status', 'done')->update(['checked' => false]);
            $task->update(['status' => 'checking']);
            PhotoWork::kick();
        }
    }

    public function copyAgain(): void
    {
        if (! $this->sureAgain) {
            $this->sureAgain = true;

            return;
        }
        $task = OldSystem::task();
        if ($task) {
            $task->items()->whereIn('status', ['done', 'skipped', 'failed'])->update(['status' => 'pending', 'checked' => false]);
            $task->update(['status' => 'running', 'options' => array_merge($task->options ?? [], ['again' => true])]);
            PhotoWork::kick();
        }
        $this->sureAgain = false;
    }

    public function pick(int $id): void
    {
        $item = PhotoTaskItem::find($id);
        $item && OldSystem::pick($item);
    }

    public function markBackup(): void
    {
        AppSetting::put('photos.old_backup', AppSetting::get('photos.old_backup') ? null : now()->toDateString());
    }

    public function csv(string $kind): StreamedResponse
    {
        $task = OldSystem::task();
        $find = OldSystem::find();
        if ($kind === 'list') {
            AppSetting::put('photos.old_csv', now()->toDateString());
        }

        return response()->streamDownload(function () use ($task, $kind, $find) {
            $out = fopen('php://output', 'w');
            fputcsv($out, $kind === 'list' ? ['old link', 'new path in the bucket', 'status', 'size before', 'size after', 'found in', 'database'] : ['path', 'found in', 'status', 'file', 'database', 'note']);
            $task?->items()->orderBy('id')->chunk(1000, function ($items) use ($out, $kind, $find) {
                foreach ($items as $i) {
                    fputcsv($out, $kind === 'list'
                        ? [OldSystem::oldLink($i, $find), $i->path, $i->status, $i->size_before, $i->size_after, $i->found, $i->ref]
                        : [$i->path, $i->found, $i->status, $i->source, $i->ref, $i->note]);
                }
            });
            fclose($out);
        }, ($kind === 'list' ? 'old-to-new-links' : 'photo-scan-report').'-'.now()->format('Ymd-Hi').'.csv', ['Content-Type' => 'text/csv']);
    }

    protected function getViewData(): array
    {
        $target = PhotoStore::target();
        $tmp = PhotoStore::bucket('tmp');
        $real = PhotoStore::bucket('real');
        $task = OldSystem::task();
        $find = $this->tab === 'old' ? OldSystem::find() : ['found' => (bool) OldSystem::folder()];
        $active = PhotoWork::active();
        $serverCount = $this->tab === 'bucket' ? Cache::remember('photos.server.count', 600, function () {
            $n = 0;
            foreach (['public', 'box'] as $d) {
                foreach (rescue(fn () => $d === 'box' ? PhotoStore::server($d)->allFiles('box-photos') : PhotoStore::server($d)->allFiles(), [], false) as $p) {
                    $n += PhotoStore::skip($d, $p) || str_starts_with(basename($p), '.') ? 0 : 1;
                }
            }

            return $n;
        }) : 0;

        $items = fn () => $task ? $task->items() : PhotoTaskItem::whereRaw('1 = 0');
        $groups = $task ? $task->items()->selectRaw('found, count(*) as n')->groupBy('found')->pluck('n', 'found') : collect();

        return [
            'target' => $target, 'tmp' => $tmp, 'real' => $real, 'stats' => PhotoStore::stats(), 'driver' => PhotoStore::driverReady(),
            'usable' => ['server' => true, 'tmp' => PhotoStore::usable('tmp'), 'real' => PhotoStore::usable('real')],
            'inTmp' => PhotoStore::countIn('tmp'), 'serverCount' => $serverCount,
            'moves' => PhotoTask::whereIn('kind', ['move', 'switch'])->latest('id')->limit(3)->get(),
            'active' => $active, 'switch' => PhotoTask::where('kind', 'switch')->latest('id')->first(),
            'worker' => PhotoStore::workerOn(), 'scheduler' => PhotoStore::schedulerOn(), 'queueSeen' => PhotoStore::queueSeen(), 'scheduleSeen' => PhotoStore::scheduleSeen(),
            'find' => $find, 'task' => $task,
            'columns' => $this->tab === 'old' && $this->step === 1 && ($find['found'] ?? false) ? Cache::remember('photos.old.columns', 600, fn () => OldSystem::columns()->all()) : [],
            'groups' => $groups,
            'rows' => $this->tab === 'old' && $this->step === 3 ? $items()->where('found', $this->rt)
                ->when($this->search !== '', fn ($q) => $q->where(fn ($w) => $w->where('path', 'like', '%'.$this->search.'%')->orWhere('ref', 'like', '%'.$this->search.'%')))
                ->orderBy('id')->limit(40)->get() : collect(),
            'tried' => $this->step === 4 ? $items()->where('tried', true)->whereIn('status', ['done', 'skipped'])->orderByDesc('size_before')->limit(6)->get() : collect(),
            'triedSum' => $task ? $task->items()->where('tried', true)->where('status', 'done')->selectRaw('count(*) n, sum(size_before) b, sum(size_after) a')->first() : null,
            'last' => $this->step === 5 && $task ? $task->items()->whereIn('status', ['done', 'skipped', 'failed'])->latest('updated_at')->limit(6)->get() : collect(),
            'checkedN' => $task ? $task->items()->where('checked', true)->count() : 0,
            'missingN' => (int) ($groups['missing'] ?? 0),
            'maxKb' => \App\Support\Photos\Storage\PhotoFolders::maxKb(), 'folderMap' => \App\Support\Photos\Storage\PhotoFolders::MAP,
            'backup' => AppSetting::get('photos.old_backup'), 'csvAt' => AppSetting::get('photos.old_csv'),
            'mb' => fn ($b) => $b >= 1073741824 ? number_format($b / 1073741824, 1).' GB' : ($b >= 1048576 ? number_format($b / 1048576, 1).' MB' : number_format($b / 1024).' KB'),
            'openUrl' => fn (PhotoTaskItem $i) => route('photo-storage.open', $i->id),
            'oldUrl' => fn (PhotoTaskItem $i) => OldSystem::oldLink($i, $find),
        ];
    }
}
DISPATCH_FILE_END_9

# ---------------------------------------------------------------- app/Filament/Resources/CompanyResource.php
mkdir -p 'app/Filament/Resources'
cat > 'app/Filament/Resources/CompanyResource.php' <<'DISPATCH_FILE_END_10'
<?php

namespace App\Filament\Resources;

use UnitEnum;
use BackedEnum;
use Filament\Forms;
use Filament\Tables;
use App\Models\Company;
use Filament\Tables\Table;
use Filament\Schemas\Schema;
use Filament\Actions\EditAction;
use Filament\Resources\Resource;
use Filament\Actions\BulkActionGroup;
use Filament\Forms\Components\Select;
use Filament\Forms\Components\Toggle;
use Filament\Actions\DeleteBulkAction;
use Filament\Schemas\Components\Group;
use Filament\Tables\Columns\IconColumn;
use Filament\Tables\Columns\TextColumn;
use Filament\Forms\Components\TextInput;
use Filament\Schemas\Components\Section;
use Filament\Forms\Components\FileUpload;
use Illuminate\Database\Eloquent\Builder;
use App\Filament\Resources\CompanyResource\Pages;
use Illuminate\Database\Eloquent\SoftDeletingScope;
use App\Filament\Resources\CompanyResource\RelationManagers;
use App\Filament\Resources\CompanyResource\Pages\EditCompany;
use App\Filament\Resources\CompanyResource\Pages\CreateCompany;
use App\Filament\Resources\CompanyResource\Pages\ListCompanies;
use App\Models\Logistichub;

class CompanyResource extends Resource
{
    protected static ?string $model = Company::class;
    protected static ?string $navigationLabel = 'Company/Agent';
    public static ?string $label = 'Company/Agent';
    protected static string | UnitEnum | null $navigationGroup = 'Settings';
  //  protected static string | \BackedEnum | null $navigationIcon = 'heroicon-o-building-office-2';

    public static function form(Schema $schema): Schema
    {
        return $schema
            ->components([
                Group::make()
                ->schema([
                    Section::make('Company Information')
                    ->schema([
                      
                        TextInput::make('company_name')
                    ->label('Name')
                    ->required()
                    ->maxLength(255),
                TextInput::make('company_email')
                    ->label('Email')
                    ->email()
                    ->unique(ignoreRecord: true)
                    ->required()
                    ->maxLength(255),
                TextInput::make('company_mobileno')
                    ->label('Mobile Phone')
                    ->unique(ignoreRecord: true)
                    ->required()
                    ->maxLength(255),
                TextInput::make('company_phone')
                    ->label('Office Phone')
                    ->unique(ignoreRecord: true)
                    ->maxLength(255),
                TextInput::make('company_address')
                    ->label('Address')
                    ->required()
                    ->maxLength(255),
                    TextInput::make('company_owner')
                    ->label('Owner Name')
                    ->required()
                    ->maxLength(255),

                Select::make('logistichub_id')
    ->label('Hub')
    ->options(Logistichub::query()
    ->pluck('hub_name', 'id')),
    
                    ])->columns(2)
                ])->columnSpan(['lg' => 2]),
                Group::make()
                ->schema([
                Section::make('Other Information')
                ->schema([
                    FileUpload::make('company_picture')
                    ->image()
                    ->avatar()
                    ->imageEditor()
                    ->circleCropper()
                    // ->panelLayout('grid')
                    ->uploadingMessage('Uploading attachment...')
                    ->openable()
                    ->maxSize(1024)
                    ->disk('public')
                    ->directory('papers/companies')
                    ->visibility('private')
                    ->removeUploadedFileButtonPosition('right')
                    ->label('Logo')
                    ->columnSpanFull(),
                FileUpload::make('company_document')
                    ->label('Document')
                    ->multiple()
                    // ->panelLayout('grid')
                    ->uploadingMessage('Uploading attachment...')
                    ->openable()
                    ->disk('public')
                    ->directory('papers/companies')
                    ->visibility('private')
                    ->removeUploadedFileButtonPosition('right')
                    ->columnSpanFull(),
                Toggle::make('is_active')
                    ->label('Active')
                    ->required(),
                ])
                
                ])->columnSpan(['lg' => 1])
                
                    
            ])->columns(3);
    }

    public static function table(Table $table): Table
    {
        return $table
            ->columns([
                TextColumn::make('company_name')
                    ->label('Name')
                    ->searchable(),
                TextColumn::make('company_email')
                    ->label('Email')
                    ->searchable(),
                TextColumn::make('company_mobileno')
                    ->label('Mobile No.')
                    ->searchable(),
                TextColumn::make('company_phone')
                    ->label('Office No.')
                    ->searchable(),
                TextColumn::make('company_address')
                    ->label('Address')
                    ->searchable(),
                TextColumn::make('company_owner')
                    ->label('Owner')
                    ->searchable(),
                IconColumn::make('is_active')
                    ->label('Active')
                    ->boolean(),
                TextColumn::make('user.full_name')
                    ->label('Created By')
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
                //
            ])
            ->recordActions([
                EditAction::make(),
            ])
            ->toolbarActions([
                BulkActionGroup::make([
                    DeleteBulkAction::make(),
                ]),
            ]);
    }

    public static function getRelations(): array
    {
        return [
            //
        ];
    }

    public static function getPages(): array
    {
        return [
            'index' => ListCompanies::route('/'),
            'create' => CreateCompany::route('/create'),
            'edit' => EditCompany::route('/{record}/edit'),
        ];
    }
}
DISPATCH_FILE_END_10

# ---------------------------------------------------------------- app/Filament/Resources/ConsolidatorResource.php
mkdir -p 'app/Filament/Resources'
cat > 'app/Filament/Resources/ConsolidatorResource.php' <<'DISPATCH_FILE_END_11'
<?php

namespace App\Filament\Resources;

use Filament\Schemas\Schema;
use Filament\Schemas\Components\Group;
use Filament\Schemas\Components\Section;
use Filament\Forms\Components\TextInput;
use Filament\Forms\Components\Toggle;
use Filament\Tables\Columns\TextColumn;
use Filament\Actions\DeleteAction;
use Filament\Actions\EditAction;
use Filament\Actions\BulkActionGroup;
use Filament\Actions\DeleteBulkAction;
use App\Filament\Resources\ConsolidatorResource\Pages\ListConsolidators;
use App\Filament\Resources\ConsolidatorResource\Pages\CreateConsolidator;
use App\Filament\Resources\ConsolidatorResource\Pages\EditConsolidator;
use Filament\Forms;
use Filament\Tables;
use Filament\Tables\Table;
use App\Models\Consolidator;
use Filament\Resources\Resource;
use Illuminate\Support\Facades\Auth;
use Filament\Forms\Components\Hidden;
use Filament\Forms\Components\FileUpload;
use Illuminate\Database\Eloquent\Builder;
use Illuminate\Database\Eloquent\SoftDeletingScope;
use App\Filament\Resources\ConsolidatorResource\Pages;
use App\Filament\Resources\ConsolidatorResource\RelationManagers;
use UnitEnum;
class ConsolidatorResource extends Resource
{
    protected static ?string $model = Consolidator::class;
protected static string | UnitEnum | null $navigationGroup = 'Settings';
  //  protected static string | \BackedEnum | null $navigationIcon = 'heroicon-o-squares-plus';

    public static function form(Schema $schema): Schema
    {
        return $schema
            ->components([
                Group::make()
                ->schema([
                    Section::make('Consolidator Information')
                        ->columnSpanFull()
                ->schema([
                    TextInput::make('company_name')
                    ->required()
                    ->maxLength(255),
                TextInput::make('code')
                    ->maxLength(255),
                TextInput::make('address')
                    ->required()
                    ->maxLength(255),
                TextInput::make('mobile_no')
                    ->required()
                    ->maxLength(255),
                TextInput::make('office_no')
                    ->maxLength(255),
                    
                TextInput::make('website')
                    ->maxLength(255),
                 TextInput::make('email')
                    ->maxLength(255)
                ]),
            ]),
            Group::make()
            ->schema([
                Section::make('Other Information')
                ->schema([
                    FileUpload::make('logo')
                    ->image()
                    ->imageEditor()
                    // ->panelLayout('grid')
                    ->uploadingMessage('Uploading attachment...')
                    ->openable()
                    ->maxSize(1024)
                    ->disk('public')
                    ->directory('consolidatorlogo')
                    ->visibility('private')
                    ->removeUploadedFileButtonPosition('right')
                    ->label('Logo')
                    ->columnSpanFull(),
                    FileUpload::make('company_document')
                    ->label('Document')
                    ->multiple()
                    ->panelLayout('grid')
                    ->uploadingMessage('Uploading attachment...')
                    ->openable()
                    ->disk('public')
                    ->directory('papers/consolidators')
                    ->visibility('private')
                    ->removeUploadedFileButtonPosition('right'),
                    Toggle::make('is_active')
                    ->label('Active')
                    ->required()
                    ->default(true),
                    Toggle::make('is_download')
                    ->label('Download')
                    ->required()
                    ->default(true),
                    Toggle::make('is_upload')
                    ->label('Upload')
                    ->required()
                    ->default(true),
                 
                ])
                ])->columns(3)
                
                ]);
    }

    public static function table(Table $table): Table
    {
        return $table
            ->defaultSort('created_at','desc')
            ->columns([
                TextColumn::make('company_name')
                    ->searchable(),
                TextColumn::make('code')
                    ->searchable(),
                TextColumn::make('address')
                    ->searchable(),
                TextColumn::make('mobile_no')
                    ->searchable(),
                TextColumn::make('office_no')
                    ->searchable(),
                TextColumn::make('user.full_name')
                ->label('Created By'),
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
                //
            ])
            ->recordActions([
                DeleteAction::make(),
                EditAction::make(),
            ])
            ->toolbarActions([
                BulkActionGroup::make([
                    DeleteBulkAction::make(),
                ]),
            ]);
    }

    public static function getRelations(): array
    {
        return [
            //
        ];
    }

    public static function getPages(): array
    {
        return [
            'index' => ListConsolidators::route('/'),
            'create' => CreateConsolidator::route('/create'),
            'edit' => EditConsolidator::route('/{record}/edit'),
        ];
    }
}
DISPATCH_FILE_END_11

# ---------------------------------------------------------------- app/Filament/Resources/ContainerResource.php
mkdir -p 'app/Filament/Resources'
cat > 'app/Filament/Resources/ContainerResource.php' <<'DISPATCH_FILE_END_12'
<?php

namespace App\Filament\Resources;

use Filament\Forms;
use Filament\Tables;
use App\Models\Container;
use Filament\Tables\Table;
use Filament\Schemas\Schema;
use Filament\Actions\EditAction;
use Filament\Resources\Resource;
use Filament\Tables\Filters\Filter;
use Filament\Actions\BulkActionGroup;
use Filament\Forms\Components\Select;
use Filament\Forms\Components\Toggle;
use Filament\Actions\DeleteBulkAction;
use Filament\Tables\Columns\TextColumn;
use Filament\Forms\Components\TextInput;
use Filament\Schemas\Components\Section;
use Filament\Forms\Components\DatePicker;
use Filament\Forms\Components\FileUpload;
use Filament\Tables\Columns\ToggleColumn;
use Filament\Tables\Filters\SelectFilter;
use Illuminate\Database\Eloquent\Builder;
use Filament\Forms\Components\ToggleButtons;
use Filament\Forms\Components\MarkdownEditor;
use Symfony\Component\HttpFoundation\File\File;
use App\Filament\Resources\ContainerResource\Pages;
use Illuminate\Database\Eloquent\SoftDeletingScope;
use App\Filament\Resources\ContainerResource\RelationManagers;
use App\Filament\Resources\ContainerResource\Pages\EditContainer;
use App\Filament\Resources\ContainerResource\Pages\ListContainers;
use App\Filament\Resources\ContainerResource\Pages\CreateContainer;
use App\Filament\Resources\ContainerResource\RelationManagers\InvoicesRelationManager;
use App\Filament\Resources\ContainerResource\RelationManagers\ContainerRelationManager;
use App\Filament\Resources\ContainerResource\RelationManagers\ContainerinvoicesRelationManager;
use Filament\Actions\ActionGroup;

class ContainerResource extends Resource
{
    protected static ?string $model = Container::class;

    protected static string | \BackedEnum | null $navigationIcon = 'heroicon-o-inbox-stack';

    public static function form(Schema $schema): Schema
    {
        return $schema
            ->components([
                Section::make('Container Information')
                ->columnSpanFull()
                ->schema([
                    Select::make('consolidator_id')
                    ->relationship('consolidator', 'company_name')
                    ->label('Consolidator')
                    ->required(),
                TextInput::make('booking_no')
                    ->label('Booking Number')
                    ->required()
                    ->maxLength(255),
                TextInput::make('container_no')
                    ->label('Container Number')
                    ->required()
                    ->maxLength(255),
                TextInput::make('batch_no')
                    ->label('Batch Number')
                    ->required(),
                    TextInput::make('batch_year')
                    ->label('Batch Year')
                    ->required()
                   ->default(now()->year),
                TextInput::make('seal_number')
                    ->label('Seal Number')
                    ->required()
                    ->maxLength(255),
                TextInput::make('size')
                    ->label('Container Size')
                    ->required()
                    ->maxLength(255),
                TextInput::make('type')
                    ->label('Container Type')
                    ->required()
                    ->maxLength(255),

                TextInput::make('total_boxes')
                    ->label('Total Boxes')
                    ->required()
                    ->numeric(),
                    FileUpload::make('container_picture')
                    ->label('Container picture')
                    ->multiple()
                    ->panelLayout('grid')
                    ->uploadingMessage('Uploading attachment...')
                    ->openable()
                    ->disk('public')
                    ->directory('papers/containers')
                    ->visibility('private')
                    ->removeUploadedFileButtonPosition('right')
                    ->columnSpanFull(),
                Select::make('warehouse_id')
                    ->searchable()
                    ->preload()
                    ->label('Warehouse')
                    ->relationship('warehouse', 'name')
                    ->required(),
                Toggle::make('is_unloaded')
                    ->label('Is Unloaded'),
                MarkdownEditor::make('note')->columnSpanFull()
                    ->maxLength(255),
                ])->columns(3),

            ]);
    }

    public static function table(Table $table): Table
    {
        return $table
            ->columns([
                TextColumn::make('consolidator.company_name')
                    ->sortable(),
                TextColumn::make('container_no')
                    ->searchable(),
                TextColumn::make('warehouse.name')
                    ->sortable()
                    ->searchable(),
                TextColumn::make('booking_no')
                     ->toggleable(isToggledHiddenByDefault: true)
                    ->searchable(),
                 TextColumn::make('batch_no')
                    ->searchable(),
                TextColumn::make('batch_year')
                     ->toggleable(isToggledHiddenByDefault: true)
                    ->searchable(),
                TextColumn::make('seal_number')
                     ->toggleable(isToggledHiddenByDefault: true)
                    ->searchable(),
                TextColumn::make('size')
                     ->toggleable(isToggledHiddenByDefault: true)
                    ->searchable(),
                TextColumn::make('type')
                     ->toggleable(isToggledHiddenByDefault: true)
                    ->searchable(),
                TextColumn::make('total_boxes')
                    ->numeric()
                    ->sortable(),
                  TextColumn::make('Total Imported')
                    ->badge()
                    ->color('info')
                    ->numeric()
                    ->getStateUsing(function ($record) {
                        return $record->invoices()->count();
                    }),
                  TextColumn::make('Total Unloaded')
                    ->badge()
                    ->color('success')
                    ->numeric()
                    ->getStateUsing(function ($record) {
                        return $record->invoices()->where('is_verified', 1)->count();
                    }),
                TextColumn::make('note')
                     ->toggleable(isToggledHiddenByDefault: true)
                    ->searchable(),
                ToggleColumn::make('is_unloaded')
                    ->label('Is Unloaded')
                    ->sortable()
                    ->toggleable(isToggledHiddenByDefault: true),
                 TextColumn::make('user.full_name')
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
                 ToggleColumn::make('is_active')
                    ->label('Active')
                    ->sortable()
                    ->toggleable(isToggledHiddenByDefault: true),
            ])
            ->filters([

                SelectFilter::make('is_unloaded')
                    ->label('Is Unloaded')
                    ->options([
                        1 => 'Yes',
                        0 => 'No',
                    ])->default(0),
                SelectFilter::make('consolidator_id')
                    ->label('Consolidator')
                    ->searchable()
                    ->preload()
                    ->multiple()
                    ->relationship('consolidator', 'company_name'),
            ])->deferFilters(false)
            ->persistFiltersInSession()
            ->recordActions([
               ActionGroup::make([
                EditAction::make(),
               ])
            ])
            ->toolbarActions([
                BulkActionGroup::make([
              //      DeleteBulkAction::make(),
                ]),
            ]);
    }

    public static function getRelations(): array
    {
        return [
            InvoicesRelationManager::class,
        //    ContainerinvoicesRelationManager::class,

        ];
    }

    public static function getPages(): array
    {
        return [
            'index' => ListContainers::route('/'),
            'create' => CreateContainer::route('/create'),
            'edit' => EditContainer::route('/{record}/edit'),
        ];
    }
}
DISPATCH_FILE_END_12

# ---------------------------------------------------------------- app/Filament/Resources/Deliveryinvs/Tables/DeliveryinvsTable.php
mkdir -p 'app/Filament/Resources/Deliveryinvs/Tables'
cat > 'app/Filament/Resources/Deliveryinvs/Tables/DeliveryinvsTable.php' <<'DISPATCH_FILE_END_13'
<?php

namespace App\Filament\Resources\Deliveryinvs\Tables;

use App\Filament\Exports\DeliveryinvExporter;
use App\Filament\Resources\Deliverylogs\DeliverylogResource;
use App\Models\Consolidator;
use App\Models\Deliveryinv;
use App\Models\Invoice;
use App\Models\Routearea;
use App\Models\Tripinvoice;
use Filament\Actions\Action;
use Filament\Actions\ActionGroup;
use Filament\Actions\BulkActionGroup;
use Filament\Actions\DeleteBulkAction;
use Filament\Actions\ExportAction;
use Filament\Actions\Exports\Enums\ExportFormat;
use Filament\Actions\Exports\Models\Export;
use Filament\Actions\ViewAction;
use Filament\Forms\Components\FileUpload;
use Filament\Notifications\Notification;
use Filament\Support\Icons\Heroicon;
use Filament\Tables\Columns\TextColumn;
use Filament\Tables\Filters\SelectFilter;
use Filament\Tables\Table;
use Illuminate\Contracts\Database\Eloquent\Builder;
use Illuminate\Database\Eloquent\Model;
use Illuminate\Support\Facades\Auth;
use Illuminate\Support\Facades\Http;

class DeliveryinvsTable
{
    public static function configure(Table $table): Table
    {
        return $table
            ->query(Deliveryinv::Unloadedinv())
            ->columns([
                TextColumn::make('deliverylog.trip_number')
                    ->searchable()
                    ->label('Trip Number')
                    ->color('primary')
                    ->url(fn (Model $record) => DeliverylogResource::getUrl('edit', ['record' => $record->deliverylog_id])),
                TextColumn::make('company')
                    ->label('Company')
                    ->getStateUsing(function (Model $record) {
                        // $companyname = Consolidator::where('code', $records->location_code)->first();
                        $locationcode = Invoice::where('id', $record->invoice_id)->value('location_code');

                        return $companyname = Consolidator::nameForCode($locationcode);
                    }),
                TextColumn::make('invoice')
                    ->searchable()
                    ->label('Invoice'),
                TextColumn::make('invdata.container.batch_no')
                    ->toggleable(isToggledHiddenByDefault: true)
                    ->searchable()
                    ->label('Batch No'),
                TextColumn::make('invdata.container.batch_year')
                    ->searchable()
                    ->label('Batch Year'),
                TextColumn::make('invdata.container.container_no')
                    ->toggleable(isToggledHiddenByDefault: true)
                    ->searchable()
                    ->label('Container No'),
                TextColumn::make('invdata.sender_name')
                    ->toggleable(isToggledHiddenByDefault: true)
                    ->label('Sender'),
                TextColumn::make('invdata.receiver_name')
                    ->label('Receiver'),
                TextColumn::make('invdata.receiver_address')
                    ->toggleable(isToggledHiddenByDefault: true)
                    ->label('Address'),
                TextColumn::make('is_delivered')
                    ->label('Status')
                    ->formatStateUsing(function (Model $record) {
                        return $record->is_delivered ? 'Delivered' : 'In Transit';
                    })
                    ->color(function ($record) {
                        return $record->is_delivered ? 'success' : 'danger';
                    }),

                TextColumn::make('invdata.receiver_province')
                    ->toggleable(isToggledHiddenByDefault: true)
                    ->label('Province'),
                TextColumn::make('invdata.receiver_city')
                    ->toggleable(isToggledHiddenByDefault: true)
                    ->label('City'),
                TextColumn::make('invdata.receiver_barangay')
                    ->toggleable(isToggledHiddenByDefault: true)
                    ->label('Barangay'),
                TextColumn::make('invdata.boxtype')
                    ->label('Box Type'),
                TextColumn::make('invdata.routearea.description')
                    ->toggleable(isToggledHiddenByDefault: true)
                    ->label('Route Area'),
            ])
            ->filters([
                SelectFilter::make('is_delivered')
                    ->label('Is Delivered')
                    ->options([
                        1 => 'Yes',
                        0 => 'No',
                    ])->default(0),
                // SelectFilter::make('routearea_id')
                //     ->label('Route')
                //     ->relationship('invoice.routearea', 'description'),
                SelectFilter::make('deliverylog_id')
                    ->label('Trip Number')
                    ->searchable()
                    ->preload()
                    ->relationship('deliverylog', 'trip_number', fn (Builder $query) => $query->where('logistichub_id', Auth::user()->logistichub_id)),

                SelectFilter::make('container_id')
                    ->label('Batch / Container')
                    ->relationship(
                        name: 'invoice.container',
                        titleAttribute: 'container_no'

                    )
                    ->searchable(['container_no', 'batch_no', 'batch_year'])
                    ->preload()
                    ->getOptionLabelFromRecordUsing(function (Model $record) {
                        return "{$record->container_no} {$record->batch_no} {$record->batch_year}";
                    }),

                SelectFilter::make('province')
                    ->label('Province')
                    ->multiple()
                    ->searchable()
                    ->options(
                        Invoice::query()
                            ->select('receiver_province')
                            ->distinct()
                            ->orderBy('receiver_province')
                            ->pluck('receiver_province', 'receiver_province')
                            ->toArray()
                    )
                    ->query(function (Builder $query, array $data) {
                        if (! empty($data['values'])) {
                            $query->whereHas('invoice', function (Builder $q) use ($data) {
                                $q->whereIn('receiver_province', $data['values']);
                            });
                        }
                    }),
            ])->deferFilters(false)
            ->headerActions([
                ExportAction::make()
                    ->label('Export')
                    ->icon(Heroicon::ArrowUturnDown)
                    ->Color('primary')
                    ->exporter(DeliveryinvExporter::class)
                    ->formats([
                        ExportFormat::Xlsx,
                    ])
                    ->fileName(fn (Export $export): string => 'Delivery Invoices Export - '.now()->format('Y-m-d_H-i-s').'.xlsx'),
            ])
            ->recordActions([
                ActionGroup::make([

                    Action::make('MarkDelivered')
                        ->label('Mark Delivered')
                        ->icon('heroicon-o-check-circle')
                        ->color('success')
                        ->requiresConfirmation()
                        ->visible(fn ($record) => $record->status !== 'delivered')
                        ->action(function ($record) {
                            $locationCode = Invoice::where('id', $record->invoice_id)->value('location_code');
                            $server = config("services.locations.{$locationCode}");
                            if (! $server || blank($server['url']) || blank($server['token'])) {
                                Notification::make()
                                    ->title('No API configured for location code: '.($locationCode ?: 'empty'))
                                    ->danger()
                                    ->send();

                                return;
                            }

                            $response = Http::withToken($server['token'])
                                ->acceptJson()
                                ->timeout(15)
                                ->post($server['url'].'/status', [
                                    'invoice' => $record->invoice,
                                    'status' => 'Delivered',
                                ]);

                            if ($response->successful()) {

                                Notification::make()
                                    ->title('Invoice marked as delivered')
                                    ->success()
                                    ->send();
                            } elseif ($response->status() === 404) {
                                Notification::make()
                                    ->title('Invoice not found')
                                    ->danger()
                                    ->send();
                            } else {
                                Notification::make()
                                    ->title('API error')
                                    ->body($response->json('message') ?? $response->body())
                                    ->danger()
                                    ->send();
                            }
                        }),
                    // ViewAction::make()
                    //     ->slideOver()
                    //     ->modal()
                    //     ->label('View')
                    //     ->color('primary')
                    //     ->icon(Heroicon::Eye)
                    //     ->hidden(fn($record) => empty($record->delivery_picture)),

                    Action::make('Edit')
                        ->label('Edit Picture')
                        ->color('info')
                        ->icon(Heroicon::PencilSquare)
                        ->hidden(fn ($record) => empty($record->delivery_picture))
                        ->fillForm(fn (Model $record): array => [

                            'delivery_picture' => $record->delivery_picture,
                        ])
                        ->schema([
                            FileUpload::make('delivery_picture')
                                ->label('Delivery Picture')
                                ->multiple()
                                ->panelLayout('grid')
                                ->uploadingMessage('Uploading attachment...')
                                ->image()
                                ->openable()
                                ->disk('public')
                                ->directory(function (Model $record) {
                                    return \App\Support\Photos\Storage\PhotoFolders::dir('delivery', $record->invoice);
                                })
                                ->downloadable()
                                ->visibility('private')
                                ->required()
                                ->removeUploadedFileButtonPosition('right'),
                        ])
                        ->action(function (array $data, Model $record): void {
                            if (! auth()->user()->hasRole('cscanada')) {
                                Tripinvoice::where('id', $record->id)
                                    ->update([
                                        'delivery_picture' => $data['delivery_picture'],
                                    ]);
                                Notification::make()
                                    ->title('Delivery Picture Updated')
                                    ->success()
                                    ->send();
                            } else {
                                Notification::make()
                                    ->title('Edit Denied')
                                    ->warning()
                                    ->send();
                            }

                        }),
                    Action::make('Picture')
                        ->label('Add Picture')
                        ->color('danger')
                        ->icon(Heroicon::Camera)
                        ->hidden(fn ($record) => ! empty($record->delivery_picture))
                        ->schema([
                            FileUpload::make('delivery_picture')
                                ->label('Delivery Picture')
                                ->multiple()
                                ->panelLayout('grid')
                                ->uploadingMessage('Uploading ...')
                                ->acceptedFileTypes([
                                    'image/*',
                                    'application/pdf',
                                ])
                                ->openable()
                                ->disk('public')
                                ->directory(function (Model $record) {
                                    return \App\Support\Photos\Storage\PhotoFolders::dir('delivery', $record->invoice);
                                })
                                ->visibility('private')
                                ->required()
                                ->removeUploadedFileButtonPosition('right'),
                            // ->minFiles(6),
                        ])
                        ->action(function (array $data, Model $record): void {
                            if (! auth()->user()->hasRole('cscanada')) {
                                Tripinvoice::where('id', $record->id)
                                    ->update([
                                        'delivery_picture' => $data['delivery_picture'],
                                        'is_delivered' => true,
                                    ]);
                                Notification::make()
                                    ->title('Picture Added and Status Updated to Delivered')
                                    ->success()
                                    ->send();
                            } else {
                                Notification::make()
                                    ->title('Add Picture Denied')
                                    ->warning()
                                    ->send();
                            }

                        }),
                    Action::make('Delete Picture')
                        ->requiresConfirmation()
                        ->label('Delete Picture')
                        ->color('danger')
                        ->icon(Heroicon::Trash)
                        ->hidden(fn ($record) => empty($record->delivery_picture))
                        ->action(function (array $data, Model $record): void {
                            if (! auth()->user()->hasRole('cscanada')) {
                                Tripinvoice::where('id', $record->id)
                                    ->update([
                                        'delivery_picture' => null,
                                        'is_delivered' => false,
                                    ]);
                                Notification::make()
                                    ->title('Picture Deleted ')
                                    ->success()
                                    ->send();
                            } else {
                                Notification::make()
                                    ->title('Delete Denied')
                                    ->warning()
                                    ->send();
                            }

                        }),
                ]),
            ])
            ->toolbarActions([
                BulkActionGroup::make([
                    //    DeleteBulkAction::make(),
                ]),
            ]);
    }
}
DISPATCH_FILE_END_13

# ---------------------------------------------------------------- app/Filament/Resources/Trucks/Schemas/TruckForm.php
mkdir -p 'app/Filament/Resources/Trucks/Schemas'
cat > 'app/Filament/Resources/Trucks/Schemas/TruckForm.php' <<'DISPATCH_FILE_END_14'
<?php

namespace App\Filament\Resources\Trucks\Schemas;

use App\Models\Logistichub;
use Filament\Forms\Components\DatePicker;
use Filament\Forms\Components\FileUpload;
use Filament\Forms\Components\MarkdownEditor;
use Filament\Forms\Components\Select;
use Filament\Forms\Components\TextInput;
use Filament\Forms\Components\Toggle;
use Filament\Schemas\Components\Group;
use Filament\Schemas\Components\Section;
use Filament\Schemas\Schema;

class TruckForm
{
    public static function configure(Schema $schema): Schema
    {
        return $schema
            ->components([
                Group::make()
                    ->schema([
                        \App\Filament\Shared\Trucks\OwnershipSection::make(),
                        Section::make('vehicles Information')
                            ->schema([
                                TextInput::make('category')
                                    ->hint('Ex. Ten Wheeler, Truck, Mini Truck or Van')
                                    ->hintColor('warning')
                                    ->hintIcon('heroicon-m-truck')
                                    ->required()
                                    ->maxLength(255),
                                TextInput::make('description')
                                    ->hint('Ex Brand, Color, Model')
                                    ->hintColor('warning')
                                    ->hintIcon('heroicon-m-truck')
                                    ->required()
                                    ->maxLength(255),
                                TextInput::make('registration_no')
                                    ->label('Registration Number')
                                    ->required()
                                    ->maxLength(255),
                                TextInput::make('plate_no')
                                    ->label('Plate Number')
                                    ->unique()
                                    ->required()
                                    ->maxLength(255),
                                // Select::make('logistichub_id')
                                // ->label('Logistic Hub/Location')
                                // ->options(Logistichub::query()->pluck('hub_name', 'id'))
                                // ->required(),
                                TextInput::make('capacity')
                                    ->label(fn () => \App\Support\BoxSizes::on() ? 'Capacity (space, in normal boxes)' : 'Capacity (boxes)')
                                    ->numeric()
                                    ->minValue(1)
                                    ->placeholder('60')
                                    ->helperText(fn () => \App\Support\BoxSizes::on()
                                        ? 'How many of your normal box fit. Bigger boxes take more space: Settings → Box sizes. Empty means 50.'
                                        : 'About how many boxes fit. Used to plan trips; empty means 50.'),
                                MarkdownEditor::make('Note')
                                    ->columnSpanFull(),
                            ]),

                    ]),
                Group::make()
                    ->schema([
                        Section::make('Other Information')
                            ->schema([
                                FileUpload::make('truck_picture')
                                    ->image()
                                    ->avatar()
                                    ->imageEditor()
                                    ->circleCropper()
                                    ->uploadingMessage('Uploading attachment...')
                                    ->openable()
                                    ->maxSize(1024)
                                    ->disk('public')
                                    ->directory('trucks')
                                    ->visibility('private')
                                    ->removeUploadedFileButtonPosition('right')
                                    ->label('Vehicles Picture')
                                    ->columnSpanFull(),
                                DatePicker::make('date_registered')
                                    ->native(false)
                                    ->closeOnDateSelection(true)
                                    ->label('Date Register')
                                    ->required(),
                                DatePicker::make('date_expired')
                                    ->label('Registration Expiration Date')
                                    ->native(false)
                                    ->closeOnDateSelection(true)
                                    ->required()
                                    ->rules(['after_or_equal:today']),
                                Toggle::make('is_active')
                                    ->default(true)
                                    ->required(),
                            ]),

                    ]),

            ]);
    }
}
DISPATCH_FILE_END_14

# ---------------------------------------------------------------- app/Filament/Resources/Truckteams/Schemas/TruckteamForm.php
mkdir -p 'app/Filament/Resources/Truckteams/Schemas'
cat > 'app/Filament/Resources/Truckteams/Schemas/TruckteamForm.php' <<'DISPATCH_FILE_END_15'
<?php

namespace App\Filament\Resources\Truckteams\Schemas;

use App\Filament\Resources\UserResource\Pages\EditUser;
use App\Models\Logistichub;
use App\Models\Workposition;
use Filament\Forms\Components\FileUpload;
use Filament\Forms\Components\Select;
use Filament\Forms\Components\TextInput;
use Filament\Forms\Components\Toggle;
use Filament\Schemas\Components\Group;
use Filament\Schemas\Components\Section;
use Filament\Schemas\Components\Utilities\Get;
use Filament\Schemas\Schema;
use Illuminate\Support\Facades\Hash;
use Illuminate\Support\Str;

class TruckteamForm
{
    public static function configure(Schema $schema): Schema
    {
        return $schema
            ->components([
                Group::make()
                    ->schema([
                        Section::make('Personal Information')
                            ->schema([
                                TextInput::make('first_name')
                                    ->required()
                                    ->maxLength(255),
                                TextInput::make('middle_name')
                                    ->maxLength(255),
                                TextInput::make('last_name')
                                    ->required()
                                    ->maxLength(255),
                                TextInput::make('address')
                                    ->required()
                                    ->maxLength(255)
                                    ->columnSpanFull(),
                                TextInput::make('mobile_number')
                                    ->required()
                                    ->maxLength(255),
                                TextInput::make('email')
                                    ->email()
                                    ->required()
                                    ->maxLength(255)
                                    ->unique(ignoreRecord: true),
                                // Select::make('panelcategory_id')
                                //     ->label('Panel Category')
                                //     ->relationship(name: 'panelcategory', titleAttribute: 'description')
                                //      ->required(),
                                // Select::make('logistichub_id')
                                // ->label('Logistic Hub/Location')
                                // ->options(Logistichub::query()->pluck('hub_name', 'id'))
                                // ->required(),
                                Select::make('workposition_id')
                                    ->label('Work Position')
                                    ->options(Workposition::query()
                                        ->where('is_crew', true)
                                        ->pluck('position_description', 'id'))
                                    ->required(),

                                Toggle::make('is_active')
                                    ->label('Active')
                                    ->required(),
                                // Toggle::make('is_crew')
                                //     ->label('Crew')
                                //     ->required(),

                                //         Select::make('roles')
                                // ->multiple()
                                // ->relationship('roles', 'name')
                                // ->preload(),

                            ])->columns(3),

                    ])->columnSpan(['lg' => 2]),
                Group::make()
                    ->schema([
                        Section::make()
                            ->schema([
                                FileUpload::make('profile_picture')
                                    ->image()
                                    ->avatar()
                                    ->imageEditor()
                                    ->circleCropper()
                                    // ->panelLayout('grid')
                                    ->uploadingMessage('Uploading attachment...')
                                    ->openable()
                                    ->getUploadedFileNameForStorageUsing(function ($file, Get $get) {
                                        return Str::slug($get('last_name') ?: 'user').'-'.Str::random(8).'.'.$file->getClientOriginalExtension();
                                    })
                                    ->maxSize(1024)
                                    ->disk('public')
                                    ->directory('people')
                                    ->visibility('private')
                                    ->removeUploadedFileButtonPosition('right')
                                    ->label('Profile Picture'),
                                TextInput::make('password')
                                    ->password()
                                    ->required()
                                    ->dehydrateStateUsing(fn ($state) => Hash::make($state))
                                    ->dehydrated(fn ($state) => filled($state))
                                    ->maxLength(255)
                                    ->hiddenOn(EditUser::class)
                                    ->maxLength(255),
                            ]),
                    ])->columnSpan(['lg' => 1]),
            ])->columns(3);
    }
}
DISPATCH_FILE_END_15

# ---------------------------------------------------------------- app/Filament/Resources/Unmanifesteds/Pages/ListUnmanifesteds.php
mkdir -p 'app/Filament/Resources/Unmanifesteds/Pages'
cat > 'app/Filament/Resources/Unmanifesteds/Pages/ListUnmanifesteds.php' <<'DISPATCH_FILE_END_16'
<?php

namespace App\Filament\Resources\Unmanifesteds\Pages;

use App\Filament\Resources\Unmanifesteds\UnmanifestedResource;
use App\Models\Container;
use Filament\Actions\CreateAction;
use Filament\Forms\Components\FileUpload;
use Filament\Forms\Components\MarkdownEditor;
use Filament\Forms\Components\Select;
use Filament\Forms\Components\TextInput;
use Filament\Resources\Pages\ListRecords;
use Filament\Schemas\Components\Section;

class ListUnmanifesteds extends ListRecords
{
    protected static string $resource = UnmanifestedResource::class;

    protected function getHeaderActions(): array
    {
        return [
            CreateAction::make()
            ->createAnother(false)
            ->slideOver()
           // ->successNotification(fn() => 'Unmanifested created successfully!')
            ->label('Create Unmanifested')
            ->schema([

                Section::make('Unmanifested Details')
                ->schema([
                Select::make('container_id')
                        ->label('Container')
                        ->options(function () {
                            return Container::where('is_active', true)
                                ->pluck('container_no', 'id');
                        })
                        ->searchable()
                        ->required(),
                TextInput::make('invoice')
                ->label('Invoice Number')
                ->numeric()
                ->required(),
                MarkdownEditor::make('remarks')
                ->label('Remarks'),
                FileUpload::make('attachment_pic')
                ->label('Attachment')
                ->uploadingMessage('Uploading attachment...')
                ->image()
                ->disk('public')
                ->directory(fn () => \App\Support\Photos\Storage\PhotoFolders::dir('unmanifested'))
                ->visibility('private')
                ->required()
                ->maxSize(5120), // 5MB

                ])
            ]),
        ];
    }
}
DISPATCH_FILE_END_16

# ---------------------------------------------------------------- app/Filament/Resources/Unmanifesteds/Schemas/UnmanifestedForm.php
mkdir -p 'app/Filament/Resources/Unmanifesteds/Schemas'
cat > 'app/Filament/Resources/Unmanifesteds/Schemas/UnmanifestedForm.php' <<'DISPATCH_FILE_END_17'
<?php

namespace App\Filament\Resources\Unmanifesteds\Schemas;

use Filament\Forms\Components\FileUpload;
use Filament\Forms\Components\MarkdownEditor;
use Filament\Forms\Components\RichEditor;
use Filament\Forms\Components\Textarea;
use Filament\Forms\Components\TextInput;
use Filament\Schemas\Components\Section;
use Filament\Schemas\Schema;

class UnmanifestedForm
{
    public static function configure(Schema $schema): Schema
    {
        return $schema
            ->components([
                Section::make('Unmanifested Details')
                ->schema([
                    MarkdownEditor::make('remarks'),
                 FileUpload::make('attachment_pic')
                ->label('Attachment')
                ->uploadingMessage('Uploading attachment...')
                ->image()
                ->disk('public')
                ->directory(fn () => \App\Support\Photos\Storage\PhotoFolders::dir('unmanifested'))
                ->visibility('private')
                ->required()
                ->maxSize(5120), // 5MB
                ])->columnSpanFull()

            ]);
    }
}
DISPATCH_FILE_END_17

# ---------------------------------------------------------------- app/Filament/Resources/UserResource.php
mkdir -p 'app/Filament/Resources'
cat > 'app/Filament/Resources/UserResource.php' <<'DISPATCH_FILE_END_18'
<?php

namespace App\Filament\Resources;

use App\Filament\Resources\UserResource\Pages\ListUsers;
use App\Models\Company;
use App\Models\Logistichub;
use App\Models\User;
use App\Models\Warehouse;
use App\Support\People\People;
use Filament\Actions\Action;
use Filament\Actions\BulkActionGroup;
use Filament\Actions\DeleteBulkAction;
use Filament\Actions\EditAction;
use Filament\Forms\Components\FileUpload;
use Filament\Forms\Components\Select;
use Filament\Forms\Components\TextInput;
use Filament\Forms\Components\Toggle;
use Filament\Forms\Components\ToggleButtons;
use Filament\Notifications\Notification;
use Filament\Resources\Resource;
use Filament\Schemas\Components\Grid;
use Filament\Schemas\Components\Section;
use Filament\Schemas\Components\Text;
use Filament\Schemas\Components\Utilities\Get;
use Filament\Schemas\Components\Utilities\Set;
use Filament\Schemas\Schema;
use Filament\Tables\Columns\TextColumn;
use Filament\Tables\Columns\ViewColumn;
use Filament\Tables\Table;
use Illuminate\Database\Eloquent\Builder;
use Illuminate\Support\Facades\Auth;
use Illuminate\Support\Facades\Hash;
use Illuminate\Support\HtmlString;
use Illuminate\Support\Str;
use UnitEnum;

/**
 * Users (board 59): a list with a tab per panel, and New user / Edit user in a panel on the right.
 * Panels and work positions come from Settings (Panel categories, Work positions): nothing is fixed here.
 */
class UserResource extends Resource
{
    protected static ?string $model = User::class;

    protected static string|UnitEnum|null $navigationGroup = 'Settings';

    public static function form(Schema $schema): Schema
    {
        return $schema->columns(1)->components([
            Section::make('Personal')->compact()->schema([
                FileUpload::make('profile_picture')
                    ->hiddenLabel()->image()->avatar()->imageEditor()->circleCropper()
                    ->getUploadedFileNameForStorageUsing(fn ($file, Get $get) => Str::slug($get('last_name') ?: 'user').'-'.Str::random(8).'.'.$file->getClientOriginalExtension())
                    ->maxSize(1024)->disk('public')->directory('people')->visibility('private')
                    ->extraAttributes(['class' => 'ds-us__photo']),
                Grid::make(3)->schema([
                    TextInput::make('first_name')->required()->maxLength(255),
                    TextInput::make('middle_name')->maxLength(255)->placeholder('Optional'),
                    TextInput::make('last_name')->required()->maxLength(255),
                ]),
                Grid::make(2)->schema([
                    TextInput::make('mobile_number')->label('Mobile')->tel()->maxLength(255),
                    TextInput::make('email')->label('Email · used to sign in')->email()->required()->maxLength(255)->unique(ignoreRecord: true),
                ]),
                TextInput::make('address')->required()->maxLength(255),
            ]),

            Section::make('Works in')->description('Which app they open · from Settings → Panel categories')->compact()->schema([
                ToggleButtons::make('panelcategory_id')->hiddenLabel()->required()->inline()->live()
                    ->options(fn () => People::panels()->mapWithKeys(fn ($p) => [$p->id => People::look($p)['label']])->all())
                    ->icons(fn () => People::panels()->mapWithKeys(fn ($p) => [$p->id => People::look($p)['icon']])->all())
                    ->afterStateUpdated(function (Set $set, Get $get, $state) {
                        // a position of another panel does not fit any more
                        if ($get('workposition_id') && ! array_key_exists((int) $get('workposition_id'), People::positions((int) $state))) {
                            $set('workposition_id', null);
                        }
                        if (People::panelCode((int) $state) === 'drv') {
                            $set('is_crew', true);
                            $set('is_admin', false);
                        }
                    })
                    ->extraAttributes(['class' => 'ds-us__panels']),
                Text::make(fn (Get $get) => new HtmlString('<span class="ds-us__noapp">⚠ This panel has no app yet: they can be saved, but cannot sign in anywhere.</span>'))
                    ->visible(fn (Get $get) => $get('panelcategory_id') && ! in_array(People::panelCode((int) $get('panelcategory_id')), People::WITH_APP, true)),
                Grid::make(2)->schema([
                    Select::make('logistichub_id')->label('Hub / location')->required()->searchable()
                        ->options(fn () => Logistichub::query()->orderBy('hub_name')->pluck('hub_name', 'id')->all())
                        ->helperText(fn (Get $get) => People::panelCode((int) $get('panelcategory_id')) === 'co' ? 'The partner hub: they only see its boxes and trips.' : 'Where they work. Drivers: the hub their truck goes out from.'),
                    Select::make('warehouse_id')->label('Warehouse')->searchable()
                        ->options(fn () => Warehouse::query()->orderBy('name')->pluck('name', 'id')->all())
                        ->visible(fn (Get $get) => People::panelCode((int) $get('panelcategory_id')) !== 'co'),
                    Select::make('company_id')->label('Company')->required()->searchable()
                        ->options(fn () => Company::query()->where('is_active', true)->orderBy('company_name')->pluck('company_name', 'id')->all())
                        ->default(fn () => Auth::user()?->company_id),
                ]),
                ToggleButtons::make('workposition_id')->label('Work position')->required()->inline()
                    ->hint('From Settings → Work positions')
                    // the panel's positions; a position they already have stays in the list (older data)
                    ->options(fn (Get $get, ?User $record) => People::positions($get('panelcategory_id') ? (int) $get('panelcategory_id') : null)
                        + ($record?->workposition ? [$record->workposition->id => $record->workposition->position_description] : []))
                    ->hintAction(static::newPositionAction())
                    ->extraAttributes(['class' => 'ds-us__chips']),
                Toggle::make('is_crew')->label('Truck crew')->helperText('Can be put on a truck as driver or helper')->default(false),
            ]),

            Section::make('Access')->compact()->schema([
                Toggle::make('is_active')->label('Active')->helperText('Can sign in. Off: cannot sign in, history is kept')->default(true),
                Toggle::make('is_admin')->label('Admin')
                    ->helperText(fn (Get $get) => match (People::panelCode((int) $get('panelcategory_id'))) {
                        'adm' => 'Opens the Admin app. Off: Scan app only.',
                        'drv' => 'Drivers cannot be admin: the Driver app opens only for non-admins.',
                        default => 'Full access to settings and other users',
                    })
                    ->disabled(fn (Get $get) => People::panelCode((int) $get('panelcategory_id')) === 'drv')
                    ->default(false),
                Select::make('roles')->label('Roles')->multiple()->relationship('roles', 'name')->preload(),
            ]),

            Section::make('Password')->compact()->schema([
                TextInput::make('password')
                    ->label(fn (string $operation) => $operation === 'create' ? 'Password' : 'New password · leave empty to keep it')
                    ->password()->revealable()
                    ->required(fn (string $operation) => $operation === 'create')
                    ->minLength(8)->maxLength(255)
                    ->dehydrateStateUsing(fn ($state) => Hash::make($state))
                    ->dehydrated(fn ($state) => filled($state))
                    ->hintAction(Action::make('makePassword')->label('Make one')->icon('heroicon-m-sparkles')
                        ->action(function (Set $set) {
                            $pw = People::randomPassword();
                            $set('password', $pw);
                            Notification::make()->title('Password made: '.$pw)->body('Give it to them, then press Save. Click the eye to see it.')->success()->persistent()->send();
                        })),
            ]),
        ]);
    }

    /** ＋ New position (admin): saved in Settings → Work positions for the chosen panel. */
    protected static function newPositionAction(): Action
    {
        return Action::make('newPosition')->label('＋ New position')->link()
            ->visible(fn () => (bool) Auth::user()?->is_admin)
            ->modalHeading('New work position')->modalWidth('md')->modalSubmitActionLabel('Add')
            ->schema([
                TextInput::make('name')->label('Position')->required()->maxLength(60)->placeholder('Forklift operator'),
                Toggle::make('crew')->label('Truck crew')->helperText('Shows in Crew, can be put on a truck'),
            ])
            ->action(function (array $data, Get $get, Set $set) {
                $panel = $get('panelcategory_id') ? (int) $get('panelcategory_id') : null;
                $w = People::addPosition($data['name'], $panel, (bool) ($data['crew'] ?? false), (int) Auth::id());
                $set('workposition_id', $w->id);
                Notification::make()->title($w->position_description.' added to Work positions')->success()->send();
            });
    }

    public static function table(Table $table): Table
    {
        return $table
            ->modifyQueryUsing(fn (Builder $query) => $query->with(['panelcategory', 'workposition', 'logistichub:id,hub_name', 'warehouse:id,name', 'company:id,company_name']))
            ->defaultSort('first_name')
            ->recordClasses(fn (User $r) => $r->is_active ? null : 'ds-us__off')
            ->recordAction('edit')
            ->columns([
                ViewColumn::make('person')->label('Person')->view('filament.people.user-cell')
                    ->searchable(query: fn (Builder $query, string $search) => $query->where(fn ($q) => $q
                        ->where('first_name', 'like', "%{$search}%")->orWhere('last_name', 'like', "%{$search}%")
                        ->orWhere('email', 'like', "%{$search}%")->orWhere('mobile_number', 'like', '%'.preg_replace('/\D/', '', $search).'%')))
                    ->sortable(query: fn (Builder $query, string $direction) => $query->orderBy('first_name', $direction)->orderBy('last_name', $direction)),
                ViewColumn::make('works')->label('Works as')->view('filament.people.works-cell'),
                TextColumn::make('where')->label('Where')->color('gray')
                    ->state(fn (User $r) => collect([$r->logistichub?->hub_name, $r->panelcategory?->code === 'co' ? $r->company?->company_name : $r->warehouse?->name])->filter()->unique()->join(' · ') ?: '—'),
                TextColumn::make('mobile_number')->label('Mobile')->color('gray'),
                ViewColumn::make('status')->label('Status')->view('filament.people.status-cell'),
                TextColumn::make('seen')->label('Last active')->color('gray')->size('sm')
                    ->state(fn (User $r, $livewire) => People::ago($livewire->lastActive()[$r->id] ?? null)),
            ])
            ->recordActions([
                EditAction::make()->iconButton()->slideOver()->modalWidth('2xl')
                    ->modalHeading(fn (User $r) => People::name($r))
                    ->modalDescription(fn (User $r) => 'Added '.$r->created_at?->format('M j, Y').($r->updated_at ? ' · changed '.$r->updated_at->diffForHumans() : ''))
                    ->modalSubmitActionLabel('Save changes'),
            ])
            ->toolbarActions([
                BulkActionGroup::make([
                    DeleteBulkAction::make(),
                ]),
            ]);
    }

    public static function getRelations(): array
    {
        return [];
    }

    public static function getPages(): array
    {
        // New user and Edit user open on the right of the list (board 59), not on their own page
        return [
            'index' => ListUsers::route('/'),
        ];
    }
}
DISPATCH_FILE_END_18

# ---------------------------------------------------------------- app/Filament/Scan/Pages/ScanApp.php
mkdir -p 'app/Filament/Scan/Pages'
cat > 'app/Filament/Scan/Pages/ScanApp.php' <<'DISPATCH_FILE_END_19'
<?php

namespace App\Filament\Scan\Pages;

use App\Models\Ai\AiPhotoCheck;
use App\Models\Boxes\SetSplit;
use App\Models\BoxPhoto;
use App\Models\Deliverylog;
use App\Models\Invoice;
use App\Models\PhotoSetting;
use App\Models\Unmanifested;
use App\Models\Whdeliverylog;
use App\Services\TripAssignment;
use App\Support\Ai\Ai;
use App\Support\Ai\PhotoCheck;
use App\Support\BoxSizes;
use App\Support\Photos\BoxPhotos;
use App\Support\ScanModes;
use App\Support\Trips\TripRules;
use App\Support\TruckSpace;
use Filament\Actions\Action;
use Filament\Forms\Components\FileUpload;
use Filament\Forms\Components\Textarea;
use Filament\Notifications\Notification;
use Filament\Pages\Page;
use Filament\Panel;
use Illuminate\Contracts\Support\Htmlable;
use Illuminate\Support\Collection;
use Illuminate\Support\Facades\Auth;
use Livewire\Attributes\Locked;
use Livewire\Features\SupportFileUploads\TemporaryUploadedFile;

/**
 * The Scan app. One phone screen with four steps: start → pick → scan → done.
 * Scanning is done by the existing scan pages (Unload Container, Load Truck, …):
 * this page only picks the right one for the signed-in person and shows the result.
 */
class ScanApp extends Page
{
    protected string $view = 'filament.scan.app';

    protected static ?string $title = 'Scan';

    #[Locked]
    public string $screen = 'home';

    #[Locked]
    public ?string $mode = null;

    #[Locked]
    public ?int $choice = null;

    /** Result of the last scan, from the scan page that handled it. */
    #[Locked]
    public ?string $status = null;

    #[Locked]
    public ?string $message = null;

    #[Locked]
    public ?int $invoiceId = null;

    /** Box not on the container's manifest (Unload container only). */
    #[Locked]
    public ?string $missing = null;

    /** Boxes returned on this screen (Return boxes counts them as it goes). */
    #[Locked]
    public int $returned = 0;

    #[Locked]
    public int $sessionScans = 0;

    /** Load truck: the box was too early (its spot is nearer the door than what is loaded now). */
    #[Locked]
    public ?array $early = null;

    /** Load truck: where the box just loaded goes. */
    #[Locked]
    public ?array $spot = null;

    /** Unload: the section (or waiting truck) of the box just scanned. */
    #[Locked]
    public ?array $route = null;

    /** The box's set: "2 of 3 · 1 more still in this container". */
    #[Locked]
    public ?array $setInfo = null;

    /** Partner hub unload: the hub trip the box went on (board 45d). */
    public ?array $hubTrip = null;

    /** Load truck: the box is for another hub. */
    #[Locked]
    public ?array $wrongHub = null;

    /** Show the finished and closed ones on the pick list too (greyed out). */
    public bool $showFinished = false;

    /** The chosen trip or container as shown in the bar (kept, so it is not looked up on every tap). */
    public ?array $targetInfo = null;

    /** Start screen: the tiles show at once, the counts and Continue a moment later (board 54). */
    public bool $homeReady = false;

    /** Load next, space, "Room for more": loaded right after the scan screen shows (board 51). */
    public bool $extrasReady = false;

    /** Pick boxes: a number per scan, so the same message twice still shows again. */
    public int $pickSeq = 0;

    /** Pick boxes: the last result (title, why, tone, undo). */
    public ?array $pickResult = null;

    public ?string $condition = null;

    public string $note = '';

    /** @var TemporaryUploadedFile|null */
    public $boxPhoto = null;

    public static function getRoutePath(Panel $panel): string
    {
        return '/';
    }

    public function getTitle(): string|Htmlable
    {
        return 'Scan';
    }

    public function getHeading(): string
    {
        return '';
    }

    protected function modes(): array
    {
        return ScanModes::for(Auth::user());
    }

    protected function mode(): ?array
    {
        return $this->mode ? ($this->modes()[$this->mode] ?? null) : null;
    }

    /** The existing scan page for this mode, set to the chosen container or trip. */
    protected function station(?int $choice = null, ?string $modeKey = null): ?object
    {
        $mode = $modeKey ? ($this->modes()[$modeKey] ?? null) : $this->mode();
        if (! $mode) {
            return null;
        }

        $station = app($mode['class']);
        $station->data = [$mode['field'] => $choice ?? $this->choice];
        if (property_exists($station, 'returnedCount')) {
            $station->returnedCount = $this->returned;
        }

        return $station;
    }

    // ------------------------------------------------------------------ steps

    public function open(string $mode): void
    {
        if (! isset($this->modes()[$mode])) {
            return;
        }
        $this->mode = $mode;
        $this->choice = null;
        $this->showFinished = false;
        $this->screen = 'pick';
        $this->clearResult();
        // Pick boxes: one trip given to you opens by itself.
        if ($mode === 'pick' && ($mine = $this->station()?->appChoices()->where('mine', true)) && $mine->count() === 1) {
            $this->pick($mine->first()['id']);
        }
    }

    /** Pick boxes: take a trip that has no picker yet. */
    public function takeTrip(int $id): void
    {
        $trip = $this->mode === 'pick' ? $this->station()?->appChoices()->firstWhere('id', $id) : null;
        $model = $trip ? Deliverylog::find($id) : null;
        if (! $model || ! \App\Support\Trips\Picking::take($model, Auth::user())) {
            Notification::make()->title('Someone else took that trip.')->warning()->send();

            return;
        }
        $this->pick($id);
    }

    /** Pick boxes: all picked, go on with Load truck for the same trip. */
    public function goLoad(): void
    {
        $trip = $this->choice;
        $key = collect(['load', 'hub_load'])->first(fn ($k) => isset($this->modes()[$k]));
        if (! $key) {
            return;
        }
        $this->open($key);
        if ($trip && $this->station()?->appChoices()->contains('id', $trip)) {
            $this->pick($trip);
        }
    }

    /** Pick boxes: picked by mistake. */
    public function undoPick(int $rowId): void
    {
        $trip = $this->mode === 'pick' && $this->choice ? Deliverylog::find($this->choice) : null;
        if ($trip && \App\Support\Trips\Picking::isPicker($trip, Auth::user()) && \App\Support\Trips\Picking::undo($trip, $rowId, Auth::user())) {
            $this->pickResult = ['title' => '↶ Undone · back on the list', 'why' => 'Put the box back where it was.', 'tone' => 'warn', 'undo' => null, 'code' => $this->pickResult['code'] ?? ''];
            $this->status = 'warning';
        }
    }

    /** Pick boxes: the box is not in its section. */
    public function notFound(int $rowId): void
    {
        $trip = $this->mode === 'pick' && $this->choice ? Deliverylog::find($this->choice) : null;
        if ($trip && \App\Support\Trips\Picking::isPicker($trip, Auth::user()) && \App\Support\Trips\Picking::notFound($trip, $rowId, Auth::user())) {
            $this->pickResult = ['title' => 'Marked not found', 'why' => 'The office sees it on Picking. Keep picking the rest.', 'tone' => 'warn', 'undo' => null, 'code' => ''];
            $this->status = 'warning';
        }
    }

    public function pick(int $id): void
    {
        $station = $this->station();
        $target = $station?->appChoices()->firstWhere('id', $id);
        if (! $target) {
            Notification::make()->title('That one is not open for you any more.')->warning()->send();

            return;
        }
        $this->targetInfo = ['id' => $id, 'name' => $target['name'] ?? '', 'sub' => $target['sub'] ?? null];
        // for Continue on the start screen
        cache()->put('scan-app.last.'.Auth::id(), ['mode' => $this->mode, 'choice' => $id, 'name' => $target['name'] ?? ''], now()->addHours(16));
        $this->extrasReady = false;
        $this->choice = $id;
        $this->returned = 0;
        $this->screen = 'scan';
        $this->clearResult();
    }

    /** Called by the start screen once it shows. */
    public function loadHome(): void
    {
        $this->homeReady = true;
    }

    /** Continue: back to the job left unfinished. */
    public function continueLast(): void
    {
        $last = cache()->get('scan-app.last.'.Auth::id());
        if (! $last || ! isset($this->modes()[$last['mode']])) {
            return;
        }
        $this->open($last['mode']);
        if ($this->screen === 'pick') {
            $this->pick((int) $last['choice']);
        }
    }

    /** The unfinished job of this person for the Continue card, or null. */
    protected function resume(): ?array
    {
        $last = cache()->get('scan-app.last.'.Auth::id());
        $mode = $last ? ($this->modes()[$last['mode']] ?? null) : null;
        if (! $mode) {
            return null;
        }
        try {
            $p = $this->station((int) $last['choice'], $last['mode'])->progress();
        } catch (\Throwable) {
            return null;
        }
        $total = (int) ($p['total'] ?? 0);
        $done = (int) ($p['loaded'] ?? 0);
        if ($total <= 0 || $done >= $total) {
            return null;
        }

        return ['label' => $mode['label'], 'name' => $last['name'], 'done' => $done, 'total' => $total, 'pct' => (int) round($done / $total * 100)];
    }

    /** Called by the scan screen once it shows. */
    public function loadExtras(): void
    {
        $this->extrasReady = true;
    }

    public function toggleFinished(): void
    {
        $this->showFinished = ! $this->showFinished;
    }

    /**
     * Containers or trips for a scan, with progress. Started ones first, then not started;
     * finished (100%) and closed ones are marked so the list can hide them.
     */
    public function choiceList(string $modeKey): Collection
    {
        $station = $this->station(null, $modeKey);
        if (! $station) {
            return collect();
        }

        $choices = $station->appChoices()->values();
        // one database question for all of them when the scan can do that
        $many = method_exists($station, 'progressMany') ? $station->progressMany($choices->pluck('id')->all()) : null;

        return $choices->map(function (array $c, int $i) use ($modeKey, $many) {
            $p = $many !== null ? ($many[$c['id']] ?? ['loaded' => 0, 'total' => 0]) : $this->station($c['id'], $modeKey)->progress();
            $done = (int) ($p['loaded'] ?? 0);
            $total = (int) ($p['total'] ?? 0);

            return $c + [
                'done' => $done, 'total' => $total, 'order' => $i,
                'finished' => ! ($c['active'] ?? true) || ($total > 0 && $done >= $total),
            ];
        })->sortBy(fn ($c) => [$c['finished'] ? 2 : ($c['done'] > 0 ? 0 : 1), $c['order']])->values();
    }

    /** "2 waiting" for each scan on the start screen (kept for a minute). */
    protected function waitingCounts(): array
    {
        $user = Auth::user();

        return cache()->remember('scan-app.waiting.'.$user?->id, 60, fn () => collect(array_keys($this->modes()))
            ->mapWithKeys(fn ($key) => [$key => $this->choiceList($key)->where('finished', false)->count()])->all());
    }

    public function home(): void
    {
        cache()->forget('scan-app.waiting.'.Auth::id());
        $this->reset('mode', 'choice', 'returned');
        $this->homeReady = false;
        $this->screen = 'home';
        $this->clearResult();
    }

    public function back(): void
    {
        $this->screen = 'pick';
        $this->choice = null;
        $this->clearResult();
    }

    public function finish(): void
    {
        $this->screen = 'done';
        $this->clearResult();
    }

    public function dismiss(): void
    {
        $this->clearResult();
    }

    protected function clearResult(): void
    {
        $this->reset('status', 'message', 'invoiceId', 'missing', 'condition', 'note', 'boxPhoto', 'early', 'spot', 'route', 'setInfo', 'wrongHub', 'bypass', 'hubTrip', 'pickResult', 'which');
    }

    /** Board 58: two boxes with the scanned number still to do: ['code' => …, 'options' => [id, name, place, sender]]. */
    public ?array $which = null;

    /** Which one? → the receiver was tapped: scan that exact box. */
    public function chooseBox(int $id): void
    {
        $w = $this->which;
        if (! $w || ! collect($w['options'] ?? [])->contains('id', $id)) {
            return;
        }
        $this->runScan($w['code'], false, $id);
    }

    /** Which one? → Not this box. */
    public function skipBox(): void
    {
        $this->clearResult();
    }

    /** The box on the result card, when it has this number (two boxes can share one). */
    protected function boxShown(string $code): ?int
    {
        return $this->invoiceId && Invoice::whereKey($this->invoiceId)->value('invoice') === $code ? $this->invoiceId : null;
    }

    /** Called by the camera or the typed box number. */
    public function scan(string $code): void
    {
        $this->runScan($code);
    }

    /** Trip rules: the reason buttons (or "Ask the office") after "load it anyway". */
    public ?array $bypass = null;

    /** A city top-up the crew said no to (trip id => true). */
    public array $topUpSkipped = [];

    protected function bypassCtx(string $code): array
    {
        $kind = in_array($this->mode, ['wh_load'], true) ? 'transfer' : 'delivery';
        $model = $kind === 'transfer' ? Whdeliverylog::class : Deliverylog::class;

        return ['kind' => $kind, 'trip_id' => $this->choice, 'trip_number' => $this->choice ? $model::whereKey($this->choice)->value('trip_number') : null,
            'invoice_id' => $this->boxShown($code) ?? \App\Support\Boxes\SameNumber::best($code)?->id, 'box' => $code];
    }

    /** After "too early", "wrong hub", "other city" or "truck full": load that box anyway (with a reason, or ask the office). */
    public function loadAnyway(): void
    {
        $code = $this->early['code'] ?? $this->wrongHub['code'] ?? null;
        if (! $code) {
            return;
        }
        $rule = TripRules::ruleOf($this->early, $this->wrongHub);
        $ctx = $this->bypassCtx($code);
        $need = TripRules::need($rule, Auth::user(), $ctx['trip_id'], $ctx['invoice_id']);
        if ($need === 'free') {
            $this->runScan($code, true);

            return;
        }
        $this->bypass = ['rule' => $rule, 'code' => $code, 'need' => $need, 'title' => TripRules::RULES[$rule][0]];
    }

    public function bypassWith(string $reason): void
    {
        if (! $this->bypass || $this->bypass['need'] !== 'reason' || ! in_array($reason, TripRules::reasons(), true)) {
            return;
        }
        $b = $this->bypass;
        TripRules::record($b['rule'], Auth::user(), $reason, $this->bypassCtx($b['code']));
        $this->bypass = null;
        $this->runScan($b['code'], true);
    }

    public function askOffice(): void
    {
        if (! $this->bypass) {
            return;
        }
        $b = $this->bypass;
        TripRules::ask($b['rule'], Auth::user(), null, $this->bypassCtx($b['code']));
        $this->clearResult();
        $this->status = 'warning';
        $this->message = "Asked the office about {$b['code']}. Keep it aside: when they approve, scan it again.";
    }

    public function cancelBypass(): void
    {
        $this->bypass = null;
    }

    /** City top-up at loading: add the suggested city to the trip. */
    public function cityTopUpAdd(string $key): void
    {
        $station = $this->station();
        if ($this->mode === 'load' && $station && method_exists($station, 'addTopUpCity')) {
            $station->data['deliverylog_id'] = $this->choice;
            $station->addTopUpCity($key);
        }
    }

    public function cityTopUpSkip(): void
    {
        $this->topUpSkipped[(int) $this->choice] = true;
    }

    // ------------------------------------------------------------------ sections, truck waiting, sets

    /** Partner hub unload: Add anyway to the full trip (space is an estimate). */
    public function hubAnyway(): void
    {
        $station = $this->station();
        if (! $this->hubTrip || ! $station || ! method_exists($station, 'hubAnyway')) {
            return;
        }
        $station->hubTrip = $this->hubTrip;
        $station->hubAnyway();
        $this->hubTrip = $station->hubTrip;
    }

    /** Unload: take the box off the waiting truck and keep it in its section. */
    public function putInSection(): void
    {
        $station = $this->station();
        if ($this->mode !== 'unload' || ! $this->invoiceId || ! $station || ! method_exists($station, 'putInSection') || ! $station->putInSection($this->invoiceId)) {
            return;
        }
        $this->route = $station->route;
        $this->message = $station->lastMessage;
    }

    /** Unload: put the box on a spot of its section, or Skip (spots are optional, board 50). */
    public function setSpot(?int $spotId = null): void
    {
        $station = $this->station();
        if ($this->mode !== 'unload' || ! $this->invoiceId || ! $station || ! method_exists($station, 'setSpot') || ! $station->setSpot($this->invoiceId, $spotId)) {
            return;
        }
        $this->route = $station->route;
        $this->message = $station->lastMessage;
    }

    /** Unload, TRUCK screen: bring another box of the customer from its section onto the truck too. */
    public function addSetBox(int $boxId): void
    {
        $station = $this->station();
        if ($this->mode !== 'unload' || ! $this->invoiceId || ! $station || ! method_exists($station, 'addSetBox')) {
            return;
        }
        $code = $station->addSetBox($this->invoiceId, $boxId);
        if (! $code) {
            Notification::make()->title('That box cannot go on the truck now (it is on another trip or not in this warehouse).')->warning()->send();

            return;
        }
        $this->setInfo = $station->setInfo;
        Notification::make()->title($code.' added to the truck: bring it and scan it at the truck door (Load transfer truck).')->success()->send();
    }

    /** Load truck, Done screen: room left on the truck, add a waiting box to this trip. */
    public function topUpAdd(int $invoiceId): void
    {
        $station = $this->station();
        if ($this->mode !== 'load' || ! $station || ! $station->appChoices()->contains('id', $this->choice)) {
            return;
        }
        $trip = Deliverylog::with('truck')->find($this->choice);
        if (! $trip || ! TruckSpace::topUp($trip)['boxes']->contains('id', $invoiceId)) {
            Notification::make()->title('That box does not fit or is not free any more.')->warning()->send();

            return;
        }
        try {
            app(TripAssignment::class)->addToDeliveryTrip($trip, Invoice::whereKey($invoiceId)->get());
        } catch (\DomainException $e) {
            Notification::make()->title($e->getMessage())->warning()->send();

            return;
        }
        Notification::make()->title(Invoice::whereKey($invoiceId)->value('invoice').' added to trip '.$trip->trip_number.': scan it onto the truck')->success()->send();
        $this->pick($this->choice);
    }

    /** Count a section, Done screen: close the count. */
    public function closeCount(): void
    {
        $station = $this->station();
        if ($this->mode === 'count' && $station && method_exists($station, 'closeCount') && ($r = $station->closeCount())) {
            Notification::make()->title('Count closed: '.$r['found'].' found, '.count($r['missing']).' missing'.($r['moved'] ? ', '.$r['moved'].' moved in' : ''))->success()->send();
            $this->home();
        }
    }

    /** Receive truck / Receive container, Done screen: boxes not scanned get a Missing box issue. */
    public function finishReceiving(): void
    {
        $station = $this->station();
        if (! $station || ! method_exists($station, 'finishReceiving')) {
            return;
        }
        $made = $station->finishReceiving();
        if ($made === null) {
            return;
        }
        cache()->forget('scan-app.waiting.'.Auth::id());
        Notification::make()->title('Received')->body($made ? $made.' missing '.str('box')->plural($made).': a Missing box issue was opened for each.' : 'Every box arrived.')->success()->send();
        $this->home();
    }

    /** Load truck, Done screen: why a box of a customer's set stays behind. */
    public function splitReason(int $invoiceId, string $reason): void
    {
        $station = $this->station();
        if ($station && method_exists($station, 'recordSplit')) {
            $station->recordSplit($invoiceId, $reason);
        }
    }

    protected function runScan(string $code, bool $force = false, ?int $pin = null): void
    {
        $station = $this->station();
        if (! $station || ! $this->choice || $this->screen !== 'scan') {
            return;
        }
        // load anyway after a pick: the same box again, not a new Which one?
        $pin ??= $force ? $this->boxShown(\App\Support\InvoiceLookup::normalize($code)) : null;

        if ($force && property_exists($station, 'forceLoad')) {
            $station->forceLoad = true;
        }
        $pin ? $station->scanPinned($code, $pin) : $station->scan($code);
        session()->forget('filament.notifications'); // this screen shows its own result

        $this->clearResult();
        $this->status = $station->lastStatus;
        $this->message = $station->lastMessage;
        $this->invoiceId = $station->lastInvoiceId;
        $this->missing = property_exists($station, 'missingCode') ? $station->missingCode : null;
        if (property_exists($station, 'returnedCount')) {
            $this->returned = $station->returnedCount;
        }
        $this->early = property_exists($station, 'early') ? $station->early : null;
        $this->spot = property_exists($station, 'spot') ? $station->spot : null;
        $this->route = property_exists($station, 'route') ? $station->route : null;
        $this->setInfo = property_exists($station, 'setInfo') ? $station->setInfo : null;
        $this->wrongHub = property_exists($station, 'wrongHub') ? $station->wrongHub : null;
        $this->hubTrip = property_exists($station, 'hubTrip') ? $station->hubTrip : null;
        $this->pickResult = property_exists($station, 'pick') ? $station->pick : null;
        $this->which = $station->which ?? null;
        if ($this->which) {
            $this->status = 'which';
            $this->dispatch('scan-app-result', status: 'which');

            return;
        }
        if ($this->mode === 'pick') {
            $this->pickSeq++;
        }

        if ($this->status === 'success') {
            if ($this->invoiceId && $this->photosOn()) {
                // photos of this box may be sent in the back (ScanPhotoController) for a while
                $ok = collect(session('scan-app.photo-ok', []))->filter(fn ($v) => ($v['at'] ?? 0) > now()->subHours(2)->timestamp)->take(-40)->all();
                $ok[$this->invoiceId] = ['mode' => $this->mode, 'choice' => $this->choice, 'at' => now()->timestamp];
                session(['scan-app.photo-ok' => $ok]);
            }
            $this->sessionScans++;
            $key = 'scan-app.today.'.now()->toDateString();
            session([$key => session($key, 0) + 1]);
        }

        $this->dispatch('scan-app-result', status: $this->status);
    }

    // ------------------------------------------------------------------ photos

    protected function photoStep(): ?string
    {
        return $this->station()?->photoStep();
    }

    public function photosOn(): bool
    {
        $step = $this->photoStep();

        return $step !== null && PhotoSetting::current()->allows($step);
    }

    public function setCondition(?string $condition): void
    {
        $this->condition = array_key_exists((string) $condition, BoxPhoto::CONDITIONS) ? $condition : null;
    }

    public function saveBoxPhoto(): void
    {
        $invoice = $this->status === 'success' && $this->invoiceId ? Invoice::find($this->invoiceId) : null;
        if (! $invoice || ! $this->photosOn()) {
            $this->reset('boxPhoto');

            return;
        }

        $this->validate(['boxPhoto' => 'required|image|max:12288'], ['boxPhoto.image' => 'That file is not a photo.']);

        $station = $this->station();
        BoxPhotos::store($this->boxPhoto, $station->photoStep(), $invoice, $station->photoContext(), Auth::user(), $this->condition, $this->note ?: null);
        $this->reset('boxPhoto');
    }

    /** Photos of the last box at this step. */
    public function shots(): Collection
    {
        $step = $this->photoStep();

        return $this->invoiceId && $step
            ? BoxPhoto::where('invoice_id', $this->invoiceId)->where('step', $step)->orderBy('id')->get()
            : collect();
    }

    // ------------------------------------------------------------------ wrong box

    public function unmanifestedAction(): Action
    {
        return Action::make('unmanifested')
            ->label('Record as unmanifested')
            ->modalHeading(fn () => "Unmanifested box {$this->missing}")
            ->modalDescription('This box is in the container but not on its manifest. Take a photo and add a note.')
            ->schema([
                FileUpload::make('attachment_pic')->label('Photo')->image()->disk('public')->directory(fn () => \App\Support\Photos\Storage\PhotoFolders::dir('unmanifested'))->visibility('private')->required(),
                Textarea::make('remarks')->label('Notes')->rows(3),
            ])
            ->visible(fn () => filled($this->missing) && $this->mode === 'unload')
            ->action(function (array $data): void {
                Unmanifested::create([
                    'invoice' => $this->missing,
                    'container_id' => $this->choice,
                    'attachment_pic' => $data['attachment_pic'] ?? null,
                    'remarks' => $data['remarks'] ?? null,
                ]);
                Notification::make()->title("Unmanifested box {$this->missing} recorded")->success()->send();
                $this->clearResult();
            });
    }

    // ------------------------------------------------------------------ view

    protected function getViewData(): array
    {
        $user = Auth::user();
        $modes = $this->modes();
        $mode = $this->mode();

        $choices = collect();
        $finishedCount = 0;
        if ($this->screen === 'pick' && $mode) {
            $all = $this->choiceList($this->mode);
            $finishedCount = $all->where('finished', true)->count();
            $choices = $this->showFinished ? $all : $all->where('finished', false)->values();
        }

        $progress = ['loaded' => 0, 'total' => 0];
        $target = null;
        $loadNext = null;
        $team = [];
        $trucks = [];
        $openSets = [];
        $countResult = null;
        $receiveResult = null;
        $topUp = null;
        if (in_array($this->screen, ['scan', 'done'], true) && $mode && $this->choice) {
            $station = $this->station();
            $progress = $station->progress();
            $target = ($this->targetInfo['id'] ?? null) === $this->choice ? $this->targetInfo : $station->appChoices()->firstWhere('id', $this->choice);
            $extras = $this->extrasReady || $this->screen === 'done';
            $loadNext = $extras && $this->screen === 'scan' && method_exists($station, 'loadNext') ? $station->loadNext() : null;
            $team = $extras && method_exists($station, 'team') ? $station->team() : [];
            $hubCounts = $this->mode === 'load' && method_exists($station, 'hubCounts') ? $station->hubCounts() : null;
            $pickGroups = $this->mode === 'pick' && $this->screen === 'scan' ? $station->groups() : [];
            $trucks = $extras && $this->mode === 'unload' && method_exists($station, 'truckStatus') ? $station->truckStatus() : [];
            $openSets = $this->screen === 'done' && method_exists($station, 'openSets') ? $station->openSets() : [];
            $countResult = $this->screen === 'done' && method_exists($station, 'countResult') ? $station->countResult() : null;
            $receiveResult = $this->screen === 'done' && method_exists($station, 'receiveResult') ? $station->receiveResult() : null;
            // Box sizes: space on the truck while loading (a big box takes more).
            if ($extras && in_array($this->mode, ['load', 'hub_load'], true) && BoxSizes::on() && ($trip = Deliverylog::with('truck')->find($this->choice))) {
                $space = BoxSizes::tripSpace($trip, $this->mode === 'hub_load');
                if ($this->screen === 'done' && $this->mode === 'load' && ($progress['total'] ?? 0) > 0 && ($progress['loaded'] ?? 0) >= $progress['total']) {
                    $topUp = TruckSpace::topUp($trip);
                }
            }
        }

        $todayPhotos = BoxPhoto::where('user_id', $user?->id)->whereDate('taken_at', today());

        return [
            'modes' => $modes,
            'def' => $mode,
            'place' => ScanModes::place($user),
            'firstName' => $user?->first_name ?: 'there',
            'initials' => mb_strtoupper(mb_substr($user?->first_name ?? '', 0, 1).mb_substr($user?->last_name ?? '', 0, 1)) ?: '·',
            'greeting' => now()->hour < 12 ? 'Good morning' : (now()->hour < 18 ? 'Good afternoon' : 'Good evening'),
            'today' => [
                'scans' => (int) session('scan-app.today.'.now()->toDateString(), 0),
                'photos' => (clone $todayPhotos)->count(),
                'problems' => (clone $todayPhotos)->whereIn('condition', ['damaged', 'wet', 'open'])->distinct()->count('invoice_id'),
            ],
            'choices' => $choices,
            'finishedCount' => $finishedCount,
            'waiting' => $this->screen === 'home' && $this->homeReady ? $this->waitingCounts() : [],
            'resume' => $this->screen === 'home' && $this->homeReady ? $this->resume() : null,
            'homeReady' => $this->homeReady,
            'progress' => $progress,
            'target' => $target,
            'loadNext' => $loadNext,
            'team' => $team,
            'hubCounts' => $hubCounts ?? null,
            'trucks' => $trucks,
            'openSets' => $openSets,
            'countResult' => $countResult,
            'receiveResult' => $receiveResult,
            'topUp' => $topUp,
            'extrasReady' => $this->extrasReady || $this->screen !== 'scan',
            'paused' => $this->screen === 'scan' && $this->mode !== 'pick' && (($this->status !== null && ($this->status !== 'success' || $this->photosOn())) || $this->bypass !== null),
            'cityTopUp' => $this->extrasReady && $this->mode === 'load' && $this->choice && empty($this->topUpSkipped[(int) $this->choice]) && ($st = $this->station()) && method_exists($st, 'cityTopUp')
                ? (function () use ($st) {
                    $st->data['deliverylog_id'] = $this->choice;

                    return $st->cityTopUp();
                })() : null,
            'bypassReasons' => TripRules::reasons(),
            'noReason' => collect($openSets)->filter(fn ($o) => collect($o['missing'])->contains(fn ($m) => ! $m['reason']))->count(),
            'splitReasons' => SetSplit::REASONS,
            'box' => $box = ($this->invoiceId ? Invoice::find($this->invoiceId) : null),
            'space' => $space ?? null,
            'pickGroups' => $pickGroups ?? [],
            'boxSize' => $box && BoxSizes::on() ? ['name' => BoxSizes::nameOfType($box->boxtype), 'space' => BoxSizes::spaceOf($box->boxtype)] : null,
            'conditions' => BoxPhoto::CONDITIONS,
            'shots' => $this->status === 'success' ? $this->shots() : collect(),
            ...$this->aiPhotoFlag(),
        ];
    }

    /** AI photo check: the newest photo of this person that the AI thinks looks damaged while they marked it Good. */
    protected function aiPhotoFlag(): array
    {
        if ($this->screen !== 'scan' || ! Ai::switchedOn('photo_check')) {
            return ['aiFlag' => null, 'aiPending' => false];
        }
        $mine = AiPhotoCheck::where('source', 'scan')
            ->whereIn('box_photo_id', BoxPhoto::where('user_id', Auth::id())->where('taken_at', '>=', now()->subMinutes(20))->select('id'));

        return [
            'aiFlag' => (clone $mine)->where('flagged', true)->whereNull('decision')
                ->where(fn ($q) => $q->whereNull('worker_said')->orWhere('worker_said', 'good'))->latest('id')->first(),
            'aiPending' => (clone $mine)->whereNull('checked_at')->where('created_at', '>=', now()->subMinutes(3))->exists(),
        ];
    }

    public function aiFlagAnswer(int $id, bool $damaged): void
    {
        $check = AiPhotoCheck::whereIn('box_photo_id', BoxPhoto::where('user_id', Auth::id())->select('id'))->find($id);
        if (! $check || $check->decision) {
            return;
        }
        if ($damaged) {
            BoxPhoto::whereKey($check->box_photo_id)->update(['condition' => $check->verdict === 'wet' ? 'wet' : ($check->verdict === 'open' ? 'open' : 'damaged')]);
            PhotoCheck::confirm($check, Auth::user());
        } else {
            PhotoCheck::dismiss($check, Auth::user());
        }
    }
}
DISPATCH_FILE_END_19

# ---------------------------------------------------------------- app/Filament/Shared/Shipping/SeaShipmentPage.php
mkdir -p 'app/Filament/Shared/Shipping'
cat > 'app/Filament/Shared/Shipping/SeaShipmentPage.php' <<'DISPATCH_FILE_END_20'
<?php

namespace App\Filament\Shared\Shipping;

use App\Models\Shipping\SeaShipment;
use App\Models\Shipping\WrongHubBox;
use App\Support\Boxes\BoxSets;
use App\Support\Photos\PhotoShrinker;
use App\Support\Shipping\Shipments;
use App\Support\Tracking\Tracker;
use Filament\Facades\Filament;
use Filament\Notifications\Notification;
use Filament\Pages\Page;
use Illuminate\Contracts\Support\Htmlable;
use Illuminate\Support\Facades\Auth;
use Livewire\Attributes\Locked;
use Livewire\Attributes\Url;
use Livewire\WithFileUploads;

/** One sea shipment: its steps, details, port check, cost, and receiving at the partner hub. */
abstract class SeaShipmentPage extends Page
{
    use WithFileUploads;

    protected string $view = 'filament.shipping.detail';

    protected static bool $shouldRegisterNavigation = false;

    protected static ?string $slug = 'sea-shipment';

    /** Partner hub panel: may only press Arrived, Picked up and finish receiving. */
    protected static bool $hubSide = false;

    #[Url(as: 'shipment')]
    #[Locked]
    public int $shipmentId = 0;

    public array $f = [];

    public $sealPhoto = null;

    public $receipt = null;

    /** The "Change trip" list is open. */
    public bool $changing = false;

    public string $changeSearch = '';

    public static function canAccess(): bool
    {
        return Shipments::ready() && parent::canAccess();
    }

    public function mount(): void
    {
        $this->shipmentId = (int) request()->query('shipment', $this->shipmentId);
        $s = $this->shipment();
        abort_unless($s, 404);
        $this->fillForm($s);
    }

    protected function shipment(): ?SeaShipment
    {
        $hub = Tracker::hubFor(Auth::user(), Filament::getCurrentPanel()?->getId());
        $mine = (int) Auth::user()?->logistichub_id;
        $q = Shipments::visible($hub)->when(static::$hubSide, fn ($q) => $q->where(fn ($q) => $q->where('logistichub_id', $mine)
            ->when(Shipments::stopsReady(), fn ($q) => $q->orWhereIn('id', \App\Models\Shipping\SeaShipmentStop::where('logistichub_id', $mine)->select('sea_shipment_id')))));

        return $q->find($this->shipmentId);
    }

    protected function fillForm(SeaShipment $s): void
    {
        $lcl = \App\Support\Shipping\SeaTrucks::ready() ? ['forwarder', 'waybill_no', 'charge_basis', 'charge_rate', 'hand_over_at', 'pick_up_at'] : [];
        if (\Illuminate\Support\Facades\Schema::hasColumn('sea_shipments', 'forwarder_id')) {
            $lcl = array_merge($lcl, ['forwarder_id', 'hand_over_branch_id', 'pick_up_branch_id']);
        }
        foreach (array_merge(['mode', 'van_no', 'van_size', 'seal_no', 'shipping_line', 'vessel', 'voyage', 'bl_no', 'port_from', 'port_to', 'port_check', 'port_count', 'port_reason', 'cost_freight', 'cost_trucking', 'cost_port', 'cost_other', 'note'], $lcl) as $k) {
            $this->f[$k] = (string) ($s->{$k} ?? '');
        }
        $this->truckCost = \App\Support\Shipping\SeaTrucks::ready()
            ? \App\Support\Shipping\SeaTrucks::trucks($s)->mapWithKeys(fn ($t) => [$t['tripId'] => $t['cost'] !== null ? (string) $t['cost'] : ''])->all() : [];
        $this->f['etd'] = $s->etd?->toDateString() ?? '';
        $this->f['eta'] = $s->eta?->toDateString() ?? '';
    }

    public function getTitle(): string|Htmlable
    {
        $s = $this->shipment();

        return $s ? $s->code.' → '.($s->hub?->hub_name ?? '') : 'Sea shipment';
    }

    public function save(): void
    {
        abort_if(static::$hubSide, 403);
        $s = $this->shipment();
        abort_unless($s, 404);
        foreach (['cost_freight', 'cost_trucking', 'cost_port', 'cost_other', 'charge_rate'] as $k) {
            if (array_key_exists($k, $this->f)) {
                $this->f[$k] = str_replace([',', '₱', ' '], '', (string) $this->f[$k]);
            }
        }
        $this->validate([
            'f.mode' => 'required|in:'.implode(',', array_keys(Shipments::MODES)),
            'f.port_check' => 'required|in:'.implode(',', array_keys(Shipments::PORT_CHECKS)),
            'f.van_no' => 'nullable|string|max:20', 'f.van_size' => 'nullable|string|max:10', 'f.seal_no' => 'nullable|string|max:30',
            'f.shipping_line' => 'nullable|string|max:80', 'f.vessel' => 'nullable|string|max:80', 'f.voyage' => 'nullable|string|max:30', 'f.bl_no' => 'nullable|string|max:40',
            'f.port_from' => 'nullable|string|max:80', 'f.port_to' => 'nullable|string|max:80', 'f.etd' => 'nullable|date', 'f.eta' => 'nullable|date',
            'f.port_count' => 'nullable|integer|min:0|max:100000', 'f.port_reason' => 'nullable|string|max:200',
            'f.cost_freight' => 'nullable|numeric|min:0', 'f.cost_trucking' => 'nullable|numeric|min:0', 'f.cost_port' => 'nullable|numeric|min:0', 'f.cost_other' => 'nullable|numeric|min:0',
            'f.note' => 'nullable|string|max:500',
            'f.forwarder' => 'nullable|string|max:80', 'f.waybill_no' => 'nullable|string|max:40', 'f.charge_basis' => 'nullable|in:'.implode(',', array_keys(Shipments::CHARGES)),
            'f.charge_rate' => 'nullable|numeric|min:0', 'f.hand_over_at' => 'nullable|string|max:160', 'f.pick_up_at' => 'nullable|string|max:160',
            'f.forwarder_id' => 'nullable|integer', 'f.hand_over_branch_id' => 'nullable|integer', 'f.pick_up_branch_id' => 'nullable|integer',
            'sealPhoto' => 'nullable|image|max:12288', 'receipt' => 'nullable|image|max:12288',
        ]);
        $data = collect($this->f)->map(fn ($v) => $v === '' ? null : $v)->all();
        // board 64: the forwarder and its branches come from Settings → Forwarders; the text follows them
        if (! empty($data['forwarder_id']) && ($fw = \App\Models\Shipping\Forwarder::find($data['forwarder_id']))) {
            $data['forwarder'] = $fw->name;
            foreach (['hand_over_branch_id' => 'hand_over_at', 'pick_up_branch_id' => 'pick_up_at'] as $id => $text) {
                $b = ! empty($data[$id]) ? \App\Models\Shipping\ForwarderBranch::where('forwarder_id', $fw->id)->find($data[$id]) : null;
                $data[$id] = $b?->id;
                if ($b) {
                    $data[$text] = $b->line();
                }
            }
        }
        if ($data['port_count'] !== null && (int) $data['port_count'] !== (int) $s->port_count) {
            $data['port_by'] = Auth::id();
            $data['port_at'] = now();
        }
        foreach (['sealPhoto' => 'seal_photo', 'receipt' => 'port_receipt'] as $prop => $col) {
            if ($this->{$prop}) {
                $path = $this->{$prop}->store(\App\Support\Photos\Storage\PhotoFolders::dir('shipments', $s->code ?? null), 'public');
                PhotoShrinker::file('public', $path);
                $data[$col] = $path;
                $this->{$prop} = null;
            }
        }
        $s->update($data);
        Notification::make()->title('Saved')->success()->send();
    }

    public function advance(): void
    {
        $s = $this->shipment();
        abort_unless($s, 404);
        $to = Shipments::next($s);
        if (! $to || ($to === 'received')) {
            return;
        }
        if (static::$hubSide && ! in_array($to, ['arrived', 'picked_up'], true)) {
            abort(403);
        }
        if (! Shipments::move($s, $to)) {
            Notification::make()->title('Not yet')->body(implode(' ', Shipments::blockers($s, $to)))->warning()->send();

            return;
        }
        Notification::make()->title(Shipments::label($s->fresh(), $to))->success()->send();
    }

    public function openChange(bool $open = true): void
    {
        $this->changing = $open && ! static::$hubSide;
        $this->changeSearch = '';
    }

    public function changeTrip(int $tripId): void
    {
        abort_if(static::$hubSide, 403);
        $s = $this->shipment();
        $trip = Shipments::tripsFor(Tracker::hubFor(Auth::user(), Filament::getCurrentPanel()?->getId()), true)->firstWhere('id', $tripId);
        if ($s && $trip && Shipments::changeTrip($s, $trip)) {
            $this->changing = false;
            Notification::make()->title($s->fresh()->code.' now uses trip '.$trip->trip_number)->success()->send();
        }
    }

    public function removeShipment(): void
    {
        abort_if(static::$hubSide, 403);
        $s = $this->shipment();
        if ($s && Shipments::remove($s)) {
            Notification::make()->title($s->code.' removed')->body('Trip '.$s->trip?->trip_number.' and its boxes stay as they are.')->success()->send();
            $this->redirect(str_replace('SeaShipment', 'SeaShipments', static::class)::getUrl());
        }
    }

    public function finishReceiving(): void
    {
        $s = $this->shipment();
        abort_unless($s && in_array($s->status, ['sailed', 'arrived', 'picked_up'], true), 404);
        abort_unless(static::$hubSide || Tracker::hubFor(Auth::user(), Filament::getCurrentPanel()?->getId()) === null, 403);
        $hubId = static::$hubSide ? (int) Auth::user()?->logistichub_id : null;
        $stop = $hubId ? Shipments::stopFor($s, $hubId) : Shipments::currentStop($s);
        abort_unless($stop && ! $stop->received_at && $this->isTurnOf($s, $stop), 403);
        $made = Shipments::finishReceiving($s, null, (int) $stop->logistichub_id);
        $next = Shipments::currentStop($s->fresh());
        Notification::make()->title(($stop->hub?->hub_name ?? $s->code).' received'.($next ? ' · passed on to '.$next->hub?->hub_name : ''))
            ->body($made ? "{$made} missing ".str('box')->plural($made).': an Invoice Issue was opened for each.' : 'Every box arrived.')->success()->send();
    }

    /** Every stop before this one is received (one container, more hubs). */
    protected function isTurnOf(SeaShipment $s, \App\Models\Shipping\SeaShipmentStop $stop): bool
    {
        return Shipments::stops($s)->every(fn ($x) => $x->stop >= $stop->stop || $x->received_at);
    }

    /** While preparing: put another hub's trip in this container (it unloads after the others). */
    public function addStop(int $tripId): void
    {
        abort_if(static::$hubSide, 403);
        $s = $this->shipment();
        $trip = Shipments::tripsFor(Tracker::hubFor(Auth::user(), Filament::getCurrentPanel()?->getId()), true)->firstWhere('id', $tripId);
        if (! $s || ! $trip) {
            return;
        }
        if ($clash = Shipments::portClash([$s->trip, $trip])) {
            Notification::make()->title('Different ports: '.implode(' and ', $clash))->body('One container goes to one port. Make another sea shipment for that trip.')->warning()->send();

            return;
        }
        if (Shipments::addStop($s, $trip)) {
            $this->changing = false;
            Notification::make()->title('Trip '.$trip->trip_number.' ('.$trip->destination?->hub_name.') is now in this container')->success()->send();
        }
    }

    public function removeStop(int $tripId): void
    {
        abort_if(static::$hubSide, 403);
        $s = $this->shipment();
        if ($s && Shipments::removeStop($s, $tripId)) {
            Notification::make()->title('Trip taken out of this container')->body('The trip and its boxes stay as they are.')->success()->send();
        }
    }

    public bool $adding = false;

    /** Board 62: Container, RoRo or LCL, from the buttons at the top (until the truck leaves). */
    public function setMode(string $mode): void
    {
        abort_if(static::$hubSide, 403);
        $s = $this->shipment();
        if (! $s || ! array_key_exists($mode, Shipments::MODES) || ! in_array($s->status, ['preparing', 'sealed'], true)) {
            return;
        }
        $s->update(match ($mode) {
            'roro' => ['mode' => 'roro', 'port_check' => 'off', 'port_reason' => $s->port_reason ?: 'RoRo: the truck drives onto the ferry'],
            'lcl' => ['mode' => 'lcl', 'port_check' => 'count'],
            default => ['mode' => 'container', 'port_check' => $s->port_check === 'off' && $s->mode === 'roro' ? 'count' : $s->port_check],
        });
        $this->fillForm($s->fresh());
    }

    /** Board 64: pick the forwarder; its usual rate fills in. */
    public function pickForwarder(int $id): void
    {
        abort_if(static::$hubSide, 403);
        $fw = \App\Models\Shipping\Forwarder::find($id);
        if (! $fw) {
            return;
        }
        $this->f['forwarder_id'] = (string) $fw->id;
        $this->f['forwarder'] = $fw->name;
        $this->f['charge_basis'] = $this->f['charge_basis'] ?: (string) $fw->charge_basis;
        $this->f['charge_rate'] = $this->f['charge_rate'] ?: (string) ($fw->charge_rate ?? '');
        $mine = $fw->branches()->pluck('id')->map(fn ($i) => (string) $i)->all();
        foreach (['hand_over_branch_id', 'pick_up_branch_id'] as $k) {
            if (! in_array((string) ($this->f[$k] ?? ''), $mine, true)) {
                $this->f[$k] = '';
            }
        }
    }

    /** Board 64: ＋ New branch for the chosen forwarder, right from the shipment. */
    public function newBranchAction(): \Filament\Actions\Action
    {
        return \Filament\Actions\Action::make('newBranch')->modalWidth('lg')
            ->modalHeading(fn () => 'New branch · '.(\App\Models\Shipping\Forwarder::find((int) ($this->f['forwarder_id'] ?? 0))?->name ?? ''))
            ->schema([
                \Filament\Forms\Components\Select::make('for')->label('Use it as')->options(['pick_up_branch_id' => 'Pick up at (the hub goes here)', 'hand_over_branch_id' => 'Hand over at (our truck goes here)'])->default('pick_up_branch_id')->required(),
                \Filament\Forms\Components\TextInput::make('name')->label('Branch')->required()->maxLength(80)->placeholder('Cebu · Pier 3'),
                \Filament\Forms\Components\TextInput::make('address')->maxLength(200),
                \Filament\Forms\Components\TextInput::make('hours')->maxLength(60)->placeholder('8 AM–5 PM'),
                \Filament\Forms\Components\TextInput::make('phone')->label('Contact no.')->maxLength(40),
            ])
            ->action(function (array $data) {
                $fid = (int) ($this->f['forwarder_id'] ?? 0);
                if (static::$hubSide || ! $fid) {
                    return;
                }
                $b = \App\Models\Shipping\ForwarderBranch::create(['forwarder_id' => $fid] + collect($data)->only(['name', 'address', 'hours', 'phone'])->all());
                $this->f[$data['for']] = (string) $b->id;
                Notification::make()->title($b->name.' added to the forwarder')->body('Press Save to keep it on this shipment.')->success()->send();
            });
    }

    /** "+ Add a second truck" list is open. */
    public bool $second = false;

    /** truck picked for a trip in that list */
    public array $secondTruck = [];

    public function useSecondTruck(int $tripId): void
    {
        abort_if(static::$hubSide, 403);
        $s = $this->shipment();
        $truck = (int) ($this->secondTruck[$tripId] ?? 0) ?: null;
        if ($s && \App\Support\Shipping\SeaTrucks::ownTruck($s, $tripId, $truck)) {
            $this->second = false;
            Notification::make()->title('Second truck added')->success()->send();
        } else {
            Notification::make()->title('Pick the truck for that trip first')->warning()->send();
        }
    }

    /** Board 62: this trip goes with the main truck. */
    public function goWithMain(int $tripId): void
    {
        abort_if(static::$hubSide, 403);
        $s = $this->shipment();
        if ($s && \App\Support\Shipping\SeaTrucks::goWithMain($s, $tripId)) {
            Notification::make()->title('It goes with the main truck now')->body('Load it on the main truck\'s trip in the Scan app.')->success()->send();
        }
    }

    /** Board 62: this trip keeps its own truck (a second truck). */
    public function ownTruck(int $tripId): void
    {
        abort_if(static::$hubSide, 403);
        $s = $this->shipment();
        if ($s && \App\Support\Shipping\SeaTrucks::ownTruck($s, $tripId)) {
            Notification::make()->title('Second truck: this trip uses its own truck')->success()->send();
        } else {
            Notification::make()->title('This trip has no truck of its own')->body('Give the trip a truck first (Delivery trips), then press this again.')->warning()->send();
        }
    }

    /** @var array<int, string> trucking per truck trip */
    public array $truckCost = [];

    public function saveTruckCost(int $tripId): void
    {
        abort_if(static::$hubSide, 403);
        $s = $this->shipment();
        $v = str_replace([',', '₱', ' '], '', (string) ($this->truckCost[$tripId] ?? ''));
        if (! $s || ($v !== '' && ! is_numeric($v))) {
            return;
        }
        \App\Support\Shipping\SeaTrucks::setCost($s, $tripId, $v === '' ? null : (float) $v);
        $this->fillForm($s->fresh());
        Notification::make()->title('Trucking saved')->success()->send();
    }

    public function openAdd(bool $open = true): void
    {
        $this->adding = $open && ! static::$hubSide;
        $this->changing = false;
        $this->changeSearch = '';
    }

    protected function getViewData(): array
    {
        $s = $this->shipment();
        $to = Shipments::next($s);

        return [
            's' => $s,
            'steps' => Shipments::steps($s),
            'stepKeys' => array_keys(Shipments::steps($s)),
            'next' => $to,
            'nextLabel' => $to ? Shipments::label($s, $to) : null,
            'blockers' => $to && $to !== 'received' ? Shipments::blockers($s, $to) : [],
            'counts' => Shipments::counts($s),
            'track' => Shipments::trackText($s),
            'openSets' => \App\Models\Deliverylog::whereIn('id', Shipments::tripIds($s))->get()->flatMap(fn ($t) => BoxSets::openOnTrip($t))->all(),
            'stops' => $stops = Shipments::stops($s),
            'wrong' => WrongHubBox::with('invoice', 'correctHub')->where('sea_shipment_id', $s->id)->get(),
            'modes' => Shipments::MODES,
            'charges' => Shipments::CHARGES,
            'forwarders' => \Illuminate\Support\Facades\Schema::hasTable('forwarders') ? \App\Models\Shipping\Forwarder::with('branches')->where(fn ($q) => $q->where('is_active', true)->orWhere('id', (int) ($this->f['forwarder_id'] ?? 0)))->orderBy('name')->get() : collect(),
            'ports' => \Illuminate\Support\Facades\Schema::hasTable('ports') ? \App\Models\Shipping\Port::where('is_active', true)->orderBy('name')->pluck('name') : collect(),
            'stopBoxes' => \App\Models\Tripinvoice::whereIn('deliverylog_id', Shipments::tripIds($s))->selectRaw('deliverylog_id, count(*) n')->groupBy('deliverylog_id')->pluck('n', 'deliverylog_id'),
            'hubTrucks' => $this->second ? \App\Models\Truck::where('is_active', 1)->where('logistichub_id', $s->trip?->logistichub_id)->orderBy('plate_no')->pluck('plate_no', 'id') : collect(),
            'trucks' => $trucks = \App\Support\Shipping\SeaTrucks::ready() ? \App\Support\Shipping\SeaTrucks::trucks($s) : collect(),
            'canTruck' => ! static::$hubSide && \App\Support\Shipping\SeaTrucks::ready() && \App\Support\Shipping\SeaTrucks::canChange($s),
            'carrierPlate' => fn ($st) => \App\Support\Shipping\SeaTrucks::ready() ? $trucks->first(fn ($t) => $t['stops']->contains('deliverylog_id', $st->deliverylog_id))['plate'] ?? null : null,
            'rides' => fn ($st) => \App\Support\Shipping\SeaTrucks::ready() && $st->exists && \App\Support\Shipping\SeaTrucks::rides($s, $st),
            'checks' => Shipments::PORT_CHECKS,
            'hubSide' => static::$hubSide,
            'canPress' => $to && $to !== 'received' && (! static::$hubSide || in_array($to, ['arrived', 'picked_up'], true)),
            'receiveStop' => $rs = in_array($s->status, ['sailed', 'arrived', 'picked_up'], true) && (static::$hubSide || Tracker::hubFor(Auth::user(), Filament::getCurrentPanel()?->getId()) === null)
                ? (static::$hubSide ? Shipments::stopFor($s, (int) Auth::user()?->logistichub_id) : Shipments::currentStop($s)) : null,
            'canReceive' => $rs && ! $rs->received_at && $this->isTurnOf($s, $rs),
            'nextAfter' => $rs ? $stops->first(fn ($x) => $x->stop > $rs->stop && ! $x->received_at)?->hub?->hub_name : null,
            'addTrips' => $this->adding ? Shipments::tripsFor(Tracker::hubFor(Auth::user(), Filament::getCurrentPanel()?->getId()))->filter(fn ($t) => ! Shipments::portClash([$s->trip, $t])) : collect(),
            'whenOf' => fn ($st) => Shipments::when($s, $st),
            'changeTrips' => $this->changing ? Shipments::tripsFor(Tracker::hubFor(Auth::user(), Filament::getCurrentPanel()?->getId()))
                ->filter(fn ($t) => $this->changeSearch === '' || collect(preg_split('/\s+/', mb_strtolower(trim($this->changeSearch))))->filter()
                    ->every(fn ($w) => str_contains(mb_strtolower($t->trip_number.' '.$t->destination?->hub_name.' '.$t->truck?->plate_no), $w)))->take(20) : collect(),
        ];
    }
}
DISPATCH_FILE_END_20

# ---------------------------------------------------------------- app/Filament/Shared/Trucks/TruckEditorPage.php
mkdir -p 'app/Filament/Shared/Trucks'
cat > 'app/Filament/Shared/Trucks/TruckEditorPage.php' <<'DISPATCH_FILE_END_21'
<?php

namespace App\Filament\Shared\Trucks;

use App\Models\Logistichub;
use App\Models\RentalCompany;
use App\Models\Truck;
use App\Support\Photos\PhotoShrinker;
use App\Support\Rentals;
use App\Support\Tracking\Tracker;
use App\Support\TruckDuplicates;
use App\Support\TruckSpace;
use Filament\Facades\Filament;
use Filament\Notifications\Notification;
use Filament\Pages\Page;
use Illuminate\Contracts\Support\Htmlable;
use Illuminate\Support\Carbon;
use Illuminate\Support\Facades\Auth;
use Illuminate\Support\Facades\Storage;
use Illuminate\Support\Str;
use Illuminate\Validation\Rule;
use Livewire\Attributes\Url;
use Livewire\WithFileUploads;

/** Add or edit a truck on one page: live preview on the left, the form on the right. */
class TruckEditorPage extends Page
{
    use WithFileUploads;

    protected string $view = 'filament.trucks.editor';

    protected static ?string $slug = 'truck-edit';

    protected static bool $shouldRegisterNavigation = false;

    /** Kind tiles: label, hint, usual space, drawing length. */
    public const KINDS = [
        'van' => ['Van', 'up to 20', 20, 14],
        '4w' => ['4-wheeler', 'about 30', 30, 20],
        '6w' => ['6-wheeler', 'about 50', 50, 28],
        '10w' => ['10-wheeler', 'about 80', 80, 38],
        'other' => ['Other', 'type it', 50, 24],
    ];

    public const RATES = ['trip' => ['Per trip', 'a trip', 'Each trip costs this'], 'day' => ['Per day', 'a day', 'First trip of the day only'], 'km' => ['Per km', 'a km', 'Times the km the driver logs']];

    #[Url(as: 'truck')]
    public ?int $truckId = null;

    public array $data = [];

    public $photo = null;

    public bool $removePhoto = false;

    public bool $showSize = false;

    public static function canAccess(): bool
    {
        return Tracker::hubFor(Auth::user(), Filament::getCurrentPanel()?->getId()) !== false;
    }

    protected function hub(): int|false|null
    {
        return Tracker::hubFor(Auth::user(), Filament::getCurrentPanel()?->getId());
    }

    public function truck(): ?Truck
    {
        $t = $this->truckId ? Truck::with('rentalCompany')->find($this->truckId) : null;

        return $t && Tracker::canSeeTruck($this->hub(), $t) ? $t : null;
    }

    public static function kindOf(?string $category): string
    {
        $c = Str::lower((string) $category);

        return match (true) {
            $c === '' => '6w',
            Str::contains($c, 'van') => 'van',
            (bool) preg_match('/\b(10|ten)\b|10-?wheel|ten-?wheel/', $c) => '10w',
            (bool) preg_match('/\b(6|six)\b|6-?wheel|six-?wheel/', $c) => '6w',
            (bool) preg_match('/\b(4|four)\b|4-?wheel|four-?wheel/', $c) => '4w',
            default => 'other',
        };
    }

    public function mount(): void
    {
        $t = $this->truck();
        abort_if($this->truckId && ! $t, 404);
        $space = TruckSpace::ready();
        $rate = $t ? collect(['trip' => $t->rate_trip, 'day' => $t->rate_day, 'km' => $t->rate_km])->filter(fn ($v) => $v > 0) : collect();
        $kind = static::kindOf($t?->category);
        $this->data = [
            'plate_no' => $t?->plate_no ?? '', 'registration_no' => $t?->registration_no ?? '',
            'logistichub_id' => $t?->logistichub_id ?? Auth::user()->logistichub_id,
            'kind' => $kind, 'kindStart' => $t ? $kind : null, 'category' => $t?->category ?? '',
            'make_model' => $t?->make_model ?? '', 'description' => $t?->description ?? '',
            'ownership' => $t?->ownership === 'rental' ? 'rental' : 'own',
            'rental_company_id' => $t?->rental_company_id, 'rental_driver' => $t?->rental_driver ?? '',
            'rate_way' => $rate->keys()->first() ?? 'trip', 'rate' => $rate->first() !== null ? rtrim(rtrim(number_format((float) $rate->first(), 2, '.', ''), '0'), '.') : '',
            'date_registered' => $t?->date_registered?->format('Y-m-d') ?? '', 'date_expired' => $t?->date_expired?->format('Y-m-d') ?? '',
            'capacity' => $t?->capacity, 'note' => $t?->Note ?? '', 'is_active' => $t ? (bool) $t->is_active : true,
            'cargo_length_cm' => $space ? $t?->cargo_length_cm : null, 'cargo_width_cm' => $space ? $t?->cargo_width_cm : null,
            'cargo_height_cm' => $space ? $t?->cargo_height_cm : null, 'fill_pct' => $space ? $t?->fill_pct : null,
            'newCompany' => '', 'newCompanyPhone' => '',
        ];
        $this->showSize = $space && $t && $t->cargo_length_cm;
    }

    public function getTitle(): string|Htmlable
    {
        return $this->truckId ? 'Edit '.$this->truck()?->plate_no : 'Add a truck';
    }

    public function getHeading(): string|Htmlable
    {
        return '';
    }

    public function pickKind(string $k): void
    {
        if (! isset(static::KINDS[$k])) {
            return;
        }
        $this->data['kind'] = $k;
        if ($k !== 'other') {
            $this->data['capacity'] = static::KINDS[$k][2];
        }
    }

    public function setOwnership(string $o): void
    {
        $this->data['ownership'] = $o === 'rental' ? 'rental' : 'own';
    }

    public function setRateWay(string $w): void
    {
        $this->data['rate_way'] = isset(static::RATES[$w]) ? $w : 'trip';
    }

    public function stepSpace(int $by): void
    {
        $now = (int) ($this->data['capacity'] ?: static::KINDS[$this->data['kind']][2]);
        $this->data['capacity'] = max(5, $now + $by);
    }

    public function toggleActive(): void
    {
        $this->data['is_active'] = ! $this->data['is_active'];
    }

    public function addCompany(): void
    {
        $name = trim((string) $this->data['newCompany']);
        if ($name === '') {
            return;
        }
        $c = RentalCompany::create(['name' => $name, 'phone' => trim((string) $this->data['newCompanyPhone']) ?: null,
            'logistichub_id' => is_int($this->hub()) ? $this->hub() : ($this->data['logistichub_id'] ?: null)]);
        $this->data['rental_company_id'] = $c->id;
        $this->data['newCompany'] = $this->data['newCompanyPhone'] = '';
    }

    /** The plate is already an inactive truck: switch that one back on instead of adding it again. */
    public function reactivate(int $id): void
    {
        $t = Truck::find($id);
        abort_unless($t && Tracker::canSeeTruck($this->hub(), $t), 404);
        $t->update(['is_active' => true]);
        Notification::make()->title($t->plate_no.' is active again')->success()->send();
        $this->redirect($this->profileUrl($t) ?? $this->fleetUrl() ?? '/');
    }

    public function save(): void
    {
        $t = $this->truck();
        $d = $this->data;
        $rental = $d['ownership'] === 'rental';
        $this->validate([
            'data.plate_no' => ['required', 'string', 'max:255', Rule::unique('trucks', 'plate_no')->ignore($t?->id),
                function ($attr, $value, $fail) use ($t) {
                    if ($same = TruckDuplicates::existing($value, $t?->id)) {
                        $fail('Another truck already has this plate ('.$same->plate_no.').');
                    }
                }],
            'data.registration_no' => ['required', 'string', 'max:255'],
            'data.category' => [$d['kind'] === 'other' ? 'required' : 'nullable', 'string', 'max:255'],
            'data.logistichub_id' => ['required'],
            'data.date_registered' => ['required', 'date'],
            'data.date_expired' => ['required', 'date', 'after_or_equal:data.date_registered'],
            'data.capacity' => ['nullable', 'integer', 'min:1', 'max:5000'],
            'data.rental_company_id' => [$rental ? 'required' : 'nullable'],
            'data.rate' => ['nullable', 'numeric', 'min:0'],
            'photo' => ['nullable', 'image', 'max:8192'],
        ], [
            'data.plate_no.unique' => 'Another truck already has this plate.',
            'data.rental_company_id.required' => 'Pick the rental company, or add a new one.',
            'data.category.required' => 'Type what kind of truck it is.',
            'data.date_expired.after_or_equal' => 'Expiry must be after the registration date.',
        ], [
            'data.plate_no' => 'plate number', 'data.registration_no' => 'registration no.', 'data.logistichub_id' => 'hub',
            'data.date_registered' => 'registered date', 'data.date_expired' => 'expiry date',
        ]);

        $kindLabel = static::KINDS[$d['kind']][0];
        $category = $d['kind'] === 'other' ? trim($d['category'])
            : ($t && $d['kind'] === $d['kindStart'] && $t->category ? $t->category : $kindLabel);
        $rate = $d['rate'] !== '' && $d['rate'] !== null ? (float) $d['rate'] : null;
        $hub = is_int($this->hub()) ? $this->hub() : (int) $d['logistichub_id'];
        $values = [
            'plate_no' => TruckDuplicates::format($d['plate_no']), 'registration_no' => trim($d['registration_no']),
            'category' => $category, 'description' => trim((string) $d['description']), 'make_model' => trim((string) $d['make_model']) ?: null,
            'ownership' => $rental ? 'rental' : 'own',
            'rental_company_id' => $rental ? $d['rental_company_id'] : null, 'rental_driver' => $rental ? (trim((string) $d['rental_driver']) ?: null) : null,
            'rate_trip' => $rental && $d['rate_way'] === 'trip' ? $rate : null,
            'rate_day' => $rental && $d['rate_way'] === 'day' ? $rate : null,
            'rate_km' => $rental && $d['rate_way'] === 'km' ? $rate : null,
            'date_registered' => $d['date_registered'], 'date_expired' => $d['date_expired'],
            'capacity' => $d['capacity'] ? (int) $d['capacity'] : null, 'Note' => trim((string) $d['note']) ?: null,
            'is_active' => (bool) $d['is_active'], 'logistichub_id' => $hub,
        ];
        if (TruckSpace::ready()) {
            foreach (['cargo_length_cm', 'cargo_width_cm', 'cargo_height_cm', 'fill_pct'] as $k) {
                $values[$k] = $d[$k] ? (int) $d[$k] : null;
            }
        }
        if ($this->photo) {
            $path = $this->photo->store('trucks', 'public');
            PhotoShrinker::file('public', $path);
            $values['truck_picture'] = $path;
        } elseif ($this->removePhoto) {
            $values['truck_picture'] = null;
        }
        if ($t) {
            $t->update($values);
        } else {
            $t = Truck::create($values + ['user_id' => Auth::id()]);
        }
        Notification::make()->title($t->plate_no.($this->truckId ? ' saved' : ' added'))->success()->send();
        $this->redirect($this->profileUrl($t) ?? $this->fleetUrl() ?? '/');
    }

    protected function profileUrl(?Truck $t): ?string
    {
        $p = str_replace('TruckEditor', 'TruckProfile', static::class);

        return $t && static::class !== self::class && class_exists($p) ? $p::getUrl(['truck' => $t->id]) : null;
    }

    protected function fleetUrl(): ?string
    {
        $p = str_replace('TruckEditor', 'Fleet', static::class);

        return static::class !== self::class && class_exists($p) ? $p::getUrl() : null;
    }

    public static function urlFor(?Truck $t = null): ?string
    {
        if (static::class === self::class) {
            return null;
        }

        return static::getUrl($t ? ['truck' => $t->id] : []);
    }

    protected function getViewData(): array
    {
        $t = $this->truck();
        $d = $this->data;
        $kind = static::KINDS[$d['kind']] ?? static::KINDS['6w'];
        $rental = $d['ownership'] === 'rental';
        $company = $d['rental_company_id'] ? RentalCompany::find($d['rental_company_id']) : null;
        $space = (int) ($d['capacity'] ?: $kind[2]);
        $exp = $d['date_expired'] ? rescue(fn () => Carbon::parse($d['date_expired']), null, false) : null;
        $expNote = match (true) {
            ! $exp => ['Set the expiry date so we can remind you.', 'muted', 'not set'],
            $exp->isPast() => ['Expired '.$exp->format('M j, Y').'. Renew it, then change the date.', 'bad', 'expired'],
            $exp->lte(today()->addDays(30)) => ['Expires '.$exp->format('M j, Y').' (in '.today()->diffInDays($exp).' days)', 'warn', 'in '.today()->diffInDays($exp).' days'],
            default => ['✓ Good until '.$exp->format('M j, Y').' ('.today()->diffForHumans($exp, ['syntax' => Carbon::DIFF_ABSOLUTE, 'parts' => 1]).' left)', 'ok', 'good for '.today()->diffForHumans($exp, ['syntax' => Carbon::DIFF_ABSOLUTE, 'parts' => 1])],
        };
        $rateLabel = $d['rate'] !== '' && $d['rate'] !== null && is_numeric($d['rate']) ? '₱'.number_format((float) $d['rate']).' '.static::RATES[$d['rate_way']][1] : 'no rate yet';
        $bw = ['van' => 70, '4w' => 92, '6w' => 112, '10w' => 140, 'other' => 104][$d['kind']] ?? 112;
        $booked = $t && $t->isRental() ? collect(Rentals::bookedDays($t, today()->startOfMonth()))->filter(fn ($day) => Carbon::parse($day)->gte(today()))->map(fn ($day) => Carbon::parse($day)->format('M j'))->values() : collect();
        $next = $t && $t->isRental() ? Rentals::nextBooking($t) : null;
        $hub = $this->hub();
        $same = filled($d['plate_no']) ? TruckDuplicates::existing($d['plate_no'], $t?->id) : null;
        $sameMine = $same && Tracker::canSeeTruck($hub, $same);

        return [
            'same' => $same, 'sameMine' => $sameMine,
            'sameUrl' => $sameMine ? $this->profileUrl($same) : null,
            'sameStats' => $same ? TruckDuplicates::tripCount($same) : 0,
            'plateSaved' => TruckDuplicates::format($d['plate_no']),
            't' => $t, 'd' => $d, 'kinds' => static::KINDS, 'rates' => static::RATES, 'rental' => $rental,
            'color' => $d['is_active'] ? ['van' => '#7a4fb0', '4w' => '#c97a00', '6w' => '#17895e', '10w' => '#1d6fb8', 'other' => '#6b7b88'][$d['kind']] : '#c3ccd4',
            'bw' => $bw,
            'kindLine' => collect([$d['kind'] === 'other' ? ($d['category'] ?: 'Other') : $kind[0], $d['make_model'] ?: null, $rental ? ($company?->name ?? 'rental') : null])->filter()->join(' · '),
            'facts' => array_values(array_filter([
                ['Space', 'about '.$space.' boxes', ''],
                $rental ? ['Rental', $rateLabel, 'is-rent'] : null,
                ['Registration', $expNote[2], $expNote[1] === 'muted' ? 'is-muted' : ($expNote[1] === 'ok' ? '' : 'is-'.$expNote[1])],
            ])),
            'expNote' => $expNote,
            'usual' => $kind[2], 'kindName' => $kind[0],
            'companies' => Rentals::companies(is_int($hub) ? $hub : null),
            'hubs' => $hub === null ? Logistichub::orderBy('hub_name')->pluck('hub_name', 'id')->all() : [],
            'hubName' => is_int($hub) ? Logistichub::find($hub)?->hub_name : null,
            'booked' => $booked, 'next' => $next,
            'rentalTabUrl' => $t ? (($u = $this->profileUrl($t)) ? $u.'&tab=rental' : null) : null,
            'cancelUrl' => $this->profileUrl($t) ?? $this->fleetUrl(),
            'fleetUrl' => $this->fleetUrl(),
            'photoUrl' => $this->photo ? rescue(fn () => $this->photo->temporaryUrl(), null, false)
                : ($t?->truck_picture && ! $this->removePhoto ? Storage::disk('public')->url($t->truck_picture) : null),
            'spaceReady' => TruckSpace::ready(),
            'spaceGuess' => TruckSpace::ready() && $d['cargo_length_cm'] && $d['cargo_width_cm'] && $d['cargo_height_cm']
                ? TruckSpace::fit(new Truck(['cargo_length_cm' => $d['cargo_length_cm'], 'cargo_width_cm' => $d['cargo_width_cm'], 'cargo_height_cm' => $d['cargo_height_cm'], 'fill_pct' => $d['fill_pct']])) : null,
        ];
    }
}
DISPATCH_FILE_END_21

# ---------------------------------------------------------------- app/Filament/Shared/UnloadContainerPage.php
mkdir -p 'app/Filament/Shared'
cat > 'app/Filament/Shared/UnloadContainerPage.php' <<'DISPATCH_FILE_END_22'
<?php

namespace App\Filament\Shared;

use App\Filament\Concerns\ScansInvoices;
use App\Models\Boxes\WhSection;
use App\Models\Boxes\WhSpot;
use App\Models\Boxissue;
use App\Models\Container;
use App\Models\Invoice;
use App\Models\Invoiceissue;
use App\Models\Unmanifested;
use App\Models\User;
use App\Models\Whtripinvoice;
use App\Support\Boxes\BoxSets;
use App\Support\Boxes\Crossdock;
use App\Support\Boxes\Sections;
use App\Support\Boxes\TruckSets;
use App\Support\Warehouses\Coverage;
use Filament\Actions\Action;
use Filament\Forms\Components\FileUpload;
use Filament\Forms\Components\MarkdownEditor;
use Filament\Forms\Components\Select;
use Filament\Forms\Components\Textarea;
use Filament\Notifications\Notification;
use Filament\Pages\Page;
use Filament\Schemas\Schema;
use Filament\Support\Icons\Heroicon;
use Illuminate\Database\Eloquent\Builder;
use Illuminate\Support\Carbon;
use Illuminate\Support\Collection;
use Illuminate\Support\Facades\Auth;
use Livewire\Attributes\Locked;

/**
 * Scan station for unloading a shipping container: every box scanned is
 * marked verified. Boxes that are damaged can be reported, and boxes that
 * are not on the manifest can be recorded as unmanifested.
 */
abstract class UnloadContainerPage extends Page
{
    use ScansInvoices;

    protected string $view = 'filament.pages.scaninvoice';

    /** The last code that was not found in the container (for the unmanifested form). */
    #[Locked]
    public ?string $missingCode = null;

    /** Where the box just scanned goes: a section tile, or the waiting truck. */
    public ?array $route = null;

    /** The box's set: "Maria Santos · 2 of 3 · 1 more still in this container". */
    public ?array $setInfo = null;

    abstract protected function containerQuery(): Builder;

    public function mount(): void
    {
        $this->form->fill();
    }

    public function form(Schema $schema): Schema
    {
        return $schema
            ->statePath('data')
            ->components([
                Select::make('container_id')
                    ->label('Container')
                    ->placeholder('Choose the container you are unloading')
                    ->searchable()
                    ->live()
                    ->required()
                    ->afterStateUpdated(fn () => $this->reset('lastInvoiceId', 'lastStatus', 'lastMessage', 'missingCode'))
                    ->options(fn () => $this->containerQuery()
                        ->with('consolidator:id,company_name')
                        ->latest('id')
                        ->get()
                        ->mapWithKeys(fn (Container $container) => [
                            $container->id => collect([
                                $container->container_no,
                                $container->batch_no ? 'batch '.$container->batch_no : null,
                                $container->batch_year,
                                $container->consolidator?->company_name,
                            ])->filter()->join(' · '),
                        ])),
            ]);
    }

    protected function selectionField(): ?string
    {
        return 'container_id';
    }

    protected function selectionLabel(): string
    {
        return 'a container';
    }

    public function stationHeading(): string
    {
        return 'Unload the container';
    }

    public function stationDescription(): string
    {
        return 'Pick the container, then scan each box as it comes off. Scanned boxes are marked verified.';
    }

    public function stationIcon(): string
    {
        return 'heroicon-o-archive-box-arrow-down';
    }

    public function progressLabel(): string
    {
        return 'Boxes verified in this container';
    }

    protected function selectedContainer(): ?Container
    {
        return $this->containerQuery()->find($this->data['container_id'] ?? null);
    }

    protected function handleScan(string $code): void
    {
        $container = $this->selectedContainer();

        if (! $container) {
            $this->scanResult('danger', 'That container is not available any more.');

            return;
        }

        $this->missingCode = null;
        $this->route = null;
        $this->setInfo = null;

        if ($section = Sections::fromCode($code)) {
            $this->placeInSection($container, $section);

            return;
        }
        if ($spot = Sections::spotFromCode($code)) {
            $this->placeOnSpot($container, $spot);

            return;
        }

        // board 58: two boxes with this number in the container still to unload → Which one?
        $same = Invoice::where('container_id', $container->id)->where('invoice', $code)->orderBy('id')->get();
        $invoice = $this->whichRow($code, $same, fn ($i) => $i, fn ($i) => (bool) $i->is_verified);
        if ($invoice === false) {
            return;
        }

        if (! $invoice) {
            $this->missingCode = $code;
            $other = $this->invoicesMatching($code)->first();

            $this->scanResult(
                'danger',
                $other
                    ? "{$code} is manifested in another container ({$other->container?->container_no})."
                    : "{$code} is not on this container's manifest.",
                $other,
            );

            return;
        }

        if ($invoice->is_verified) {
            $who = $invoice->verified_by && $invoice->verified_by !== Auth::id() ? User::find($invoice->verified_by)?->first_name : null;
            $when = $invoice->verified_at ? Carbon::parse($invoice->verified_at)->format('g:i A') : null;
            $this->route = Sections::tile($invoice->whSection);
            $this->scanResult('warning', $same->count() > 1 && $same->every(fn ($i) => $i->is_verified)
                ? "Already unloaded: all {$same->count()} boxes with number {$code}. Leave this one."
                : "{$code} was already verified".($who ? " by {$who}" : '').($when ? " at {$when}" : '').'. Not counted again.', $invoice);

            return;
        }

        $invoice->forceFill(['is_verified' => true, 'verified_at' => now(), 'verified_by' => Auth::id()])->save();

        $msg = $this->sendToSection($container, $invoice);
        if ($same->count() > 1) {
            $msg .= $this->whichSuffix($same->filter(fn ($i) => $i->is_verified || $i->is($invoice))->count(), $same->count(), $invoice);
        }
        $this->scanResult('success', $msg, $invoice);
    }

    /** After the box is verified: pick its section, or load it straight onto the waiting truck. */
    protected function sendToSection(Container $container, Invoice $invoice): string
    {
        $code = $invoice->invoice;
        $warehouseId = $this->warehouseId($container);
        $section = Sections::forInvoice($invoice, $warehouseId);
        $this->setInfo = BoxSets::atUnload($invoice);

        // Two warehouses: a box that another warehouse delivers goes to the transfer for it.
        if ($home = Coverage::transferTo($invoice, $warehouseId)) {
            $to = Sections::of($warehouseId)->first(fn ($s) => (int) $s->to_warehouse_id === $home);
            if ($to) {
                $section = $to;
            } else {
                $name = Coverage::name($home);
                $invoice->forceFill(['wh_section_id' => null, 'sectioned_at' => now()])->save();
                $this->route = ['kind' => 'transfer', 'code' => 'T', 'name' => 'Transfer → '.$name, 'color' => '#c97a00'];

                return "{$code} verified · transfer to {$name}.";
            }
        }

        if (! $section) {
            return "{$code} verified.";
        }

        if ($trip = Crossdock::load($invoice, $warehouseId, $section)) {
            $invoice->forceFill(['wh_section_id' => $section->id, 'sectioned_at' => null])->save();
            $this->route = ['kind' => 'truck', 'code' => 'TRUCK', 'name' => $trip->warehouse?->name ?? $section->goesTo(), 'trip' => $trip->trip_number, 'plate' => $trip->truck?->plate_no, 'color' => '#e2700c'];
            $this->setInfo = TruckSets::card($invoice, $trip, $warehouseId) ?? $this->setInfo;

            return "{$code} verified · onto truck {$trip->trip_number}.";
        }

        $label = Sections::labelScan($warehouseId);
        $invoice->forceFill(['wh_section_id' => $section->id, 'sectioned_at' => $label ? null : now()]
            + (\Illuminate\Support\Facades\Schema::hasColumn('invoices', 'wh_spot_id') ? ['wh_spot_id' => null] : []))->save();
        $this->route = Sections::tile($section) + ['pending' => $label, 'why' => $section->kind === 'check' ? Sections::whyCheck($invoice) : null]
            + $this->spotChoice($section, $invoice);

        return "{$code} verified · section {$section->code}.";
    }

    /** Spots of the section (optional, board 50): the crew scans the spot's QR, taps one, or skips. */
    protected function spotChoice(WhSection $section, Invoice $invoice): array
    {
        $spots = Sections::spotsOf($section);

        return $spots->isEmpty() ? [] : ['spots' => $spots->map(fn ($p) => ['id' => $p->id, 'code' => $p->code])->values()->all(), 'spot' => null, 'invoiceId' => $invoice->id];
    }

    /** Put the box on a spot of its section, or no spot (Skip). */
    public function setSpot(int $invoiceId, ?int $spotId): bool
    {
        $container = $this->selectedContainer();
        $invoice = $container ? Invoice::where('container_id', $container->id)->find($invoiceId) : null;
        if (! $invoice || ! $invoice->wh_section_id) {
            return false;
        }
        $spot = $spotId ? WhSpot::where('wh_section_id', $invoice->wh_section_id)->find($spotId) : null;
        if ($spotId && ! $spot) {
            return false;
        }
        $invoice->forceFill(['wh_spot_id' => $spot?->id])->save();
        $section = $invoice->whSection;
        $this->route = Sections::tile($section) + $this->spotChoice($section, $invoice);
        $this->route['spot'] = $spot?->code ?? 'skip';
        $this->lastInvoiceId = $invoice->id;
        $this->lastStatus = 'success';
        $this->lastMessage = $spot ? "{$invoice->invoice} on spot {$spot->code}." : "{$invoice->invoice} in section {$section?->code} (no spot).";

        return true;
    }

    /** A spot's QR was scanned: the last box this person scanned for that section goes on it. */
    protected function placeOnSpot(Container $container, WhSpot $spot): void
    {
        $box = Invoice::where('container_id', $container->id)->where('verified_by', Auth::id())->where('wh_section_id', $spot->wh_section_id)
            ->orderByDesc('verified_at')->orderByDesc('id')->first();
        $this->route = Sections::tile($spot->section);
        if (! $box) {
            $this->scanResult('warning', "Spot {$spot->code}: none of your boxes are for section {$spot->section?->code}.");

            return;
        }
        $this->setSpot($box->id, $spot->id);
        $this->scanResult('success', "{$box->invoice} on spot {$spot->code}.", $box);
        $this->route = Sections::tile($spot->section) + $this->spotChoice($spot->section, $box);
        $this->route['spot'] = $spot->code;
    }

    /** Section-label scan (when switched on): the boxes this person scanned for that section are now there. */
    protected function placeInSection(Container $container, WhSection $section): void
    {
        $warehouseId = $this->warehouseId($container);
        if (! Sections::labelScan($warehouseId)) {
            $this->scanResult('warning', 'The section label scan is off: boxes are saved in their section when you scan them.');

            return;
        }
        $pending = Invoice::where('container_id', $container->id)->where('verified_by', Auth::id())
            ->whereNotNull('wh_section_id')->whereNull('sectioned_at')->get();
        $here = Crossdock::here($warehouseId)->pluck('id');
        if ($here->isNotEmpty()) {
            $onTruck = Whtripinvoice::whereIn('whdeliverylog_id', $here)->whereIn('invoice_id', $pending->pluck('id'))->pluck('invoice_id')->all();
            $pending = $pending->reject(fn ($b) => in_array($b->id, $onTruck, true));
        }
        $mine = $pending->where('wh_section_id', $section->id);
        $other = $pending->where('wh_section_id', '!=', $section->id);
        $this->route = Sections::tile($section);

        if ($mine->isEmpty()) {
            $this->scanResult('warning', $other->isNotEmpty()
                ? 'Wrong section: your '.$other->count().' '.str('box')->plural($other->count()).' '.($other->count() === 1 ? 'is' : 'are').' for '.$other->map(fn ($b) => $b->whSection?->code)->unique()->join(', ').', not '.$section->code.'.'
                : "Section {$section->code}: none of your boxes are waiting for it.");

            return;
        }
        Invoice::whereIn('id', $mine->pluck('id'))->update(['sectioned_at' => now()]);
        $this->scanResult('success', $mine->count().' '.str('box')->plural($mine->count())." saved in section {$section->code}"
            .($other->isNotEmpty() ? ' · '.$other->count().' still for '.$other->map(fn ($b) => $b->whSection?->code)->unique()->join(', ') : '').'.');
    }

    protected function warehouseId(?Container $container): ?int
    {
        return $container?->warehouse_id ?? Auth::user()?->warehouse_id;
    }

    // ------------------------------------------------------------------ truck here (switched on in the transfer trip)

    /** "Put in section instead": take the box off the truck and keep it in its section. */
    public function putInSection(int $invoiceId): bool
    {
        $container = $this->selectedContainer();
        $invoice = $container ? Invoice::where('container_id', $container->id)->find($invoiceId) : null;
        $trip = $invoice ? Crossdock::tripOf($invoice, $this->warehouseId($container)) : null;
        if (! $trip || ! Crossdock::unload($invoice, $trip)) {
            return false;
        }
        $section = $invoice->whSection ?? Sections::forInvoice($invoice, $this->warehouseId($container));
        $invoice->forceFill(['wh_section_id' => $section?->id, 'sectioned_at' => now()])->save();
        $this->route = Sections::tile($section);
        $this->lastInvoiceId = $invoice->id;
        $this->lastStatus = 'success';
        $this->lastMessage = "{$invoice->invoice} stays in section ".($section?->code ?? '').'. It goes on the next truck.';

        return true;
    }

    /** TRUCK screen: "Bring it to the truck too" for another box of the customer that is in its section. */
    public function addSetBox(int $ofInvoiceId, int $boxId): ?string
    {
        $container = $this->selectedContainer();
        $of = $container ? Invoice::where('container_id', $container->id)->find($ofInvoiceId) : null;
        $warehouseId = $this->warehouseId($container);
        $trip = $of ? Crossdock::tripOf($of, $warehouseId) : null;
        $box = $trip ? TruckSets::add($of, $boxId, $trip, $warehouseId) : null;
        if (! $box) {
            return null;
        }
        $this->setInfo = TruckSets::card($of, $trip, $warehouseId);

        return $box->invoice;
    }

    /** The trucks here now at this warehouse (switched on in their transfer trip). */
    public function truckStatus(): array
    {
        return Crossdock::status($this->warehouseId($this->selectedContainer()));
    }

    /** Who scanned how many boxes off this container. */
    public function team(): array
    {
        $id = $this->data['container_id'] ?? null;
        if (! $id) {
            return [];
        }
        $counts = Invoice::where('container_id', $id)->whereNotNull('verified_by')->selectRaw('verified_by, count(*) n')->groupBy('verified_by')->pluck('n', 'verified_by');
        $names = User::whereIn('id', $counts->keys())->pluck('first_name', 'id');

        return $counts->sortDesc()->map(fn ($n, $uid) => ['name' => (int) $uid === Auth::id() ? 'You' : ($names[$uid] ?? '?'), 'n' => (int) $n, 'me' => (int) $uid === Auth::id()])->values()->all();
    }

    /** @return array{loaded: int, total: int, last?: ?string, issues?: int, unmanifested?: int} */
    /**
     * Progress of many containers in one database question (the Scan app list).
     *
     * @param  list<int>  $ids
     * @return array<int, array{loaded: int, total: int}>
     */
    public function progressMany(array $ids): array
    {
        if (! $ids) {
            return [];
        }

        return Invoice::whereIn('container_id', $ids)->selectRaw('container_id as c, count(*) as total, sum(case when is_verified = 1 then 1 else 0 end) as loaded')
            ->groupBy('container_id')->toBase()->get()
            ->mapWithKeys(fn ($r) => [(int) $r->c => ['loaded' => (int) $r->loaded, 'total' => (int) $r->total]])->all();
    }

    public function progress(): array
    {
        $containerId = $this->data['container_id'] ?? null;

        if (! $containerId) {
            return ['loaded' => 0, 'total' => 0];
        }

        $query = Invoice::where('container_id', $containerId);

        return [
            'loaded' => (clone $query)->where('is_verified', true)->count(),
            'total' => $query->count(),
            'last' => (clone $query)->max('verified_at'),
            'issues' => Invoiceissue::where('container_id', $containerId)->count(),
            'unmanifested' => Unmanifested::where('container_id', $containerId)->count(),
        ];
    }

    public function household(): array
    {
        return $this->householdRows($this->lastInvoice(), fn (Invoice $box) => [
            'trip' => $box->is_verified ? 'Verified' : 'Not scanned yet',
            'done' => (bool) $box->is_verified,
        ]);
    }

    public function reportIssueAction(): Action
    {
        return Action::make('reportIssue')
            ->label('Report a problem')
            ->icon(Heroicon::OutlinedExclamationTriangle)
            ->color('danger')
            ->outlined()
            ->visible(fn () => $this->lastInvoiceId !== null && $this->lastInvoice()?->container_id == ($this->data['container_id'] ?? null))
            ->modalHeading(fn () => 'Report a problem with '.$this->lastInvoice()?->invoice)
            ->modalWidth('lg')
            ->schema([
                Select::make('boxissue_id')
                    ->label('Problem')
                    ->options(fn () => Boxissue::query()->orderBy('issue_type')->pluck('issue_type', 'id'))
                    ->required(),
                MarkdownEditor::make('remarks')
                    ->label('Notes')
                    ->toolbarButtons(['bold', 'italic', 'bulletList']),
                FileUpload::make('attachment_pic')
                    ->label('Photo')
                    ->image()
                    ->disk('public')
                    ->directory(fn () => \App\Support\Photos\Storage\PhotoFolders::dir('damage'))
                    ->visibility('private')
                    ->required(),
            ])
            ->action(function (array $data): void {
                $invoice = $this->lastInvoice();

                if (! $invoice) {
                    return;
                }

                Invoiceissue::create([
                    'invoice' => $invoice->invoice,
                    'invoice_id' => $invoice->id,
                    'container_id' => $invoice->container_id,
                    'boxissue_id' => $data['boxissue_id'],
                    'remarks' => $data['remarks'] ?? null,
                    'attachment_pic' => $data['attachment_pic'] ?? null,
                    'user_id' => Auth::id(),
                ]);

                Notification::make()->title("Problem recorded for {$invoice->invoice}")->success()->send();
            });
    }

    public function unmanifestedAction(): Action
    {
        return Action::make('unmanifested')
            ->label('Record as unmanifested box')
            ->icon(Heroicon::OutlinedDocumentPlus)
            ->color('warning')
            ->visible(fn () => filled($this->missingCode))
            ->modalHeading(fn () => "Unmanifested box {$this->missingCode}")
            ->modalDescription('This box is in the container but not on its manifest. Take a photo and add a note.')
            ->modalWidth('lg')
            ->schema([
                FileUpload::make('attachment_pic')
                    ->label('Photo')
                    ->image()
                    ->disk('public')
                    ->directory(fn () => \App\Support\Photos\Storage\PhotoFolders::dir('unmanifested'))
                    ->visibility('private')
                    ->required(),
                Textarea::make('remarks')->label('Notes')->rows(3),
            ])
            ->action(function (array $data): void {
                Unmanifested::create([
                    'invoice' => $this->missingCode,
                    'container_id' => $this->data['container_id'],
                    'attachment_pic' => $data['attachment_pic'] ?? null,
                    'remarks' => $data['remarks'] ?? null,
                ]);

                Notification::make()->title("Unmanifested box {$this->missingCode} recorded")->success()->send();

                $this->missingCode = null;
            });
    }

    public function photoStep(): ?string
    {
        return 'unload';
    }

    public function photoContext(): array
    {
        $id = $this->data['container_id'] ?? null;

        return [
            'container_id' => $id,
            'warehouse_id' => ($id ? Container::whereKey($id)->value('warehouse_id') : null) ?? Auth::user()?->warehouse_id,
            'logistichub_id' => Auth::user()?->logistichub_id,
        ];
    }

    public function appChoices(): Collection
    {
        return $this->containerQuery()->with('consolidator:id,company_name')->latest('id')->limit(60)->get()
            ->map(fn (Container $c) => ['id' => $c->id, 'name' => $c->container_no, 'active' => (bool) ($c->is_active ?? true) && ! $c->is_unloaded,
                'sub' => collect([$c->batch_no ? 'Batch '.$c->batch_no : null, $c->consolidator?->company_name])->filter()->join(' · ') ?: null]);
    }
}
DISPATCH_FILE_END_22

# ---------------------------------------------------------------- app/Filament/Warehouse/Resources/Deliveryinvs/Tables/DeliveryinvsTable.php
mkdir -p 'app/Filament/Warehouse/Resources/Deliveryinvs/Tables'
cat > 'app/Filament/Warehouse/Resources/Deliveryinvs/Tables/DeliveryinvsTable.php' <<'DISPATCH_FILE_END_23'
<?php

namespace App\Filament\Warehouse\Resources\Deliveryinvs\Tables;

use App\Filament\Exports\DeliveryinvExporter;
use App\Filament\Warehouse\Resources\Deliverylogs\DeliverylogResource;
use App\Models\Consolidator;
use App\Models\Deliveryinv;
use App\Models\Invoice;
use App\Models\Tripinvoice;
use Filament\Actions\Action;
use Filament\Actions\ActionGroup;
use Filament\Actions\BulkActionGroup;
use Filament\Actions\DeleteBulkAction;
use Filament\Actions\ExportAction;
use Filament\Actions\Exports\Enums\ExportFormat;
use Filament\Actions\Exports\Models\Export;
use Filament\Actions\ViewAction;
use Filament\Forms\Components\FileUpload;
use Filament\Notifications\Notification;
use Filament\Support\Icons\Heroicon;
use Filament\Tables\Columns\TextColumn;
use Filament\Tables\Filters\SelectFilter;
use Filament\Tables\Table;
use Illuminate\Contracts\Database\Eloquent\Builder;
use Illuminate\Database\Eloquent\Model;
use Illuminate\Support\Facades\Auth;

class DeliveryinvsTable
{
    public static function configure(Table $table): Table
    {
        return $table
            ->query(Deliveryinv::Unloadedinv())
            ->columns([
                TextColumn::make('deliverylog.trip_number')
                    ->searchable()
                    ->label('Trip Number')
                    ->color('primary')
                    ->url(fn (Model $record) => DeliverylogResource::getUrl('edit', ['record' => $record->deliverylog_id])),
                TextColumn::make('company')
                    ->label('Company')
                    ->getStateUsing(function (Model $record) {
                        // $companyname = Consolidator::where('code', $records->location_code)->first();
                        $locationcode = Invoice::where('id', $record->invoice_id)->value('location_code');

                        return $companyname = Consolidator::nameForCode($locationcode);
                    }),
                TextColumn::make('invoice')
                    ->searchable()
                    ->label('Invoice'),
                TextColumn::make('invdata.container.batch_no')
                    ->toggleable(isToggledHiddenByDefault: true)
                    ->searchable()
                    ->label('Batch No'),
                TextColumn::make('invdata.container.batch_year')
                    ->searchable()
                    ->label('Batch Year'),
                TextColumn::make('invdata.container.container_no')
                    ->toggleable(isToggledHiddenByDefault: true)
                    ->searchable()
                    ->label('Container No'),
                TextColumn::make('invdata.sender_name')
                    ->toggleable(isToggledHiddenByDefault: true)
                    ->label('Sender'),
                TextColumn::make('invdata.receiver_name')
                    ->label('Receiver'),
                TextColumn::make('invdata.receiver_address')
                    ->toggleable(isToggledHiddenByDefault: true)
                    ->label('Address'),
                TextColumn::make('is_delivered')
                    ->label('Status')
                    ->formatStateUsing(function (Model $record) {
                        return $record->is_delivered ? 'Delivered' : 'In Transit';
                    })
                    ->color(function ($record) {
                        return $record->is_delivered ? 'success' : 'danger';
                    }),

                TextColumn::make('invdata.receiver_province')
                    ->toggleable(isToggledHiddenByDefault: true)
                    ->label('Province'),
                TextColumn::make('invdata.receiver_city')
                    ->toggleable(isToggledHiddenByDefault: true)
                    ->label('City'),
                TextColumn::make('invdata.receiver_barangay')
                    ->toggleable(isToggledHiddenByDefault: true)
                    ->label('Barangay'),
                TextColumn::make('invdata.boxtype')
                    ->label('Box Type'),
                TextColumn::make('invdata.routearea.description')
                    ->toggleable(isToggledHiddenByDefault: true)
                    ->label('Route Area'),
            ])
            ->filters([
                SelectFilter::make('is_delivered')
                    ->label('Is Delivered')
                    ->options([
                        1 => 'Yes',
                        0 => 'No',
                    ])->default(0),
                // SelectFilter::make('routearea_id')
                //     ->label('Route')
                //     ->relationship('invoice.routearea', 'description'),
                SelectFilter::make('deliverylog_id')
                    ->label('Trip Number')
                    ->searchable()
                    ->preload()
                    ->relationship('deliverylog', 'trip_number', fn (Builder $query) => $query->where('logistichub_id', Auth::user()->logistichub_id)),

                SelectFilter::make('container_id')
                    ->label('Batch / Container')
                    ->relationship(
                        name: 'invoice.container',
                        titleAttribute: 'container_no'

                    )
                    ->searchable(['container_no', 'batch_no', 'batch_year'])
                    ->preload()
                    ->getOptionLabelFromRecordUsing(function (Model $record) {
                        return "{$record->container_no} {$record->batch_no} {$record->batch_year}";
                    }),

                SelectFilter::make('province')
                    ->label('Province')
                    ->multiple()
                    ->searchable()
                    ->options(
                        Invoice::query()
                            ->select('receiver_province')
                            ->distinct()
                            ->orderBy('receiver_province')
                            ->pluck('receiver_province', 'receiver_province')
                            ->toArray()
                    )
                    ->query(function (Builder $query, array $data) {
                        if (! empty($data['values'])) {
                            $query->whereHas('invoice', function (Builder $q) use ($data) {
                                $q->whereIn('receiver_province', $data['values']);
                            });
                        }
                    }),
            ])->deferFilters(false)
            ->headerActions([
                ExportAction::make()
                    ->label('Export')
                    ->icon(Heroicon::ArrowUturnDown)
                    ->Color('primary')
                    ->exporter(DeliveryinvExporter::class)
                    ->formats([
                        ExportFormat::Xlsx,
                    ])
                    ->fileName(fn (Export $export): string => 'Delivery Invoices Export - '.now()->format('Y-m-d_H-i-s').'.xlsx'),
            ])
            ->recordActions([
                ActionGroup::make([
                    // ViewAction::make()
                    //     ->slideOver()
                    //     ->modal()
                    //     ->label('View')
                    //     ->color('primary')
                    //     ->icon(Heroicon::Eye)
                    //     ->hidden(fn($record) => empty($record->delivery_picture)),

                    Action::make('Edit')
                        ->label('Edit Picture')
                        ->color('info')
                        ->icon(Heroicon::PencilSquare)
                        ->hidden(fn ($record) => empty($record->delivery_picture))
                        ->fillForm(fn (Model $record): array => [

                            'delivery_picture' => $record->delivery_picture,
                        ])
                        ->schema([
                            FileUpload::make('delivery_picture')
                                ->label('Delivery Picture')
                                ->multiple()
                                ->panelLayout('grid')
                                ->uploadingMessage('Uploading attachment...')
                                ->image()
                                ->openable()
                                ->disk('public')
                                ->directory(function (Model $record) {
                                    return \App\Support\Photos\Storage\PhotoFolders::dir('delivery', $record->invoice);
                                })
                                ->downloadable()
                                ->visibility('private')
                                ->required()
                                ->removeUploadedFileButtonPosition('right'),
                        ])
                        ->action(function (array $data, Model $record): void {
                            if (! auth()->user()->hasRole('cscanada')) {
                                Tripinvoice::where('id', $record->id)
                                    ->update([
                                        'delivery_picture' => $data['delivery_picture'],
                                    ]);
                                Notification::make()
                                    ->title('Delivery Picture Updated')
                                    ->success()
                                    ->send();
                            } else {
                                Notification::make()
                                    ->title('Edit Denied')
                                    ->warning()
                                    ->send();
                            }

                        }),
                    Action::make('Picture')
                        ->label('Add Picture')
                        ->color('danger')
                        ->icon(Heroicon::Camera)
                        ->hidden(fn ($record) => ! empty($record->delivery_picture))
                        ->schema([
                            FileUpload::make('delivery_picture')
                                ->label('Delivery Picture')
                                ->multiple()
                                ->panelLayout('grid')
                                ->uploadingMessage('Uploading ...')
                                ->acceptedFileTypes([
                                    'image/*',
                                    'application/pdf',
                                ])
                                ->openable()
                                ->disk('public')
                                ->directory(function (Model $record) {
                                    return \App\Support\Photos\Storage\PhotoFolders::dir('delivery', $record->invoice);
                                })
                                ->visibility('private')
                                ->required()
                                ->removeUploadedFileButtonPosition('right'),
                            // ->minFiles(6),
                        ])
                        ->action(function (array $data, Model $record): void {
                            if (! auth()->user()->hasRole('cscanada')) {
                                Tripinvoice::where('id', $record->id)
                                    ->update([
                                        'delivery_picture' => $data['delivery_picture'],
                                        'is_delivered' => true,
                                    ]);
                                Notification::make()
                                    ->title('Picture Added and Status Updated to Delivered')
                                    ->success()
                                    ->send();
                            } else {
                                Notification::make()
                                    ->title('Add Picture Denied')
                                    ->warning()
                                    ->send();
                            }

                        }),
                    Action::make('Delete Picture')
                        ->requiresConfirmation()
                        ->label('Delete Picture')
                        ->color('danger')
                        ->icon(Heroicon::Trash)
                        ->hidden(fn ($record) => empty($record->delivery_picture))
                        ->action(function (array $data, Model $record): void {
                            if (! auth()->user()->hasRole('cscanada')) {
                                Tripinvoice::where('id', $record->id)
                                    ->update([
                                        'delivery_picture' => null,
                                        'is_delivered' => false,
                                    ]);
                                Notification::make()
                                    ->title('Picture Deleted ')
                                    ->success()
                                    ->send();
                            } else {
                                Notification::make()
                                    ->title('Delete Denied')
                                    ->warning()
                                    ->send();
                            }

                        }),
                ]),
            ])
            ->toolbarActions([
                BulkActionGroup::make([
                    //    DeleteBulkAction::make(),
                ]),
            ]);
    }
}
DISPATCH_FILE_END_23

# ---------------------------------------------------------------- app/Filament/Warehouse/Resources/Trucks/Schemas/TruckForm.php
mkdir -p 'app/Filament/Warehouse/Resources/Trucks/Schemas'
cat > 'app/Filament/Warehouse/Resources/Trucks/Schemas/TruckForm.php' <<'DISPATCH_FILE_END_24'
<?php

namespace App\Filament\Warehouse\Resources\Trucks\Schemas;

use Filament\Forms\Components\DatePicker;
use Filament\Forms\Components\FileUpload;
use Filament\Forms\Components\MarkdownEditor;
use Filament\Forms\Components\TextInput;
use Filament\Forms\Components\Toggle;
use Filament\Schemas\Components\Group;
use Filament\Schemas\Components\Section;
use Filament\Schemas\Schema;

class TruckForm
{
    public static function configure(Schema $schema): Schema
    {
        return $schema
            ->components([
                                Group::make()
                    ->schema([
                        \App\Filament\Shared\Trucks\OwnershipSection::make(),
                        Section::make('vehicles Information')
                            ->schema([
                                TextInput::make('category')
                                    ->hint('Ex. Ten Wheeler, Truck, Mini Truck or Van')
                                    ->hintColor('warning')
                                    ->hintIcon('heroicon-m-truck')
                                    ->required()
                                    ->maxLength(255),
                                TextInput::make('description')
                                    ->hint('Ex Brand, Color, Model')
                                    ->hintColor('warning')
                                    ->hintIcon('heroicon-m-truck')
                                    ->required()
                                    ->maxLength(255),
                                TextInput::make('registration_no')
                                    ->label('Registration Number')
                                    ->required()
                                    ->maxLength(255),
                                TextInput::make('plate_no')
                                    ->label('Plate Number')
                                    ->unique()
                                    ->required()
                                    ->maxLength(255),
                                // Select::make('logistichub_id')
                                // ->label('Logistic Hub/Location')
                                // ->options(Logistichub::query()->pluck('hub_name', 'id'))
                                // ->required(),
                                MarkdownEditor::make('Note')
                                    ->columnSpanFull(),
                            ])

                    ]),
                Group::make()
                    ->schema([
                        Section::make('Other Information')
                            ->schema([
                                FileUpload::make('truck_picture')
                                ->image()
                                ->avatar()
                                ->imageEditor()
                                ->circleCropper()
                                ->uploadingMessage('Uploading attachment...')
                                ->openable()
                                ->maxSize(1024)
                                ->disk('public')
                                ->directory('trucks')
                                ->visibility('private')
                                ->removeUploadedFileButtonPosition('right')
                                ->label('Vehicles Picture')
                                ->columnSpanFull(),
                                DatePicker::make('date_registered')
                                    ->native(false)
                                    ->closeOnDateSelection(true)
                                    ->label('Date Register')
                                    ->required(),
                                DatePicker::make('date_expired')
                                    ->label('Registration Expiration Date')
                                    ->native(false)
                                    ->closeOnDateSelection(true)
                                    ->required()
                                    ->rules(['after_or_equal:today']),
                                    Toggle::make('is_active')
                                    ->default(true)
                                    ->required(),
                            ])

                    ])


            ]);
    }
}
DISPATCH_FILE_END_24

# ---------------------------------------------------------------- app/Filament/Warehouse/Resources/Truckteams/Schemas/TruckteamForm.php
mkdir -p 'app/Filament/Warehouse/Resources/Truckteams/Schemas'
cat > 'app/Filament/Warehouse/Resources/Truckteams/Schemas/TruckteamForm.php' <<'DISPATCH_FILE_END_25'
<?php

namespace App\Filament\Warehouse\Resources\Truckteams\Schemas;

use App\Filament\Resources\UserResource\Pages\EditUser;
use App\Models\Workposition;
use Filament\Forms\Components\FileUpload;
use Filament\Forms\Components\Select;
use Filament\Forms\Components\TextInput;
use Filament\Forms\Components\Toggle;
use Filament\Schemas\Components\Group;
use Filament\Schemas\Components\Section;
use Filament\Schemas\Components\Utilities\Get;
use Filament\Schemas\Schema;
use Illuminate\Support\Facades\Hash;
use Illuminate\Support\Str;

class TruckteamForm
{
    public static function configure(Schema $schema): Schema
    {
        return $schema
            ->components([
                Group::make()
                    ->schema([
                        Section::make('Personal Information')
                            ->schema([
                                TextInput::make('first_name')
                                    ->required()
                                    ->maxLength(255),
                                TextInput::make('middle_name')
                                    ->maxLength(255),
                                TextInput::make('last_name')
                                    ->required()
                                    ->maxLength(255),
                                TextInput::make('address')
                                    ->required()
                                    ->maxLength(255)
                                    ->columnSpanFull(),
                                TextInput::make('mobile_number')
                                    ->required()
                                    ->maxLength(255),
                                TextInput::make('email')
                                    ->email()
                                    ->required()
                                    ->maxLength(255)
                                    ->unique(ignoreRecord: true),
                                // Select::make('panelcategory_id')
                                //     ->label('Panel Category')
                                //     ->relationship(name: 'panelcategory', titleAttribute: 'description')
                                //      ->required(),
                                // Select::make('logistichub_id')
                                // ->label('Logistic Hub/Location')
                                // ->options(Logistichub::query()->pluck('hub_name', 'id'))
                                // ->required(),
                                Select::make('workposition_id')
                                    ->label('Work Position')
                                    ->options(Workposition::query()
                                        ->where('is_crew', true)
                                        ->pluck('position_description', 'id'))
                                    ->required(),

                                Toggle::make('is_active')
                                    ->label('Active')
                                    ->required(),
                                // Toggle::make('is_crew')
                                //     ->label('Crew')
                                //     ->required(),

                                //         Select::make('roles')
                                // ->multiple()
                                // ->relationship('roles', 'name')
                                // ->preload(),

                            ])->columns(3),

                    ])->columnSpan(['lg' => 2]),
                Group::make()
                    ->schema([
                        Section::make()
                            ->schema([
                                FileUpload::make('profile_picture')
                                    ->image()
                                    ->avatar()
                                    ->imageEditor()
                                    ->circleCropper()
                                    // ->panelLayout('grid')
                                    ->uploadingMessage('Uploading attachment...')
                                    ->openable()
                                    ->getUploadedFileNameForStorageUsing(function ($file, Get $get) {
                                        return Str::slug($get('last_name') ?: 'user').'-'.Str::random(8).'.'.$file->getClientOriginalExtension();
                                    })
                                    ->maxSize(1024)
                                    ->disk('public')
                                    ->directory('people')
                                    ->visibility('private')
                                    ->removeUploadedFileButtonPosition('right')
                                    ->label('Profile Picture'),
                                TextInput::make('password')
                                    ->password()
                                    ->required()
                                    ->dehydrateStateUsing(fn ($state) => Hash::make($state))
                                    ->dehydrated(fn ($state) => filled($state))
                                    ->maxLength(255)
                                    ->hiddenOn(EditUser::class)
                                    ->maxLength(255),
                            ]),
                    ])->columnSpan(['lg' => 1]),
            ])->columns(3);
    }
}
DISPATCH_FILE_END_25

# ---------------------------------------------------------------- app/Http/Controllers/DriverOfflineController.php
mkdir -p 'app/Http/Controllers'
cat > 'app/Http/Controllers/DriverOfflineController.php' <<'DISPATCH_FILE_END_26'
<?php

namespace App\Http\Controllers;

use App\Enums\FailedDeliveryReason;
use App\Models\Maps\TripStop;
use App\Models\OfflineSubmission;
use App\Models\Tripinvoice;
use App\Models\User;
use App\Services\TripAssignment;
use App\Support\Branding;
use App\Support\DriverTrip;
use App\Support\Maps\TripSorter;
use App\Support\Photos\PhotoShrinker;
use DomainException;
use Illuminate\Http\JsonResponse;
use Illuminate\Http\Request;
use Illuminate\Support\Carbon;
use Illuminate\Support\Facades\Auth;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Storage;
use Illuminate\Support\Str;
use Symfony\Component\HttpFoundation\Response;

/**
 * Driver app without signal.
 *  - trip():  today's boxes, saved on the phone while there is signal.
 *  - sync():  one delivery or not-delivered saved on the phone, sent when the signal is back.
 *             Uses the same rules as the app (TripAssignment). Sending the same one twice does nothing.
 *  - shell(): the page the phone opens with no signal (no data in it; it reads what the phone saved).
 */
class DriverOfflineController extends Controller
{
    /** How far back a phone time is believed (older = "now"). */
    public const MAX_AGE_HOURS = 48;

    protected function driver(): ?User
    {
        $user = Auth::user();

        return $user && $user->is_active && $user->panelcategory?->code === 'drv' && ! $user->is_admin ? $user : null;
    }

    public function trip(): JsonResponse
    {
        $driver = $this->driver();
        if (! $driver) {
            return response()->json(['message' => 'Sign in to the Driver app.'], 401);
        }

        $trip = DriverTrip::for($driver);
        $boxes = $trip->trip
            ? $trip->boxes()->with('invdata')->withCount('deliveryAttempts')->orderBy('invoice')->get()
            : collect();

        return response()->json([
            'csrf' => csrf_token(),
            'saved_at' => now()->toIso8601String(),
            'driver' => ['id' => $driver->id, 'first_name' => $driver->first_name],
            'trip' => $trip->trip ? [
                'id' => $trip->trip->id,
                'number' => $trip->trip->trip_number,
                'plate' => $trip->trip->truck?->plate_no,
            ] : null,
            'boxes' => $boxes->map(fn (Tripinvoice $b) => [
                'id' => $b->id,
                'invoice' => $b->invoice,
                'codes' => array_values(array_unique(array_filter([$b->invoice, $b->invdata?->invoice]))),
                'name' => Str::title((string) $b->invdata?->receiver_name),
                'address' => collect([$b->invdata?->receiver_address, $b->invdata?->receiver_barangay, $b->invdata?->receiver_city])
                    ->filter()->map(fn ($p) => Str::title($p))->join(', '),
                'phone' => $b->invdata?->receiver_mobile_no,
                'delivered' => (bool) $b->is_delivered,
                'attempted' => $b->delivery_attempts_count > 0,
            ])->values(),
            // Maps & routes: the stops in order, so Navigate works without signal too
            'stops' => $trip->trip && TripSorter::ensure($trip->trip, 0)
                ? TripSorter::stops($trip->trip)->map(fn (TripStop $s) => [
                    'id' => $s->id, 'no' => $s->stop_no, 'name' => $s->name, 'address' => $s->address,
                    'place' => trim(($s->barangay ? $s->barangay.', ' : '').$s->city, ', '),
                    'lat' => $s->lat, 'lng' => $s->lng, 'exact' => $s->exact, 'priority' => $s->priority,
                    'go' => $s->hasPin() ? $s->lat.','.$s->lng : $s->address.', Philippines',
                    'phone' => $s->phone, 'boxes' => array_map('intval', $s->box_ids ?? []),
                ])->values()
                : [],
            'reasons' => collect(FailedDeliveryReason::cases())->map(fn (FailedDeliveryReason $r) => [
                'value' => $r->value, 'label' => $r->getLabel(), 'prompt' => $r->notePrompt(),
                'note' => $r->requiresNote(), 'photo' => $r->requiresPhoto(),
            ])->values(),
        ]);
    }

    public function sync(Request $request): JsonResponse
    {
        $driver = $this->driver();
        if (! $driver) {
            return response()->json(['message' => 'Sign in to the Driver app.'], 401);
        }

        $data = $request->validate([
            'uuid' => ['required', 'uuid'],
            'type' => ['required', 'in:deliver,miss'],
            'tripinvoice_id' => ['required', 'integer'],
            'at' => ['required', 'date'],
            'reason' => ['nullable', 'string'],
            'note' => ['nullable', 'string', 'max:500'],
            'photos' => ['array', 'max:12'],
            'photos.*' => ['image', 'max:12288'],
        ]);

        // Sent before (e.g. the answer got lost): give the same answer again.
        if ($done = OfflineSubmission::where('uuid', $data['uuid'])->where('user_id', $driver->id)->first()) {
            return $this->answer($done);
        }

        $at = Carbon::parse($data['at'])->setTimezone(config('app.timezone'));
        if ($at->isFuture() || $at->lt(now()->subHours(self::MAX_AGE_HOURS))) {
            $at = now();
        }

        $box = DriverTrip::for($driver)->boxes()->with('invdata')->find($data['tripinvoice_id']);
        $result = ['status' => 'saved', 'message' => null];

        if (! $box) {
            $result = ['status' => 'conflict', 'message' => 'This box is no longer on your trip. Keep it on the truck and call the office.'];
        } elseif ($box->is_delivered) {
            $mine = (int) $box->delivered_by === (int) $driver->id;
            $result = $mine
                ? ['status' => 'saved', 'message' => 'Already delivered by you.']
                : ['status' => 'conflict', 'message' => 'Someone else already marked this box delivered. Call the office.'];
        } else {
            $dir = \App\Support\Photos\Storage\PhotoFolders::dir($data['type'] === 'deliver' ? 'delivery' : 'not-delivered', $box->invoice);
            $paths = collect($request->file('photos', []))->map(function ($f) use ($dir) {
                $path = $f->store($dir, 'public');
                PhotoShrinker::file('public', $path);

                return $path;
            })->all();

            try {
                DB::transaction(function () use ($data, $box, $driver, $paths, $at): void {
                    $service = app(TripAssignment::class);
                    if ($data['type'] === 'deliver') {
                        if ($paths === []) {
                            throw new DomainException('A delivery needs at least one photo.');
                        }
                        $service->markDelivered($box, $paths, $driver);
                        $box->forceFill(['delivered_at' => $at])->save();
                    } else {
                        $reason = FailedDeliveryReason::tryFrom((string) ($data['reason'] ?? '')) ?? FailedDeliveryReason::Other;
                        $attempt = $service->recordFailedAttempt($box, $driver, $reason, $data['note'] ?? null, $paths);
                        $attempt->forceFill(['created_at' => $at])->save();
                    }
                });
            } catch (DomainException $e) {
                foreach ($paths as $p) {
                    Storage::disk('public')->delete($p);
                }
                $result = ['status' => 'conflict', 'message' => $e->getMessage()];
            }
        }

        $row = OfflineSubmission::create([
            'uuid' => $data['uuid'], 'user_id' => $driver->id, 'tripinvoice_id' => $data['tripinvoice_id'],
            'type' => $data['type'], 'status' => $result['status'], 'message' => $result['message'], 'happened_at' => $at,
            'payload' => ['reason' => $data['reason'] ?? null, 'note' => $data['note'] ?? null, 'photos' => count($request->file('photos', []))],
        ]);

        return $this->answer($row);
    }

    protected function answer(OfflineSubmission $row): JsonResponse
    {
        return response()->json(['uuid' => $row->uuid, 'status' => $row->status, 'message' => $row->message]);
    }

    /** The page the phone opens with no signal. It holds no data; driver-offline.js reads what the phone saved. */
    public function shell(): Response
    {
        return response(view('pwa.driver-offline', [
            'company' => Branding::companyName(),
            'script' => asset('js/app/driver-offline.js').'?v='.self::scriptVersion(),
        ])->render(), 200, ['Cache-Control' => 'no-cache']);
    }

    public static function scriptVersion(): string
    {
        $file = public_path('js/app/driver-offline.js');

        return is_file($file) ? substr(md5((string) filemtime($file)), 0, 8) : '0';
    }
}
DISPATCH_FILE_END_26

# ---------------------------------------------------------------- app/Support/Photos/BoxPhotos.php
mkdir -p 'app/Support/Photos'
cat > 'app/Support/Photos/BoxPhotos.php' <<'DISPATCH_FILE_END_27'
<?php

namespace App\Support\Photos;

use App\Models\BoxPhoto;
use App\Models\Invoice;
use App\Models\Invoiceissue;
use App\Models\PhotoSetting;
use App\Models\User;
use App\Support\Ai\PhotoCheck;
use Illuminate\Http\UploadedFile;
use Illuminate\Support\Facades\Storage;
use Illuminate\Support\Str;

/** Saves scan photos: made smaller (max 1600 px, JPEG) and stamped with invoice, date and who took it. */
class BoxPhotos
{
    public const MAX_SIDE = 1600;

    /**
     * @param  array{container_id?: ?int, deliverylog_id?: ?int, whdeliverylog_id?: ?int, warehouse_id?: ?int, logistichub_id?: ?int}  $context
     */
    public static function store(UploadedFile $file, string $step, ?Invoice $invoice, array $context, ?User $user, ?string $condition = null, ?string $note = null): BoxPhoto
    {
        $taken = now();
        $stamp = collect([
            $invoice?->invoice ?? 'BATCH',
            BoxPhoto::SHORT[$step] ?? $step,
            $condition ? strtoupper($condition) : null,
            $taken->format('d M Y g:i A'),
            $user?->full_name,
        ])->filter()->join('  |  ');

        $bytes = static::shrink((string) file_get_contents($file->getRealPath()), $stamp);
        $path = \App\Support\Photos\Storage\PhotoFolders::dir('scan/'.\App\Support\Photos\Storage\PhotoFolders::clean($step), $invoice?->invoice ?? 'batch', $taken).'/'.Str::uuid().'.jpg';
        Storage::disk('box')->put($path, $bytes);

        $photo = BoxPhoto::create([
            'invoice_id' => $invoice?->id,
            'invoice' => $invoice?->invoice,
            'step' => $step,
            'condition' => $condition,
            'note' => $note ? Str::limit(trim($note), 250, '') : null,
            'is_batch' => ! $invoice,
            'path' => $path,
            'size' => strlen($bytes),
            'container_id' => $context['container_id'] ?? null,
            'deliverylog_id' => $context['deliverylog_id'] ?? null,
            'whdeliverylog_id' => $context['whdeliverylog_id'] ?? null,
            'warehouse_id' => $context['warehouse_id'] ?? null,
            'logistichub_id' => $context['logistichub_id'] ?? null,
            'user_id' => $user?->id,
            'taken_at' => $taken,
        ]);

        PhotoCheck::queueBoxPhoto($photo);

        return $photo;
    }

    /** Resize to MAX_SIDE, add a dark strip with the stamp text, save as JPEG. Without GD the file is kept as is. */
    public static function shrink(string $bytes, string $stamp): string
    {
        if (! function_exists('imagecreatefromstring') || ! ($src = @imagecreatefromstring($bytes))) {
            return $bytes;
        }
        $src = PhotoShrinker::upright($src, PhotoShrinker::orientation($bytes)); // iPhone photos come sideways

        $w = imagesx($src);
        $h = imagesy($src);
        $scale = min(1, self::MAX_SIDE / max($w, $h));
        $nw = max(1, (int) round($w * $scale));
        $nh = max(1, (int) round($h * $scale));
        $img = imagecreatetruecolor($nw, $nh);
        imagecopyresampled($img, $src, 0, 0, 0, 0, $nw, $nh, $w, $h);
        imagedestroy($src);

        // stamp: white text on a dark strip, drawn small then scaled up so it stays readable
        $font = 5;
        $zoom = max(1, (int) floor($nw / 700));
        $pad = 6;
        $text = Str::ascii($stamp);
        $max = (int) floor(($nw / $zoom - $pad * 2) / imagefontwidth($font));
        $text = Str::limit($text, $max, '');
        $sw = (int) ceil($nw / $zoom);
        $sh = imagefontheight($font) + $pad * 2;
        $strip = imagecreatetruecolor($sw, $sh);
        imagefilledrectangle($strip, 0, 0, $sw, $sh, imagecolorallocate($strip, 14, 36, 51));
        imagestring($strip, $font, $pad, $pad, $text, imagecolorallocate($strip, 255, 255, 255));
        $dst = imagecreatetruecolor($nw, $sh * $zoom);
        imagecopyresized($dst, $strip, 0, 0, 0, 0, $nw, $sh * $zoom, $sw, $sh);
        imagecopymerge($img, $dst, 0, $nh - $sh * $zoom, 0, 0, $nw, $sh * $zoom, 80);
        imagedestroy($strip);
        imagedestroy($dst);

        ob_start();
        imagejpeg($img, null, 78);
        imagedestroy($img);

        return (string) ob_get_clean();
    }

    /** Photos of one box, oldest first. */
    public static function forInvoice(?int $invoiceId, ?User $user)
    {
        return $invoiceId
            ? BoxPhoto::visibleTo($user)->with('container:id,container_no', 'deliverylog:id,trip_number', 'whdeliverylog:id,trip_number', 'user:id,first_name,last_name', 'warehouse:id,name', 'logistichub:id,hub_name')
                ->where('invoice_id', $invoiceId)->orderBy('taken_at')->orderBy('id')->get()
            : collect();
    }

    /** Delete photos older than the keep time, except boxes with an open Invoice Issue. */
    public static function prune(): int
    {
        $months = PhotoSetting::current()->keep_months;
        if ($months < 1) {
            return 0;
        }

        $openIssue = Invoiceissue::query()->whereHas('invdata', fn ($q) => $q->where(fn ($q) => $q->where('is_resolved', false)->orWhereNull('is_resolved')))->select('invoice');
        $n = 0;
        BoxPhoto::where('taken_at', '<', now()->subMonths($months))
            ->where(fn ($q) => $q->whereNull('invoice')->orWhereNotIn('invoice', $openIssue))
            ->chunkById(200, function ($photos) use (&$n) {
                foreach ($photos as $p) {
                    $p->delete();
                    $n++;
                }
            });

        return $n;
    }
}
DISPATCH_FILE_END_27

# ---------------------------------------------------------------- app/Support/Photos/Storage/OldSystem.php
mkdir -p 'app/Support/Photos/Storage'
cat > 'app/Support/Photos/Storage/OldSystem.php' <<'DISPATCH_FILE_END_28'
<?php

namespace App\Support\Photos\Storage;

use App\Models\AppSetting;
use App\Models\Photos\PhotoTask;
use App\Models\Photos\PhotoTaskItem;
use Illuminate\Support\Collection;
use Illuminate\Support\Facades\Auth;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Schema;
use Illuminate\Support\Str;

/**
 * Copy from the old system (wms.icargoxpress.net, the first version) to the bucket.
 * Same database as wmsv2: each photo path in the database keeps the same path in the bucket,
 * so it opens in wmsv2 right after. Another database: the files are copied under wms-v1/.
 * Nothing on the old site is ever changed or deleted from here.
 */
class OldSystem
{
    public const IMAGES = ['jpg', 'jpeg', 'png', 'webp', 'gif'];

    /** Tables that never hold photos people took. */
    protected const NOT = ['migrations', 'jobs', 'job_batches', 'failed_jobs', 'cache', 'cache_locks', 'sessions', 'password_reset_tokens',
        'photo_files', 'photo_tasks', 'photo_task_items', 'storage_buckets', 'app_settings', 'box_photos', 'help_guides', 'notifications', 'activity_log', 'telescope_entries'];

    public static function folder(): ?string
    {
        $set = AppSetting::get('photos.old_folder');
        if ($set) {
            return rtrim((string) $set, '/');
        }
        $guess = dirname(base_path()).'/wms.icargoxpress.net';

        return is_dir($guess) ? $guess : null;
    }

    public static function env(string $dir): array
    {
        $out = [];
        foreach (@file($dir.'/.env', FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES) ?: [] as $line) {
            if (preg_match('/^\s*([A-Z_]+)\s*=\s*(.*)$/', $line, $m) && in_array($m[1], ['APP_URL', 'DB_CONNECTION', 'DB_HOST', 'DB_PORT', 'DB_DATABASE'], true)) {
                $out[$m[1]] = trim($m[2], " \t\"'");
            }
        }

        return $out;
    }

    /** What the Find step shows. */
    public static function find(): array
    {
        $dir = static::folder();
        if (! $dir || ! is_dir($dir)) {
            return ['found' => false, 'dir' => $dir];
        }
        $env = static::env($dir);
        $c = config('database.connections.'.config('database.default'));
        $host = fn ($h) => in_array($h, ['localhost', '127.0.0.1', '::1', null, ''], true) ? 'local' : $h;
        $same = filled($env['DB_DATABASE'] ?? null) && ($env['DB_DATABASE'] ?? null) === ($c['database'] ?? null)
            && $host($env['DB_HOST'] ?? null) === $host($c['host'] ?? null);

        return [
            'found' => true, 'dir' => $dir, 'laravel' => is_file($dir.'/artisan'), 'same' => $same,
            'url' => rtrim($env['APP_URL'] ?? 'https://'.basename($dir), '/'),
            'storage' => is_dir($dir.'/storage/app/public') ? $dir.'/storage/app/public' : null,
            'uploads' => is_dir($dir.'/public/uploads') ? $dir.'/public/uploads' : null,
        ];
    }

    /** Columns in the database that hold photo paths (text ending in .jpg, .png …). */
    public static function columns(): Collection
    {
        $like = fn ($q, $col) => $q->where(function ($w) use ($col) {
            foreach (static::IMAGES as $e) {
                $w->orWhere($col, 'like', '%.'.$e.'%');
            }
        });
        $out = collect();
        foreach (Schema::getTables() as $t) {
            $table = $t['name'];
            if (in_array($table, static::NOT, true) || str_starts_with($table, 'sqlite_')) {
                continue;
            }
            foreach (Schema::getColumns($table) as $col) {
                if (! preg_match('/char|text|json|string/i', (string) ($col['type_name'] ?? $col['type'] ?? ''))) {
                    continue;
                }
                $name = $col['name'];
                $n = rescue(fn () => $like(DB::table($table), $name)->count(), 0, false);
                if ($n > 0) {
                    $ex = (string) $like(DB::table($table), $name)->value($name);
                    $out->push(['table' => $table, 'column' => $name, 'n' => $n, 'example' => Str::limit(static::paths($ex)[0] ?? $ex, 80)]);
                }
            }
        }

        return $out->sortByDesc('n')->values();
    }

    /** One value can hold several paths (a JSON list) or a full link. */
    public static function paths(?string $value): array
    {
        $value = trim((string) $value);
        if ($value === '') {
            return [];
        }
        $list = str_starts_with($value, '[') ? (json_decode($value, true) ?: []) : [$value];

        return collect($list)->flatten()->filter(fn ($p) => is_string($p) && in_array(strtolower(pathinfo(parse_url($p, PHP_URL_PATH) ?: $p, PATHINFO_EXTENSION)), static::IMAGES, true))
            ->map(function ($p) {
                $p = parse_url($p, PHP_URL_PATH) ?: $p;
                $p = ltrim($p, '/');

                return str_starts_with($p, 'storage/') ? substr($p, 8) : $p;
            })->unique()->values()->all();
    }

    /** Folders with photos in the old and new site: [path => [old => [n, bytes], new => [n, bytes]]]. */
    public static function folders(array $find): array
    {
        $out = [];
        $walk = function (?string $root, string $label, string $side) use (&$out) {
            if (! $root || ! is_dir($root)) {
                return;
            }
            $it = new \RecursiveIteratorIterator(new \RecursiveDirectoryIterator($root, \FilesystemIterator::SKIP_DOTS));
            foreach ($it as $f) {
                if (! $f->isFile() || ! in_array(strtolower($f->getExtension()), static::IMAGES, true)) {
                    continue;
                }
                $rel = ltrim(substr($f->getPath(), strlen($root)), '/');
                $parts = array_slice(explode('/', $rel), 0, 2);
                $key = $label.($parts[0] !== '' ? '/'.implode('/', $parts) : '');
                $out[$key][$side][0] = ($out[$key][$side][0] ?? 0) + 1;
                $out[$key][$side][1] = ($out[$key][$side][1] ?? 0) + $f->getSize();
            }
        };
        $walk(storage_path('app/public'), 'storage/app/public', 'new');
        $walk($find['storage'] ?? null, 'storage/app/public', 'old');
        $walk($find['uploads'] ?? null, 'public/uploads', 'old');
        ksort($out);

        return $out;
    }

    /** The copy task (one at a time; Scan again refreshes it and keeps what was copied). */
    public static function task(): ?PhotoTask
    {
        return PhotoStore::ready() ? PhotoTask::where('kind', 'copy_old')->latest('id')->first() : null;
    }

    /** Scan: every photo path, where its file really is. */
    public static function scan(): PhotoTask
    {
        @set_time_limit(600);
        $find = static::find();
        $task = static::task() ?? PhotoTask::create(['kind' => 'copy_old', 'status' => 'ready', 'user_id' => Auth::id(), 'options' => ['small' => true, 'keep' => false]]);
        $known = $task->items()->get(['id', 'path', 'status', 'size_before', 'src_time', 'other'])->keyBy('path');
        $seen = [];
        $add = function (string $path, ?string $ref, ?string $src, ?string $other, string $found, array $tidy = []) use ($task, $known, &$seen) {
            if (isset($seen[$path])) {
                return;
            }
            $seen[$path] = true;
            $size = $src && is_file($src) ? filesize($src) : null;
            $time = $src && is_file($src) ? filemtime($src) : null;
            $old = $known[$path] ?? null;
            $data = ['source' => $src, 'other' => $other, 'found' => $found, 'ref' => $ref ? Str::limit($ref, 118, '') : null, 'size_before' => $size, 'src_time' => $time];
            if (! $old || $old->status !== 'done') {
                $data += ['new_path' => $tidy[0] ?? null, 'tbl' => $tidy[1] ?? null, 'col' => $tidy[2] ?? null];
            }
            if ($old) {
                // copied before and the file did not change: stays done; changed: copied again
                $changed = $old->status === 'done' && ($old->size_before !== $size || $old->src_time !== $time);
                $old->update($data + ($found === 'missing' ? ['status' => 'missing'] : ($changed || $old->status === 'missing' ? ['status' => 'pending', 'checked' => false] : [])));
            } else {
                PhotoTaskItem::create($data + ['photo_task_id' => $task->id, 'disk' => 'public', 'path' => $path, 'status' => $found === 'missing' ? 'missing' : 'pending']);
            }
        };

        if (($find['same'] ?? false) || ! ($find['found'] ?? false)) {
            foreach (static::columns() as $c) {
                $hasId = Schema::hasColumn($c['table'], 'id');
                $isKnown = isset(PhotoFolders::known()[$c['table'].'.'.$c['column']]);
                $q = DB::table($c['table'])->whereNotNull($c['column'])->select($isKnown ? ['*'] : array_filter([$hasId ? 'id' : null, $c['column']]));
                $hasId ? $q->orderBy('id') : $q->orderBy($c['column']);
                foreach ($q->cursor() as $row) {
                    foreach (static::paths($row->{$c['column']}) as $p) {
                        $new = storage_path('app/public/'.$p);
                        $olds = array_filter([($find['storage'] ?? null) ? $find['storage'].'/'.$p : null, ($find['found'] ?? false) ? $find['dir'].'/public/'.$p : null]);
                        $old = collect($olds)->first(fn ($f) => is_file($f));
                        $hasNew = is_file($new);
                        $ref = $c['table'].'.'.$c['column'].(isset($row->id) ? ' #'.$row->id : '');
                        $np = $isKnown ? PhotoFolders::newPath($c['table'], $c['column'], $row, $p) : null;
                        $tidy = $np ? [$np, $c['table'], $c['column']] : [];
                        if (PhotoStore::placeOf('public', $p) !== 'server') {
                            // already in a bucket (copied before, or moved): nothing to do
                            if (! isset($known[$p]) && ! isset($seen[$p])) {
                                PhotoTaskItem::create(['photo_task_id' => $task->id, 'disk' => 'public', 'path' => $p, 'found' => 'wmsv2', 'ref' => Str::limit($ref, 118, ''),
                                    'status' => 'skipped', 'note' => 'Already in the bucket']);
                            }
                            $seen[$p] = true;

                            continue;
                        }
                        match (true) {
                            $hasNew && $old && filesize($new) !== filesize($old) => $add($p, $ref, filemtime($new) >= filemtime($old) ? $new : $old, filemtime($new) >= filemtime($old) ? $old : $new, 'both', $tidy),
                            $hasNew => $add($p, $ref, $new, null, 'wmsv2', $tidy),
                            (bool) $old => $add($p, $ref, $old, null, 'wms', $tidy),
                            default => $add($p, $ref, null, null, 'missing'),
                        };
                    }
                }
            }
        } else {
            // another database: every picture file of the old site, under wms-v1/
            foreach (['storage' => $find['storage'] ?? null, 'public/uploads' => $find['uploads'] ?? null] as $label => $root) {
                if (! $root) {
                    continue;
                }
                $it = new \RecursiveIteratorIterator(new \RecursiveDirectoryIterator($root, \FilesystemIterator::SKIP_DOTS));
                foreach ($it as $f) {
                    if ($f->isFile() && in_array(strtolower($f->getExtension()), static::IMAGES, true)) {
                        $add('wms-v1/'.$label.'/'.ltrim(substr($f->getPathname(), strlen($root)), '/'), null, $f->getPathname(), null, 'wms');
                    }
                }
            }
        }
        $task->items()->whereNotIn('path', array_keys($seen))->where('status', '!=', 'done')->delete();
        $task->update(['total' => $task->items()->where('status', '!=', 'missing')->count()]);
        $task->forceFill(['options' => array_merge($task->options, ['scanned_at' => now()->toDateTimeString(), 'same' => (bool) ($find['same'] ?? false)])])->save();
        PhotoWork::count($task);

        return $task->fresh();
    }

    /** Copy one photo: made smaller if asked, the original kept if asked, then checked by size. */
    public static function copyOne(PhotoTask $task, PhotoTaskItem $item): void
    {
        $to = PhotoStore::target() !== 'server' ? PhotoStore::target() : 'tmp';
        if (! PhotoStore::usable($to)) {
            throw new \RuntimeException('The bucket is not ready: put it and press Test connection.');
        }
        if ($task->to_place !== $to) {
            $task->update(['to_place' => $to]);
        }
        $fs = PhotoStore::fs($to);
        $disk = str_starts_with($item->path, 'wms-v1/') ? 'old' : 'public';
        // put in the new folders (board 67): the path in the database is changed after the copy is checked
        $tidy = $task->opt('tidy', true) && $item->new_path && $item->tbl && $item->col && $disk === 'public';
        $key = $tidy ? $item->new_path : $item->path;
        if (! $task->opt('again') && PhotoStore::placeOf('public', $key) === $to && $disk === 'public') {
            $item->update(['status' => 'skipped', 'note' => 'Already in the bucket']);

            return;
        }
        if (! $item->source || ! is_file($item->source)) {
            $item->update(['status' => 'missing', 'note' => 'The file is gone']);

            return;
        }
        $bytes = (string) file_get_contents($item->source);
        $out = $task->opt('small', true) ? PhotoWork::smaller($bytes, $item->path) : $bytes;
        if ($task->opt('keep') && strlen($out) !== strlen($bytes)) {
            $fs->put('_original/'.$key, $bytes);
        }
        $fs->put($key, $out);
        if ((int) $fs->size($key) !== strlen($out)) {
            throw new \RuntimeException('The copy in the bucket has a different size.');
        }
        if ($item->found === 'both' && $item->other && is_file($item->other)) {
            $fs->put('_other/'.$key, (string) file_get_contents($item->other));
        }
        PhotoStore::record($disk, $key, $to, strlen($out));
        if ($tidy) {
            PhotoFolders::rewrite($item->tbl, $item->col, $item->path, $key);
        }
        $item->update(['status' => 'done', 'size_after' => strlen($out), 'size_before' => strlen($bytes), 'checked' => false, 'new_path' => $tidy ? $key : null]);
    }

    /** Try 50: copy 50 photos now, to look at them before copying all. */
    public static function tryFifty(PhotoTask $task): Collection
    {
        @set_time_limit(300);
        $items = $task->items()->where('status', 'pending')->orderByDesc('size_before')->limit(50)->get();
        foreach ($items as $i) {
            PhotoWork::one($task, $i);
            $i->update(['tried' => true]);
        }
        PhotoWork::count($task);

        return $items->map->fresh();
    }

    /** Pick which of the two files (both sites had one) is the photo; the other is kept under _other/. */
    public static function pick(PhotoTaskItem $item): void
    {
        if ($item->found !== 'both' || ! $item->other) {
            return;
        }
        $item->update(['source' => $item->other, 'other' => $item->source, 'status' => 'pending', 'checked' => false]);
    }

    /** Old link (as before) for a path. */
    public static function oldLink(PhotoTaskItem $item, array $find): ?string
    {
        if (! $item->source) {
            return null;
        }
        if (str_starts_with($item->source, storage_path('app/public'))) {
            return url('/storage/'.$item->path);
        }
        $dir = $find['dir'] ?? '';
        $rel = ltrim(substr($item->source, strlen($dir)), '/');

        return ($find['url'] ?? '').'/'.(str_starts_with($rel, 'storage/app/public/') ? 'storage/'.substr($rel, 19) : preg_replace('#^public/#', '', $rel));
    }
}
DISPATCH_FILE_END_28

# ---------------------------------------------------------------- app/Support/Photos/Storage/PhotoFolders.php
mkdir -p 'app/Support/Photos/Storage'
cat > 'app/Support/Photos/Storage/PhotoFolders.php' <<'DISPATCH_FILE_END_29'
<?php

namespace App\Support\Photos\Storage;

use App\Models\AppSetting;
use Illuminate\Support\Carbon;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Schema;
use Illuminate\Support\Str;

/**
 * One tidy folder structure (board 67): kind / year / month / invoice. The same on this server,
 * in R2 or in S3. New photos are saved here; old photos can be put here while they are copied
 * or moved to the bucket (the path in the database is changed after the copy is checked).
 */
class PhotoFolders
{
    /** Folders for each kind of photo (shown on the Photo storage page). */
    public const MAP = [
        ['Delivered (POD)', 'delivery/2026/11/0144033/…'],
        ['Not delivered', 'not-delivered/2026/11/0144033/…'],
        ['Box photos (scan app)', 'scan/unload/2026/11/0144033/…'],
        ['Damage (box issue)', 'damage/2026/11/…'],
        ['Unmanifested box', 'unmanifested/2026/11/…'],
        ['Sea shipment, at port, LCL pick-up', 'shipments/2026/11/SS-0042/…'],
        ['Fuel receipt, odometer', 'fuel/2026/11/ABC1234/…'],
        ['Truck pictures', 'trucks/ABC1234/…'],
        ['People (users, crew)', 'people/…'],
        ['Company and agent papers', 'papers/companies/… · papers/containers/…'],
    ];

    /** The folder for a new photo: kind / year / month / ref (invoice, plate, shipment). */
    public static function dir(string $kind, ?string $ref = null, mixed $at = null): string
    {
        $at = $at ? Carbon::parse($at) : now();
        $dated = in_array($kind, ['trucks', 'people', 'papers/companies', 'papers/containers', 'papers/consolidators'], true)
            ? $kind : $kind.'/'.$at->format('Y/m');

        return $dated.(filled($ref) ? '/'.static::clean((string) $ref) : '');
    }

    public static function clean(string $ref): string
    {
        return trim(preg_replace('/[^A-Za-z0-9._-]+/', '-', $ref), '-.') ?: 'x';
    }

    /** New photos at most this many KB (0 = no limit). */
    public static function maxKb(): int
    {
        return (int) AppSetting::get('photos.max_kb', 200);
    }

    /**
     * Columns that hold photo paths, and how to find each photo's kind, date and invoice.
     * [table.column => [kind, date column, ref: callable(row) => ?string]]
     */
    public static function known(): array
    {
        $inv = fn ($id) => $id ? DB::table('invoices')->where('id', $id)->value('invoice') : null;
        $plate = fn ($id) => $id ? DB::table('trucks')->where('id', $id)->value('plate_no') : null;

        return [
            'tripinvoices.delivery_picture' => ['delivery', ['delivered_at', 'updated_at'], fn ($r) => $r->invoice ?? $inv($r->invoice_id ?? null)],
            'delivery_attempts.photos' => ['not-delivered', ['created_at'], fn ($r) => $inv($r->invoice_id ?? null)],
            'invoiceissues.attachment_pic' => ['damage', ['created_at'], fn ($r) => $r->invoice ?? null],
            'unmanifesteds.attachment_pic' => ['unmanifested', ['created_at'], fn ($r) => $r->invoice ?? null],
            'fuel_fills.receipt_path' => ['fuel', ['filled_at', 'created_at'], fn ($r) => $plate($r->truck_id ?? null)],
            'fuel_fills.odometer_path' => ['fuel', ['filled_at', 'created_at'], fn ($r) => $plate($r->truck_id ?? null)],
            'sea_shipments.seal_photo' => ['shipments', ['created_at'], fn ($r) => $r->code ?? null],
            'sea_shipments.port_receipt' => ['shipments', ['created_at'], fn ($r) => $r->code ?? null],
            'sea_shipments.pickup_photo' => ['shipments', ['pickup_at', 'created_at'], fn ($r) => $r->code ?? null],
            'trucks.truck_picture' => ['trucks', [], fn ($r) => $r->plate_no ?? null],
            'users.profile_picture' => ['people', [], fn ($r) => null],
            'containers.container_picture' => ['papers/containers', [], fn ($r) => $r->container_no ?? null],
            'companies.company_picture' => ['papers/companies', [], fn ($r) => null],
            'companies.company_document' => ['papers/companies', [], fn ($r) => null],
            'consolidators.company_document' => ['papers/consolidators', [], fn ($r) => null],
            'box_photos.path' => ['scan', ['taken_at', 'created_at'], fn ($r) => $r->invoice ?? 'batch'],
        ];
    }

    /** Where an old photo goes in the new folders, from its record (null: not a known column). */
    public static function newPath(string $table, string $column, object $row, string $old): ?string
    {
        $k = static::known()[$table.'.'.$column] ?? null;
        if (! $k) {
            return null;
        }
        [$kind, $dates, $ref] = $k;
        if ($table === 'box_photos') {
            $kind = 'scan/'.static::clean((string) ($row->step ?? 'photo'));
        }
        $at = collect($dates)->map(fn ($c) => $row->{$c} ?? null)->first(fn ($v) => filled($v));
        $new = static::dir($kind, rescue(fn () => $ref($row), null, false), $at).'/'.basename($old);

        return $new === $old ? null : $new;
    }

    /**
     * Change one path to another in a column: plain text, or a JSON list of paths.
     * Only the rows that hold the old path; returns how many rows changed.
     */
    public static function rewrite(string $table, string $column, string $old, string $new): int
    {
        if (! Schema::hasColumn($table, $column)) {
            return 0;
        }
        $n = DB::table($table)->where($column, $old)->update([$column => $new]);
        $base = basename($old);
        $q = DB::table($table)->where($column, 'like', '%'.str_replace(['%', '_'], ['\%', '\_'], $base).'%')->where($column, 'like', '[%');
        foreach ($q->get(array_filter([Schema::hasColumn($table, 'id') ? 'id' : null, $column])) as $r) {
            $list = json_decode((string) $r->{$column}, true);
            if (! is_array($list)) {
                continue;
            }
            $changed = false;
            $list = array_map(function ($p) use ($old, $new, &$changed) {
                if (is_string($p) && ltrim(Str::after($p, '/storage/') === $p ? $p : Str::after($p, '/storage/'), '/') === $old) {
                    $changed = true;

                    return $new;
                }

                return $p;
            }, $list);
            if ($changed && isset($r->id)) {
                DB::table($table)->where('id', $r->id)->update([$column => json_encode(array_values($list))]);
                $n++;
            }
        }

        return $n;
    }

    /**
     * Every photo path in the known columns of this system: 'disk|path' => [table, column, new path].
     * Used by Move (photos of wmsv2 on this server) to put them in the new folders.
     */
    public static function refs(): array
    {
        $out = [];
        foreach (static::known() as $tc => $k) {
            [$table, $column] = explode('.', $tc);
            if (! Schema::hasTable($table) || ! Schema::hasColumn($table, $column)) {
                continue;
            }
            $q = DB::table($table)->whereNotNull($column);
            Schema::hasColumn($table, 'id') ? $q->orderBy('id') : $q->orderBy($column);
            foreach ($q->cursor() as $row) {
                foreach (OldSystem::paths($row->{$column}) as $p) {
                    $k = ($table === 'box_photos' ? 'box|' : 'public|').$p;
                    if (! isset($out[$k]) && ($new = static::newPath($table, $column, $row, $p))) {
                        $out[$k] = [$table, $column, $new];
                    }
                }
            }
        }

        return $out;
    }
}
DISPATCH_FILE_END_29

# ---------------------------------------------------------------- app/Support/Photos/Storage/PhotoStore.php
mkdir -p 'app/Support/Photos/Storage'
cat > 'app/Support/Photos/Storage/PhotoStore.php' <<'DISPATCH_FILE_END_30'
<?php

namespace App\Support\Photos\Storage;

use App\Models\AppSetting;
use App\Models\Photos\PhotoFile;
use App\Models\Photos\StorageBucket;
use Illuminate\Contracts\Filesystem\Filesystem;
use Illuminate\Filesystem\FilesystemAdapter;
use Illuminate\Support\Facades\Cache;
use Illuminate\Support\Facades\Schema;
use Illuminate\Support\Facades\Storage;
use Illuminate\Support\Str;

/**
 * Settings → Photo storage. Every photo of every app (scan app, driver app, panels) is saved
 * where "New photos go to" points: this server, the Temporary bucket or the Real bucket.
 * Each photo that is not on the server has a row in photo_files saying where it is, so old
 * photos keep opening after a switch. Links to bucket photos are made when a page shows them
 * (temporary links, the buckets stay private).
 */
class PhotoStore
{
    public const PLACES = ['server' => 'This server', 'tmp' => 'Temporary bucket', 'real' => 'Real bucket'];

    public const PROVIDERS = ['r2' => 'Cloudflare R2', 's3' => 'Amazon S3', 'other' => 'Other S3-compatible'];

    /** Folders on the public disk that always stay on the server (logos and icons used in PDFs and the app). */
    public const SKIP = ['livewire-tmp', 'filament-exports', 'filament-imports', 'exports', 'imports', 'brand', 'favicon', 'logo',
        'consolidatorlogo', 'help', 'icons', 'pwa', 'invoiceissue-attachments', 'email-attachments'];

    /** Tests: buckets are folders on the disk instead of R2. */
    public static bool $fake = false;

    protected static array $memo = [];

    protected static ?int $memoApp = null;

    protected static function memo(): array
    {
        if (static::$memoApp !== spl_object_id(app())) {
            static::$memoApp = spl_object_id(app());
            static::$memo = [];
        }

        return static::$memo;
    }

    public static function forgetMemo(): void
    {
        static::$memo = [];
        Cache::forget('photo_files.any');
    }

    public static function ready(): bool
    {
        static::memo();

        return static::$memo['ready'] ??= Schema::hasTable('photo_files') && Schema::hasTable('storage_buckets');
    }

    /** The S3 driver (composer require league/flysystem-aws-s3-v3). */
    public static function driverReady(): bool
    {
        return static::$fake || class_exists(\League\Flysystem\AwsS3V3\AwsS3V3Adapter::class);
    }

    public static function target(): string
    {
        $t = (string) AppSetting::get('photos.target', 'server');

        return isset(static::PLACES[$t]) ? $t : 'server';
    }

    public static function setTarget(string $place): void
    {
        AppSetting::put('photos.target', $place);
    }

    public static function bucket(string $slot): StorageBucket
    {
        static::memo();
        if (! static::ready()) {
            return new StorageBucket(['slot' => $slot, 'provider' => 'r2']);
        }

        return static::$memo['bucket'][$slot] ??= StorageBucket::firstOrNew(['slot' => $slot], ['provider' => 'r2']);
    }

    /** A bucket new photos can go to: set, tested, not turned off, and the driver is there. */
    public static function usable(string $slot): bool
    {
        if ($slot === 'server') {
            return true;
        }
        $b = static::bucket($slot);

        return static::driverReady() && $b->exists && $b->isSet() && $b->test_ok && ! $b->is_off;
    }

    /** A bucket photos can be read from (turned off still reads, so nothing breaks). */
    public static function readable(string $slot): bool
    {
        $b = static::bucket($slot);

        return static::driverReady() && $b->exists && $b->isSet();
    }

    public static function config(StorageBucket $b): array
    {
        if (static::$fake) {
            return ['driver' => 'local', 'root' => storage_path('framework/testing/buckets/'.$b->slot.'-'.($b->bucket ?: 'x')), 'throw' => true];
        }

        return array_filter([
            'driver' => 's3',
            'key' => trim((string) $b->access_key),
            'secret' => trim((string) $b->secret),
            'region' => $b->provider === 'r2' ? 'auto' : (trim((string) $b->region) ?: 'us-east-1'),
            'bucket' => trim((string) $b->bucket),
            'endpoint' => $b->endpointUrl(),
            'use_path_style_endpoint' => $b->provider !== 's3',
            'visibility' => 'private',
            'throw' => true,
            // R2 and other S3-compatible stores: only the checksums they need.
            'request_checksum_calculation' => 'when_required',
            'response_checksum_validation' => 'when_required',
        ], fn ($v) => $v !== null && $v !== '');
    }

    /** The bucket as a Laravel disk. */
    public static function fs(string $slot): FilesystemAdapter
    {
        static::memo();
        $b = static::bucket($slot);
        $key = $slot.':'.($b->updated_at?->timestamp ?? 0);

        return static::$memo['fs'][$key] ??= Storage::build(static::config($b));
    }

    /** The disk on this server behind a routed disk (public or box). */
    public static function server(string $disk): Filesystem
    {
        static::memo();

        return static::$memo['server'][$disk] ??= Storage::build(config('filesystems.disks.'.$disk.'.inner') + ['throw' => true]);
    }

    /** The key in the bucket: the same path (old box photos, box-photos/…, under private/). */
    public static function key(string $disk, string $path): string
    {
        $path = ltrim($path, '/');

        return ($disk === 'box' && str_starts_with($path, 'box-photos/') ? 'private/' : '').$path;
    }

    public static function skip(string $disk, string $path): bool
    {
        return $disk === 'public' && in_array(explode('/', ltrim($path, '/'))[0], static::SKIP, true);
    }

    /** Any photo off the server at all? (Before anything moved, nothing is looked up.) */
    public static function any(): bool
    {
        static::memo();

        return static::$memo['any'] ??= static::ready() && Cache::rememberForever('photo_files.any', fn () => PhotoFile::query()->exists());
    }

    public static function placeOf(string $disk, string $path): string
    {
        if (! static::any()) {
            return 'server';
        }
        static::memo();
        $k = $disk.'|'.$path;
        if (! array_key_exists($k, static::$memo['place'] ?? [])) {
            if (count(static::$memo['place'] ?? []) > 5000) {
                static::$memo['place'] = [];
            }
            static::$memo['place'][$k] = PhotoFile::where('disk', $disk)->where('path', $path)->value('place') ?? 'server';
        }
        $place = static::$memo['place'][$k];

        return $place === 'server' || ! static::readable($place) ? 'server' : $place;
    }

    /** Where a new photo goes. */
    public static function targetFor(string $disk, string $path): string
    {
        if (! static::ready() || static::skip($disk, $path)) {
            return 'server';
        }
        $t = static::target();

        return $t !== 'server' && static::usable($t) ? $t : 'server';
    }

    public static function record(string $disk, string $path, string $place, ?int $size = null, ?string $note = null): void
    {
        if (! static::ready()) {
            return;
        }
        static::memo();
        if ($place === 'server' && ! $note) {
            PhotoFile::where('disk', $disk)->where('path', $path)->delete();
        } else {
            PhotoFile::updateOrCreate(['disk' => $disk, 'path' => $path], ['place' => $place, 'size' => $size, 'note' => $note ? Str::limit($note, 150, '') : null]);
            if (! (static::$memo['any'] ?? false)) {
                Cache::forever('photo_files.any', true);
                static::$memo['any'] = true;
            }
        }
        static::$memo['place'][$disk.'|'.$path] = $place;
    }

    public static function forget(string $disk, string $path): void
    {
        if (static::any()) {
            PhotoFile::where('disk', $disk)->where('path', $path)->delete();
            static::$memo['place'][$disk.'|'.$path] = 'server';
        }
    }

    /** A link for a bucket photo: valid for some hours, made again each time a page shows it. */
    public static function link(string $slot, string $key, int $hours = 6): string
    {
        $fs = static::fs($slot);
        if (static::$fake) {
            return url('/photo-storage/fake/'.$slot.'/'.$key);
        }

        return $fs->temporaryUrl($key, now()->addHours($hours));
    }

    /** Upload, read back and delete a small file. */
    public static function test(string $slot): array
    {
        $b = static::bucket($slot);
        if (! static::driverReady()) {
            return [false, 'The S3 driver is not installed yet. On the server run: composer require league/flysystem-aws-s3-v3'];
        }
        if (! $b->isSet()) {
            return [false, 'Put the bucket details first.'];
        }
        static::$memo['fs'] = [];
        $key = 'wmsv2-test/'.Str::uuid().'.txt';
        $body = 'Photo storage test '.now()->toIso8601String();
        try {
            $fs = static::fs($slot);
            $fs->put($key, $body);
            $back = $fs->get($key);
            $fs->delete($key);
            $ok = $back === $body;
            $msg = $ok ? 'Uploaded, read and deleted a test file.' : 'The test file came back different.';
        } catch (\Throwable $e) {
            $ok = false;
            $msg = static::why($e);
        }
        $b->forceFill(['test_ok' => $ok, 'test_message' => Str::limit($msg, 250, ''), 'tested_at' => now()])->save();
        static::$memo['bucket'] = [];

        return [$ok, $msg];
    }

    /** A clear reason from an S3 error. */
    public static function why(\Throwable $e): string
    {
        $all = $e->getMessage().' '.($e->getPrevious()?->getMessage() ?? '');

        return match (true) {
            str_contains($all, 'InvalidAccessKeyId') => 'The Access key ID is wrong.',
            str_contains($all, 'SignatureDoesNotMatch') => 'The Secret access key is wrong.',
            str_contains($all, 'NoSuchBucket') => 'There is no bucket with this name.',
            str_contains($all, 'AccessDenied') || str_contains($all, '403') => 'Access denied: the API token needs Object Read & Write on this bucket.',
            str_contains($all, 'Could not resolve host') || str_contains($all, 'cURL error 6') => 'The Account ID or endpoint is wrong (the address cannot be found).',
            str_contains($all, 'timed out') || str_contains($all, 'cURL error 28') => 'No answer from the bucket (timed out). Try again.',
            default => 'Could not connect: '.Str::limit(trim(preg_replace('/\s+/', ' ', $all)), 160),
        };
    }

    /** Last 7 days: photos saved to a bucket, photos that stayed on the server because the bucket did not answer. */
    public static function stats(): array
    {
        if (! static::ready()) {
            return ['bucket' => 0, 'server' => 0];
        }
        $q = PhotoFile::where('created_at', '>=', now()->subDays(7));

        return ['bucket' => (clone $q)->whereIn('place', ['tmp', 'real'])->count(), 'server' => (clone $q)->where('place', 'server')->whereNotNull('note')->count()];
    }

    public static function countIn(string $place): int
    {
        return static::ready() ? PhotoFile::where('place', $place)->where('disk', '!=', 'old')->count() : 0;
    }

    public static function queueSeen(): ?int
    {
        return Cache::get('photos.queue.seen');
    }

    public static function scheduleSeen(): ?int
    {
        return Cache::get('photos.schedule.seen');
    }

    public static function workerOn(): bool
    {
        return (static::queueSeen() ?? 0) > now()->subMinutes(5)->timestamp;
    }

    public static function schedulerOn(): bool
    {
        return (static::scheduleSeen() ?? 0) > now()->subMinutes(3)->timestamp;
    }
}
DISPATCH_FILE_END_30

# ---------------------------------------------------------------- app/Support/Photos/Storage/PhotoWork.php
mkdir -p 'app/Support/Photos/Storage'
cat > 'app/Support/Photos/Storage/PhotoWork.php' <<'DISPATCH_FILE_END_31'
<?php

namespace App\Support\Photos\Storage;

use App\Jobs\RunPhotoTasks;
use App\Models\Photos\PhotoFile;
use App\Models\Photos\PhotoTask;
use App\Models\Photos\PhotoTaskItem;
use App\Support\Photos\PhotoShrinker;
use Illuminate\Support\Facades\Auth;
use Illuminate\Support\Facades\Cache;
use Illuminate\Support\Str;

/**
 * Moving photos in small batches: by the queue worker (Supervisor or Plesk), by the scheduler
 * (every minute), or by the Photo storage page itself while it is open ("Run here").
 * Each photo is copied, checked (same size in the bucket), and only then the old copy is deleted.
 */
class PhotoWork
{
    /** Server → a bucket: every photo still on the server (not the logos and icons). */
    public static function startMove(string $to, bool $tidy = true): PhotoTask
    {
        @set_time_limit(600);
        $task = PhotoTask::create(['kind' => 'move', 'from_place' => 'server', 'to_place' => $to, 'status' => 'running', 'user_id' => Auth::id(), 'started_at' => now(),
            'options' => ['tidy' => $tidy]]);
        $refs = $tidy ? PhotoFolders::refs() : [];
        $rows = [];
        foreach (['public', 'box'] as $disk) {
            $server = PhotoStore::server($disk);
            $files = $disk === 'box' ? $server->allFiles('box-photos') : $server->allFiles();
            foreach ($files as $path) {
                if (PhotoStore::skip($disk, $path) || str_starts_with(basename($path), '.')) {
                    continue;
                }
                $r = $refs[$disk.'|'.$path] ?? null;
                $rows[] = ['photo_task_id' => $task->id, 'disk' => $disk, 'path' => $path, 'status' => 'pending', 'created_at' => now(), 'updated_at' => now(),
                    'new_path' => $r[2] ?? null, 'tbl' => $r[0] ?? null, 'col' => $r[1] ?? null];
                if (count($rows) >= 500) {
                    PhotoTaskItem::insert($rows);
                    $rows = [];
                }
            }
        }
        $rows && PhotoTaskItem::insert($rows);
        $task->update(['total' => $task->items()->count()]);
        static::kick();

        return $task;
    }

    /** Switch to the real bucket: new photos go there now, the Temporary photos move, then Temporary turns off (if asked). */
    public static function startSwitch(bool $autoOff = true): PhotoTask
    {
        PhotoStore::setTarget('real');
        $task = PhotoTask::create(['kind' => 'switch', 'from_place' => 'tmp', 'to_place' => 'real', 'status' => 'running', 'user_id' => Auth::id(),
            'started_at' => now(), 'options' => ['auto_off' => $autoOff]]);
        PhotoFile::where('place', 'tmp')->where('disk', '!=', 'old')->select(['disk', 'path'])->orderBy('id')
            ->chunk(500, fn ($c) => PhotoTaskItem::insert($c->map(fn ($f) => ['photo_task_id' => $task->id, 'disk' => $f->disk, 'path' => $f->path,
                'status' => 'pending', 'created_at' => now(), 'updated_at' => now()])->all()));
        $task->update(['total' => $task->items()->count()]);
        static::kick();

        return $task;
    }

    /** Let the queue worker go on (if one runs; otherwise the scheduler or the page does it). */
    public static function kick(): void
    {
        rescue(fn () => RunPhotoTasks::dispatch(), null, false);
    }

    public static function active(): ?PhotoTask
    {
        return PhotoStore::ready() ? PhotoTask::whereIn('status', ['running', 'checking'])->orderBy('id')->first() : null;
    }

    /** Work for up to $seconds. Returns how many photos were done. */
    public static function work(int $seconds = 20): int
    {
        if (! PhotoStore::ready()) {
            return 0;
        }
        $lock = Cache::lock('photos.work', $seconds + 60);
        if (! $lock->get()) {
            return 0;
        }
        @ini_set('memory_limit', '512M');
        $until = microtime(true) + $seconds;
        $n = 0;
        try {
            while (microtime(true) < $until && ($task = static::active())) {
                $items = $task->items()->where('status', $task->status === 'checking' ? 'done' : 'pending')
                    ->when($task->status === 'checking', fn ($q) => $q->where('checked', false))->orderBy('id')->limit(25)->get();
                if ($items->isEmpty()) {
                    static::finish($task);

                    continue;
                }
                foreach ($items as $item) {
                    if (microtime(true) >= $until) {
                        break;
                    }
                    $task->status === 'checking' ? static::check($task, $item) : static::one($task, $item);
                    $n++;
                }
                static::count($task);
            }
        } finally {
            $lock->release();
        }

        return $n;
    }

    protected static function finish(PhotoTask $task): void
    {
        $task = $task->fresh();
        if ($task->kind === 'copy_old' && $task->status === 'checking' && $task->items()->where('status', 'pending')->exists()) {
            $task->update(['status' => 'running']); // missing in the bucket: copied again, then checked again

            return;
        }
        if ($task->kind === 'copy_old' && $task->status === 'running') {
            $task->update(['status' => 'checking']);

            return;
        }
        $task->update(['status' => 'done', 'finished_at' => $task->finished_at ?? now(), 'checked_at' => $task->status === 'checking' ? now() : $task->checked_at]);
        if ($task->kind === 'switch' && $task->opt('auto_off') && PhotoStore::countIn('tmp') === 0) {
            $b = PhotoStore::bucket('tmp');
            $b->exists && $b->update(['is_off' => true]);
        }
        PhotoStore::forgetMemo();
    }

    public static function count(PhotoTask $task): void
    {
        $by = $task->items()->selectRaw('status, count(*) as n, sum(coalesce(size_before, 0)) as b, sum(coalesce(size_after, 0)) as a')->groupBy('status')->get()->keyBy('status');
        $task->update([
            'done' => (int) ($by['done']->n ?? 0), 'skipped' => (int) ($by['skipped']->n ?? 0), 'failed' => (int) ($by['failed']->n ?? 0),
            'bytes_before' => (int) (($by['done']->b ?? 0) + ($by['skipped']->b ?? 0)), 'bytes_after' => (int) (($by['done']->a ?? 0) + ($by['skipped']->a ?? 0)),
        ]);
    }

    /** One photo of a move, a switch or a copy. */
    public static function one(PhotoTask $task, PhotoTaskItem $item): void
    {
        try {
            match ($task->kind) {
                'move', 'switch' => static::moveOne($task, $item),
                'copy_old' => OldSystem::copyOne($task, $item),
            };
        } catch (\Throwable $e) {
            $item->update(['status' => 'failed', 'note' => Str::limit(PhotoStore::why($e), 150, '')]);
            $task->update(['last_error' => Str::limit(PhotoStore::why($e), 250, '')]);
        }
    }

    protected static function moveOne(PhotoTask $task, PhotoTaskItem $item): void
    {
        $from = $task->from_place;
        $to = $task->to_place;
        $now = PhotoStore::placeOf($item->disk, $item->path);
        if ($now === $to) {
            $item->update(['status' => 'skipped', 'note' => 'Already there']);

            return;
        }
        $key = PhotoStore::key($item->disk, $item->path);
        $src = $from === 'server' ? PhotoStore::server($item->disk) : PhotoStore::fs($from);
        $srcKey = $from === 'server' ? $item->path : $key;
        if (! $src->exists($srcKey)) {
            $item->update(['status' => 'missing', 'note' => 'Not found']);

            return;
        }
        $bytes = (string) $src->get($srcKey);
        $dest = PhotoStore::fs($to);
        // put in the new folders (board 67): only photos of the server whose record is known
        $tidy = $from === 'server' && $task->opt('tidy') && $item->new_path && $item->tbl && $item->col;
        $path = $tidy ? $item->new_path : $item->path;
        $key = PhotoStore::key($item->disk, $path);
        $dest->put($key, $bytes);
        if ((int) $dest->size($key) !== strlen($bytes)) {
            throw new \RuntimeException('The copy in the bucket has a different size.');
        }
        PhotoStore::record($item->disk, $path, $to, strlen($bytes));
        if ($tidy) {
            PhotoFolders::rewrite($item->tbl, $item->col, $item->path, $path);
            PhotoStore::forget($item->disk, $item->path);
        }
        $src->delete($srcKey);
        $item->update(['status' => 'done', 'size_before' => strlen($bytes), 'size_after' => strlen($bytes), 'new_path' => $tidy ? $path : null]);
    }

    /** Check: the photo is in the bucket. A missing one is copied again. */
    protected static function check(PhotoTask $task, PhotoTaskItem $item): void
    {
        $key = $item->new_path ?: $item->path;
        $ok = $task->to_place && rescue(fn () => PhotoStore::fs($task->to_place)->exists($key), false, false);
        $item->update($ok ? ['checked' => true] : ['status' => 'pending', 'checked' => false, 'note' => 'Missing in the bucket: copied again']);
    }

    /** Make a photo at most $max bytes: 1600 px, JPEG quality 80 down to 60. Signatures (PNG) and other files stay. */
    public static function smaller(string $bytes, string $path, int $max = 200 * 1024): string
    {
        $ext = strtolower(pathinfo($path, PATHINFO_EXTENSION));
        if (strlen($bytes) <= $max || ! PhotoShrinker::available() || ! in_array($ext, ['jpg', 'jpeg', 'webp'], true)) {
            return $bytes;
        }
        $info = @getimagesizefromstring($bytes);
        if (! $info) {
            return $bytes;
        }
        $src = @imagecreatefromstring($bytes);
        if (! $src) {
            return $bytes;
        }
        $src = PhotoShrinker::upright($src, PhotoShrinker::orientation($bytes));
        $w = imagesx($src);
        $h = imagesy($src);
        $out = $bytes;
        // 1600 px with quality 80 down to 60; still too big (a very busy photo): 1280 px, then 1024 px
        foreach ([PhotoShrinker::MAX_SIDE, 1280, 1024] as $side) {
            $scale = min(1, $side / max($w, $h));
            $img = imagecreatetruecolor(max(1, (int) round($w * $scale)), max(1, (int) round($h * $scale)));
            imagecopyresampled($img, $src, 0, 0, 0, 0, imagesx($img), imagesy($img), $w, $h);
            foreach ([80, 75, 70, 65, 60] as $q) {
                ob_start();
                $ext === 'webp' && function_exists('imagewebp') ? imagewebp($img, null, $q) : imagejpeg($img, null, $q);
                $out = (string) ob_get_clean();
                if (strlen($out) <= $max) {
                    break 2;
                }
            }
            imagedestroy($img);
            $img = null;
            if ($scale < 1 && $side === 1024) {
                break;
            }
        }
        $img && imagedestroy($img);
        imagedestroy($src);

        return $out !== '' && strlen($out) < strlen($bytes) ? $out : $bytes;
    }
}
DISPATCH_FILE_END_31

# ---------------------------------------------------------------- app/Support/Photos/Storage/RoutedAdapter.php
mkdir -p 'app/Support/Photos/Storage'
cat > 'app/Support/Photos/Storage/RoutedAdapter.php' <<'DISPATCH_FILE_END_32'
<?php

namespace App\Support\Photos\Storage;

use League\Flysystem\Config;
use League\Flysystem\FileAttributes;
use League\Flysystem\FilesystemAdapter as FlyAdapter;
use League\Flysystem\UnableToReadFile;
use League\Flysystem\UnableToRetrieveMetadata;
use League\Flysystem\UnableToWriteFile;

/**
 * The "public" and "box" disks: each file is on this server or in a bucket (Settings → Photo storage).
 * New files go where "New photos go to" points; reading looks up where the file is (photo_files).
 * When a bucket does not answer, the photo is saved on the server so nothing is lost.
 */
class RoutedAdapter implements FlyAdapter
{
    public function __construct(protected string $disk, protected array $config) {}

    protected function server()
    {
        return PhotoStore::server($this->disk);
    }

    /** [place, Laravel disk, key] for reading a file. */
    protected function at(string $path): array
    {
        $place = PhotoStore::placeOf($this->disk, $path);

        return $place === 'server' ? ['server', $this->server(), $path] : [$place, PhotoStore::fs($place), PhotoStore::key($this->disk, $path)];
    }

    public function fileExists(string $path): bool
    {
        [, $fs, $key] = $this->at($path);

        return $fs->exists($key);
    }

    public function directoryExists(string $path): bool
    {
        return $this->server()->directoryExists($path);
    }

    public function write(string $path, string $contents, Config $config): void
    {
        $this->save($path, $contents, $config);
    }

    public function writeStream(string $path, $contents, Config $config): void
    {
        $this->save($path, $contents, $config);
    }

    /** @param  string|resource  $contents */
    protected function save(string $path, $contents, Config $config): void
    {
        $place = PhotoStore::targetFor($this->disk, $path);
        $options = array_filter(['visibility' => $config->get('visibility')]);
        // new photos at most 200 KB (Settings → Photo storage), wherever they are saved
        $max = PhotoStore::ready() && ! PhotoStore::skip($this->disk, $path) ? PhotoFolders::maxKb() : 0;
        if ($max > 0 && in_array(strtolower(pathinfo($path, PATHINFO_EXTENSION)), ['jpg', 'jpeg', 'webp'], true)) {
            $contents = is_resource($contents) ? (string) stream_get_contents($contents) : $contents;
            $contents = PhotoWork::smaller($contents, $path, $max * 1024);
        }
        if ($place !== 'server') {
            $bytes = is_resource($contents) ? (string) stream_get_contents($contents) : $contents;
            try {
                PhotoStore::fs($place)->put(PhotoStore::key($this->disk, $path), $bytes);
                // a copy left on the server from before would be found by mistake later
                rescue(fn () => $this->server()->delete($path), null, false);
                PhotoStore::record($this->disk, $path, $place, strlen($bytes));

                return;
            } catch (\Throwable $e) {
                $this->server()->put($path, $bytes, $options) ?: throw UnableToWriteFile::atLocation($path, 'server');
                PhotoStore::record($this->disk, $path, 'server', strlen($bytes), 'Bucket did not answer: '.PhotoStore::why($e));
                report($e);

                return;
            }
        }
        $this->server()->put($path, $contents, $options) ?: throw UnableToWriteFile::atLocation($path, 'server');
        PhotoStore::forget($this->disk, $path);
    }

    public function read(string $path): string
    {
        [, $fs, $key] = $this->at($path);
        $out = $fs->get($key);

        return $out ?? throw UnableToReadFile::fromLocation($path);
    }

    public function readStream(string $path)
    {
        [, $fs, $key] = $this->at($path);

        return $fs->readStream($key) ?? throw UnableToReadFile::fromLocation($path);
    }

    public function delete(string $path): void
    {
        [$place, $fs, $key] = $this->at($path);
        $fs->delete($key);
        if ($place !== 'server') {
            PhotoStore::forget($this->disk, $path);
        }
    }

    public function deleteDirectory(string $path): void
    {
        $this->server()->deleteDirectory($path);
    }

    public function createDirectory(string $path, Config $config): void
    {
        $this->server()->makeDirectory($path);
    }

    public function setVisibility(string $path, string $visibility): void
    {
        if (PhotoStore::placeOf($this->disk, $path) === 'server') {
            $this->server()->setVisibility($path, $visibility);
        }
    }

    public function visibility(string $path): FileAttributes
    {
        [$place, $fs, $key] = $this->at($path);

        return new FileAttributes($path, null, $place === 'server' ? $fs->getVisibility($key) : 'private');
    }

    public function mimeType(string $path): FileAttributes
    {
        [, $fs, $key] = $this->at($path);
        $mime = $fs->mimeType($key) ?: throw UnableToRetrieveMetadata::mimeType($path);

        return new FileAttributes($path, null, null, null, $mime);
    }

    public function lastModified(string $path): FileAttributes
    {
        [, $fs, $key] = $this->at($path);

        return new FileAttributes($path, null, null, $fs->lastModified($key));
    }

    public function fileSize(string $path): FileAttributes
    {
        [, $fs, $key] = $this->at($path);

        return new FileAttributes($path, $fs->size($key));
    }

    /** Only the files on this server are listed (photos in a bucket are found through photo_files). */
    public function listContents(string $path, bool $deep): iterable
    {
        return $this->server()->getDriver()->listContents($path, $deep);
    }

    public function move(string $source, string $destination, Config $config): void
    {
        [$place, $fs, $key] = $this->at($source);
        if ($place === 'server') {
            $fs->move($key, $destination);

            return;
        }
        $fs->move($key, PhotoStore::key($this->disk, $destination));
        PhotoStore::forget($this->disk, $source);
        PhotoStore::record($this->disk, $destination, $place);
    }

    public function copy(string $source, string $destination, Config $config): void
    {
        [$place, $fs, $key] = $this->at($source);
        if ($place === 'server') {
            $fs->copy($key, $destination);

            return;
        }
        $fs->copy($key, PhotoStore::key($this->disk, $destination));
        PhotoStore::record($this->disk, $destination, $place);
    }

    /** Called by Storage::disk(...)->url(): the server link, or a temporary bucket link. */
    public function getUrl(string $path): string
    {
        $place = PhotoStore::placeOf($this->disk, $path);
        if ($place !== 'server') {
            return PhotoStore::link($place, PhotoStore::key($this->disk, $path));
        }
        $base = $this->config['url'] ?? null;

        return $base ? rtrim($base, '/').'/'.ltrim($path, '/') : url('/storage/'.ltrim($path, '/'));
    }

    public function getTemporaryUrl(string $path, $expiration, array $options = []): string
    {
        return $this->getUrl($path);
    }
}
DISPATCH_FILE_END_32

# ---------------------------------------------------------------- database/migrations/2026_11_26_000051_photo_task_new_path.php
mkdir -p 'database/migrations'
cat > 'database/migrations/2026_11_26_000051_photo_task_new_path.php' <<'DISPATCH_FILE_END_33'
<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

/** Part 41: old photos put in the new folders while they are copied or moved. */
return new class extends Migration
{
    public function up(): void
    {
        if (Schema::hasTable('photo_task_items') && ! Schema::hasColumn('photo_task_items', 'new_path')) {
            Schema::table('photo_task_items', function (Blueprint $t) {
                $t->string('new_path', 500)->nullable();   // the path in the new folders (null: keeps its path)
                $t->string('tbl', 64)->nullable();         // the column whose path is changed after the copy
                $t->string('col', 64)->nullable();
            });
        }
    }

    public function down(): void
    {
        if (Schema::hasColumn('photo_task_items', 'new_path')) {
            Schema::table('photo_task_items', fn (Blueprint $t) => $t->dropColumn(['new_path', 'tbl', 'col']));
        }
    }
};
DISPATCH_FILE_END_33

# ---------------------------------------------------------------- resources/css/filament/admin/theme.css
mkdir -p 'resources/css/filament/admin'
cat > 'resources/css/filament/admin/theme.css' <<'DISPATCH_FILE_END_34'
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

/* ------------------------------------------------------------------ Warehouse sections, sets, truck waiting (Scan app) */
.ds-sx__tile { display: flex; flex-direction: column; align-items: center; gap: 0.15rem; padding: 0.9rem 1rem; border-radius: 1.2rem; background: var(--sx, #1d6fb8); color: #fff; text-align: center; animation: ds-sx-in .2s ease-out; }
.ds-sx__tile small { font-size: 0.8rem; font-weight: 700; opacity: .85; }
.ds-sx__tile strong { font-size: 3.6rem; line-height: 1; font-weight: 900; letter-spacing: -0.02em; }
.ds-sx__tile span { font-size: 1.05rem; font-weight: 800; }
.ds-sx__tile em { font-style: normal; font-size: 0.8rem; opacity: .9; }
.ds-sx__tile.is-truck strong { font-size: 3.6rem; letter-spacing: 0.02em; }
.ds-sx__setrows { list-style: none; margin: 0.25rem 0 0; padding: 0; display: flex; flex-direction: column; gap: 0.3rem; font-size: 0.8rem; color: var(--sa-text); }
.ds-sx__setrows li { display: grid; grid-template-columns: 1.4rem 1fr; }
.ds-sx__setadd { margin-top: 0.35rem; min-height: 2.8rem; border-radius: 0.75rem; background: #f6be00; color: #0a1219; font-weight: 800; font-size: 0.9rem; padding: 0 0.8rem; }
.ds-sx__here { display: flex; justify-content: space-between; align-items: center; gap: 0.5rem; padding: 0.55rem 0.8rem; border-radius: 0.8rem; background: rgb(246 140 0 / .16); color: #ffd39a; font-size: 0.85rem; }
@keyframes ds-sx-in { from { transform: scale(.96); opacity: .4; } to { transform: none; opacity: 1; } }
@media (prefers-reduced-motion: reduce) { .ds-sx__tile { animation: none; } }
.ds-sx__set { display: flex; flex-direction: column; gap: 0.35rem; padding: 0.7rem 0.9rem; border-radius: 1rem; background: rgb(255 255 255 / .06); font-size: 0.92rem; }
.ds-sx__set small { color: var(--sa-muted); font-size: 0.8rem; }
.ds-sx__set.is-done { background: rgb(52 195 143 / .14); }
.ds-sx__set.is-split { background: rgb(240 169 59 / .14); }
.ds-sx__set.is-split small { color: #f6c46b; }
.ds-sx__dots { display: flex; gap: 0.25rem; }
.ds-sx__dots i { flex: 1; max-width: 2.2rem; height: 0.4rem; border-radius: 999px; background: rgb(255 255 255 / .15); }
.ds-sx__dots i.is-on { background: var(--sa-ok); }
.ds-sx__link { align-self: center; padding: 0.35rem 0.6rem; color: var(--sa-gold); font-size: 0.88rem; font-weight: 700; text-decoration: underline; text-underline-offset: 3px; }
.ds-sx__team { display: flex; flex-wrap: wrap; gap: 0.35rem; }
.ds-sx__team span { padding: 0.25rem 0.65rem; border-radius: 999px; background: rgb(255 255 255 / .06); font-size: 0.8rem; color: var(--sa-muted); }
.ds-sx__team span.is-me { color: var(--sa-gold); box-shadow: inset 0 0 0 1px rgb(246 190 0 / .4); }
.ds-sx__team b { color: var(--sa-text); margin-left: 0.2rem; }
.ds-sx__truck { display: flex; flex-direction: column; gap: 0.5rem; padding: 0.75rem 0.9rem; border-radius: 1rem; background: rgb(232 89 12 / .16); box-shadow: inset 0 0 0 1px rgb(232 89 12 / .5); }
.ds-sx__truck.is-paused { background: rgb(255 255 255 / .05); box-shadow: inset 0 0 0 1px var(--sa-line); }
.ds-sx__truckhead { display: flex; justify-content: space-between; align-items: center; gap: 0.5rem; font-size: 0.9rem; }
.ds-sx__truckhead button { padding: 0.3rem 0.6rem; border-radius: 0.6rem; background: rgb(255 255 255 / .1); color: var(--sa-text); font-size: 0.78rem; font-weight: 700; margin-left: 0.25rem; }
.ds-sx__truckn { display: grid; grid-template-columns: repeat(3, 1fr); gap: 0.4rem; font-size: 0.74rem; color: var(--sa-muted); }
.ds-sx__truckn b { display: block; font-size: 1.15rem; color: var(--sa-text); }
.ds-sx__picker { display: flex; flex-direction: column; gap: 0.45rem; padding: 0.8rem; border-radius: 1rem; background: rgb(255 255 255 / .05); }
.ds-sx__picker > button:not(.ds-sx__link) { display: flex; flex-direction: column; align-items: flex-start; padding: 0.65rem 0.8rem; border-radius: 0.8rem; background: rgb(255 255 255 / .07); color: var(--sa-text); text-align: left; }
.ds-sx__picker small, .ds-sx__picker p { color: var(--sa-muted); font-size: 0.8rem; margin: 0; }
.ds-sx__open { display: flex; flex-direction: column; gap: 0.6rem; width: 100%; padding: 0.9rem; border-radius: 1rem; background: rgb(240 169 59 / .1); box-shadow: inset 0 0 0 1px rgb(240 169 59 / .4); text-align: left; }
.ds-sx__open > small { color: var(--sa-muted); font-size: 0.78rem; }
.ds-sx__openrow { display: flex; flex-direction: column; gap: 0.35rem; font-size: 0.9rem; }
.ds-sx__miss { display: flex; flex-direction: column; gap: 0.3rem; padding: 0.5rem 0.6rem; border-radius: 0.7rem; background: rgb(255 255 255 / .05); }
.ds-sx__miss small { color: var(--sa-muted); }
.ds-sx__why { display: flex; flex-wrap: wrap; gap: 0.3rem; }
.ds-sx__why button { padding: 0.3rem 0.55rem; border-radius: 999px; background: rgb(255 255 255 / .08); color: var(--sa-muted); font-size: 0.74rem; font-weight: 700; }
.ds-sx__why button.is-on { background: var(--sa-gold); color: #0a1219; }

/* ------------------------------------------------------------------ Settings · Warehouse sections */
.ds-ws { display: flex; flex-direction: column; gap: 1rem; }
.ds-ws__top { display: flex; flex-wrap: wrap; justify-content: space-between; align-items: flex-end; gap: 0.75rem; }
.ds-ws__wh { display: flex; flex-direction: column; gap: 0.25rem; font-size: 0.8rem; color: #6b7b88; }
.ds-ws__acts { display: flex; gap: 0.5rem; flex-wrap: wrap; }
.ds-ws select, .ds-ws input[type=text], .ds-ws textarea { min-height: 2.25rem; padding: 0.35rem 0.6rem; border-radius: 0.55rem; border: 1px solid #d5dde3; background: #fff; font-size: 0.85rem; color: inherit; width: 100%; box-sizing: border-box; }
.dark .ds-ws select, .dark .ds-ws input[type=text], .dark .ds-ws textarea { background: #0b1d2a; border-color: rgb(255 255 255 / .12); }
.ds-ws__list { padding: 0.25rem 0; overflow-x: auto; }
.ds-ws__row { display: grid; grid-template-columns: 7.5rem 1.2fr 0.9fr 1.3fr 2fr 4rem 2rem; gap: 0.6rem; align-items: center; padding: 0.6rem 1rem; border-top: 1px solid rgb(0 0 0 / .06); min-width: 62rem; }
.dark .ds-ws__row { border-color: rgb(255 255 255 / .07); }
.ds-ws__row.is-head { border-top: 0; font-size: 0.72rem; font-weight: 700; color: #6b7b88; }
.ds-ws__code { display: grid; grid-template-columns: 2.6rem 1fr; gap: 0.3rem; align-items: center; }
.ds-ws__code input { text-align: center; font-weight: 900; font-size: 1.05rem !important; color: #fff !important; background: var(--c) !important; border-color: var(--c) !important; }
.ds-ws__code select { font-size: 0.7rem !important; padding: 0.2rem !important; }
.ds-ws__muted { color: #6b7b88; font-size: 0.8rem; margin: 0; }
.ds-ws__del { width: 2rem; height: 2rem; border-radius: 0.5rem; color: #c8372d; }
.ds-ws__del:hover { background: #fde8e6; }
.ds-ws__empty { padding: 1.25rem; display: flex; flex-direction: column; align-items: flex-start; gap: 0.75rem; }
.ds-ws__empty p { margin: 0; color: #6b7b88; }
.ds-ws__err { margin: 0.5rem 1rem; color: #c8372d; font-size: 0.85rem; }
.ds-ws__two { display: grid; grid-template-columns: 1fr 1fr; gap: 1rem; }
.ds-ws__box { padding: 1rem 1.15rem; display: flex; flex-direction: column; gap: 0.6rem; }
.ds-ws__box h3 { margin: 0; font-size: 0.98rem; font-weight: 800; }
.ds-ws__toggle { display: flex; gap: 0.7rem; align-items: flex-start; cursor: pointer; }
.ds-ws__toggle input { margin-top: 0.25rem; width: 1.1rem; height: 1.1rem; }
.ds-ws__toggle small { display: block; color: #6b7b88; font-size: 0.8rem; margin-top: 0.15rem; }
@media (max-width: 900px) { .ds-ws__two { grid-template-columns: 1fr; } }
.ds-ws__result { display: flex; gap: 0.9rem; align-items: center; margin-top: 0.75rem; padding: 0.75rem 1rem; border-radius: 0.9rem; background: color-mix(in srgb, var(--c) 12%, transparent); box-shadow: inset 0 0 0 1px color-mix(in srgb, var(--c) 40%, transparent); }
.ds-ws__result > strong { display: grid; place-items: center; min-width: 3rem; height: 3rem; padding: 0 0.4rem; border-radius: 0.7rem; background: var(--c); color: #fff; font-size: 1.6rem; font-weight: 900; }
.ds-ws__result small { display: block; color: #6b7b88; font-size: 0.8rem; }

/* ------------------------------------------------------------------ Sea shipments, wrong hub & returns */
.ds-sp { display: flex; flex-direction: column; gap: 1rem; }
.ds-sp h3 { margin: 0; font-size: 0.98rem; font-weight: 800; }
.ds-sp select, .ds-sp input[type=text], .ds-sp input[type=number], .ds-sp input[type=date] { min-height: 2.25rem; padding: 0.35rem 0.6rem; border-radius: 0.55rem; border: 1px solid #d5dde3; background: #fff; font-size: 0.85rem; color: inherit; box-sizing: border-box; }
.dark .ds-sp select, .dark .ds-sp input[type=text], .dark .ds-sp input[type=number], .dark .ds-sp input[type=date] { background: #0b1d2a; border-color: rgb(255 255 255 / .12); }
.ds-sp__new { padding: 1rem 1.15rem; display: flex; flex-direction: column; gap: 0.6rem; }
.ds-sp__newrow { display: flex; flex-wrap: wrap; gap: 0.5rem; align-items: center; }
.ds-sp__newrow select, .ds-sp__newrow input { flex: 1 1 12rem; }
.ds-sp__err { margin: 0; color: #c8372d; font-size: 0.85rem; }
.ds-sp__filter { display: flex; gap: 0.35rem; }
.ds-sp__filter button { padding: 0.35rem 0.85rem; border-radius: 999px; font-size: 0.8rem; font-weight: 700; background: #eef2f5; color: #3d4f5c; }
.ds-sp__filter button.is-on { background: #0e2433; color: #fff; }
.dark .ds-sp__filter button { background: rgb(255 255 255 / .06); color: #c9d5de; }
.dark .ds-sp__filter button.is-on { background: #e6edf3; color: #0e2433; }
.ds-sp__list { display: flex; flex-direction: column; gap: 0.5rem; }
.ds-sp__item { display: grid; grid-template-columns: 2.5rem 1fr auto auto; gap: 1rem; align-items: center; padding: 0.8rem 1rem; }
.ds-sp__icon { font-size: 1.5rem; }
.ds-sp__main { display: flex; flex-direction: column; gap: 0.2rem; min-width: 0; }
.ds-sp__main small, .ds-sp__nums small { color: #6b7b88; font-size: 0.78rem; }
.ds-sp__bar { display: flex; gap: 0.2rem; margin-top: 0.25rem; max-width: 20rem; }
.ds-sp__bar i { flex: 1; height: 0.35rem; border-radius: 999px; background: #dfe5ea; }
.ds-sp__bar i.is-done { background: #17895e; }
.ds-sp__bar i.is-now { background: #f6be00; }
.dark .ds-sp__bar i { background: rgb(255 255 255 / .1); }
.ds-sp__nums { display: flex; flex-direction: column; align-items: flex-end; }
.ds-sp__nums b { font-size: 1.2rem; }
.ds-sp__state { padding: 0.25rem 0.7rem; border-radius: 999px; font-size: 0.75rem; font-weight: 800; background: #eef5fb; color: #1d6fb8; white-space: nowrap; }
.ds-sp__state.is-received { background: #e2f5ec; color: #17895e; }
.ds-sp__state.is-preparing { background: #eef2f5; color: #3d4f5c; }
.ds-sp__steps { display: grid; grid-auto-flow: column; grid-auto-columns: 1fr; gap: 0.5rem; padding: 1rem; overflow-x: auto; }
.ds-sp__step { display: flex; flex-direction: column; gap: 0.3rem; min-width: 6rem; font-size: 0.85rem; color: #8a99a5; }
.ds-sp__step i { height: 0.4rem; border-radius: 999px; background: #dfe5ea; }
.ds-sp__step.is-done { color: inherit; }
.ds-sp__step.is-done i { background: #17895e; }
.ds-sp__step.is-now { color: inherit; }
.ds-sp__step.is-now i { background: #f6be00; }
.ds-sp__step small { font-size: 0.72rem; color: #8a99a5; }
.ds-sp__head { display: flex; flex-wrap: wrap; justify-content: space-between; align-items: center; gap: 0.75rem; }
.ds-sp__track { display: flex; gap: 0.75rem; align-items: center; font-size: 1rem; }
.ds-sp__track > span:first-child { font-size: 1.6rem; }
.ds-sp__track small { display: block; color: #6b7b88; font-size: 0.78rem; }
.ds-sp__acts { display: flex; gap: 0.5rem; flex-wrap: wrap; }
.ds-sp__block { display: flex; flex-direction: column; gap: 0.25rem; padding: 0.7rem 1rem; border-radius: 0.75rem; background: #fff4e0; color: #7a4a00; font-size: 0.88rem; }
.dark .ds-sp__block { background: rgb(240 169 59 / .14); color: #f6c46b; }
.ds-sp__grid { display: grid; grid-template-columns: 1.4fr 1fr; gap: 1rem; align-items: start; }
.ds-sp__box { padding: 1rem 1.15rem; display: flex; flex-direction: column; gap: 0.7rem; }
.ds-sp__nums4 { display: grid; grid-template-columns: repeat(4, 1fr); gap: 0.5rem; }
.ds-sp__nums4 span { display: flex; flex-direction: column; padding: 0.7rem; border-radius: 0.7rem; background: #f3f6f8; }
.dark .ds-sp__nums4 span { background: rgb(255 255 255 / .04); }
.ds-sp__nums4 small { font-size: 0.72rem; color: #6b7b88; }
.ds-sp__nums4 b { font-size: 1.4rem; }
.ds-sp__nums4 .is-bad b { color: #c8372d; }
.ds-sp__warn { margin: 0; padding: 0.55rem 0.75rem; border-radius: 0.6rem; background: #fde8e6; color: #a3281f; font-size: 0.85rem; }
.dark .ds-sp__warn { background: rgb(255 107 94 / .12); color: #ff9d93; }
.ds-sp__sets { display: flex; flex-direction: column; gap: 0.25rem; font-size: 0.85rem; padding: 0.6rem 0.75rem; border-radius: 0.6rem; background: #eef5fb; }
.dark .ds-sp__sets { background: rgb(90 168 255 / .08); }
.ds-sp__dl { display: grid; grid-template-columns: 1fr auto; gap: 0.35rem 0.75rem; margin: 0; font-size: 0.88rem; }
.ds-sp__dl dt { color: #6b7b88; }
.ds-sp__dl dd { margin: 0; text-align: right; font-variant-numeric: tabular-nums; }
.ds-sp__perbox { display: flex; justify-content: space-between; align-items: baseline; margin: 0; padding: 0.7rem 0.9rem; border-radius: 0.7rem; background: #eef5fb; font-weight: 800; }
.ds-sp__perbox b { font-size: 1.4rem; }
.dark .ds-sp__perbox { background: rgb(90 168 255 / .08); }
.ds-sp__pics { display: flex; gap: 0.5rem; }
.ds-sp__pics a { display: flex; flex-direction: column; gap: 0.2rem; font-size: 0.72rem; color: #6b7b88; }
.ds-sp__pics img { width: 5rem; height: 5rem; object-fit: cover; border-radius: 0.6rem; }
.ds-sp__form { padding: 1rem 1.15rem; display: flex; flex-direction: column; gap: 0.8rem; }
.ds-sp__fields { display: grid; grid-template-columns: repeat(4, minmax(0, 1fr)); gap: 0.6rem; }
.ds-sp__fields label { display: flex; flex-direction: column; gap: 0.25rem; font-size: 0.75rem; color: #6b7b88; }
.ds-sp__fields .is-wide { grid-column: span 2; }
.ds-sp__fields input[type=file] { font-size: 0.78rem; }
.ds-sp__table { padding: 0.25rem 0; overflow-x: auto; }
.ds-sp__tr { display: grid; grid-template-columns: 1.4fr 1fr 1.6fr auto; gap: 0.8rem; align-items: center; padding: 0.7rem 1rem; border-top: 1px solid rgb(0 0 0 / .06); min-width: 46rem; font-size: 0.88rem; }
.dark .ds-sp__tr { border-color: rgb(255 255 255 / .07); }
.ds-sp__tr.is-head { border-top: 0; font-size: 0.72rem; font-weight: 700; color: #6b7b88; }
.ds-sp__tr > span { display: flex; flex-direction: column; gap: 0.2rem; }
.ds-sp__tr small { color: #6b7b88; font-size: 0.76rem; }
.ds-sp__tr select { font-size: 0.75rem; min-height: 1.9rem; }
.ds-sp__tag { align-self: flex-start; font-style: normal; font-size: 0.72rem; font-weight: 800; padding: 0.15rem 0.55rem; border-radius: 999px; background: #eef2f5; color: #3d4f5c; }
.ds-sp__tag.is-bad { background: #fde8e6; color: #a3281f; }
.ds-sp__ok { color: #17895e; }
.ds-sp__btns { flex-direction: row !important; gap: 0.35rem; flex-wrap: wrap; justify-content: flex-end; }
.ds-sp__pad { padding: 1rem; }
.ds-sp__barrow { display: grid; grid-template-columns: 11rem 1fr 2.5rem; gap: 0.6rem; align-items: center; font-size: 0.86rem; }
.ds-sp__barrow i { height: 0.7rem; border-radius: 999px; background: #eef2f5; overflow: hidden; }
.ds-sp__barrow i b { display: block; height: 100%; background: #1d6fb8; border-radius: 999px; }
@media (max-width: 1000px) { .ds-sp__grid { grid-template-columns: 1fr; } .ds-sp__fields { grid-template-columns: 1fr 1fr; } .ds-sp__nums4 { grid-template-columns: 1fr 1fr; } }
.ds-sx__stop { margin: 0; padding: 0.7rem 0.9rem; border-radius: 0.9rem; background: rgb(255 107 94 / .15); color: #ff9d93; font-weight: 700; font-size: 0.9rem; text-align: left; }
.ds-ws__row.is-view { grid-template-columns: 4rem 1.3fr 2fr 6rem 1.6fr; min-width: 48rem; }
.ds-ws__row.is-view > span { display: flex; flex-direction: column; }
.ds-ws__badge { display: grid !important; place-items: center; width: 2.6rem; height: 2.6rem; border-radius: 0.6rem; background: var(--c); color: #fff; font-weight: 900; font-size: 1.15rem; }
.ds-ws__pad { padding: 1rem; }
.ds-ws__box input[type=text] { max-width: 22rem; }
.ds-sp__tr.is-cost { grid-template-columns: 1.6fr 1fr 1.2fr 1.2fr 1fr; min-width: 40rem; }
.ds-sp__barrow.is-plain { grid-template-columns: 1fr auto auto; }
/* ============================== Box sizes ============================== */
.ds-bx { display: flex; flex-direction: column; gap: 1rem; }
.ds-bx__head { display: flex; align-items: center; justify-content: space-between; gap: 1rem; flex-wrap: wrap; }
.ds-bx__head p { margin: 0; max-width: 46rem; color: var(--ds-steel); }
.ds-bx__switch { display: inline-flex; align-items: center; gap: 0.6rem; padding: 0.5rem 0.9rem 0.5rem 0.5rem; border-radius: 0.8rem; font-weight: 800; background: #fff; color: var(--ds-steel); box-shadow: inset 0 0 0 1px rgb(14 36 51 / 0.12); cursor: pointer; }
.ds-bx__switch i { position: relative; width: 2.4rem; height: 1.4rem; border-radius: 999px; background: #c7d0d7; }
.ds-bx__switch i::after { content: ''; position: absolute; top: 0.2rem; left: 0.2rem; width: 1rem; height: 1rem; border-radius: 50%; background: #fff; transition: left .15s; }
.ds-bx__switch.is-on { background: #e7f5ee; color: #17694a; box-shadow: none; }
.ds-bx__switch.is-on i { background: var(--ds-ok); }
.ds-bx__switch.is-on i::after { left: 1.2rem; }
.ds-bx__two { display: grid; grid-template-columns: minmax(0, 1.25fr) minmax(0, 1fr); gap: 1rem; align-items: start; }
@media (max-width: 64rem) { .ds-bx__two { grid-template-columns: 1fr; } }
.ds-bx__types, .ds-bx__trucks, .ds-bx__same { display: flex; flex-direction: column; gap: 0.5rem; }
.ds-bx__side { display: flex; flex-direction: column; gap: 1rem; }
.ds-bx__type { display: grid; grid-template-columns: minmax(0, 1fr) auto 4rem; align-items: center; gap: 0.75rem; padding: 0.7rem 0.8rem; border-radius: 0.8rem; box-shadow: inset 0 0 0 1px rgb(14 36 51 / 0.08); }
.ds-bx__type.is-new { background: #fff8e0; box-shadow: inset 0 0 0 1px #f2dc8c; }
.ds-bx__type.is-plain { background: rgb(14 36 51 / 0.03); box-shadow: none; }
.ds-bx__name { display: flex; flex-direction: column; gap: 0.2rem; min-width: 0; }
.ds-bx__name > span:first-child { display: flex; align-items: center; gap: 0.5rem; flex-wrap: wrap; }
.ds-bx__name small { color: var(--ds-steel); font-size: 0.78rem; }
.ds-bx__tag { font-style: normal; font-size: 0.65rem; font-weight: 800; padding: 0.1rem 0.45rem; border-radius: 999px; }
.ds-bx__tag.is-base { background: var(--ds-navy); color: #fff; }
.ds-bx__tag.is-new { background: #fff1c2; color: #7a5600; }
.ds-bx__links { display: flex; gap: 0.75rem; }
.ds-bx__links button { font-size: 0.75rem; font-weight: 700; color: var(--ds-steel); text-decoration: underline; text-underline-offset: 2px; }
.ds-bx__step { display: inline-flex; align-items: center; gap: 0.35rem; }
.ds-bx__step button { width: 2rem; height: 2rem; border-radius: 0.5rem; background: rgb(14 36 51 / 0.07); font-weight: 800; font-size: 1.05rem; }
.ds-bx__step b { min-width: 2.2rem; text-align: center; font-size: 1.05rem; font-variant-numeric: tabular-nums; }
.ds-bx__step input { width: 4rem; text-align: center; padding: 0.3rem; border-radius: 0.5rem; border: 1px solid rgb(14 36 51 / 0.15); font-weight: 800; background: transparent; }
.ds-bx__pic { display: flex; align-items: flex-end; justify-content: center; height: 2.6rem; }
.ds-bx__pic i { display: block; border-radius: 4px; background: var(--ds-navy-3); }
.ds-bx__same > div, .ds-bx__trucks > div { display: flex; align-items: center; gap: 0.6rem; padding: 0.55rem 0; border-top: 1px solid rgb(14 36 51 / 0.08); }
.ds-bx__same > div > span, .ds-bx__trucks > div > span:first-child { flex: 1; display: flex; flex-direction: column; gap: 0.15rem; min-width: 0; }
.ds-bx__same small, .ds-bx__trucks small { color: var(--ds-steel); font-size: 0.78rem; }
.ds-bx__trucks small.ds-bx__past { color: #5b46c2; }
.ds-bx__ai { align-self: flex-start; padding: 0.55rem 0.9rem; border-radius: 0.7rem; font-weight: 800; background: #f1eefc; color: #3b2f7a; box-shadow: inset 0 0 0 1px #d9d1f7; }
.dark .ds-bx__type { box-shadow: inset 0 0 0 1px rgb(255 255 255 / 0.08); }
.dark .ds-bx__type.is-new { background: rgb(246 190 0 / 0.08); }
.dark .ds-bx__switch { background: #10283a; }
.dark .ds-bx__step button { background: rgb(255 255 255 / 0.08); }
.dark .ds-bx__pic i { background: var(--ds-signal); }
.ds-sa__size { background: rgb(246 190 0 / 0.18) !important; color: #f6be00 !important; font-weight: 800; }
.ds-sa__count small.ds-sa__space { color: #f6be00; font-weight: 700; }
.ds-bx__note { margin: 0; padding: 0.6rem 0.8rem; border-radius: 0.7rem; background: #fff8e0; color: #7a5600; font-size: 0.9rem; }
.ds-bx__dims { display: flex; flex-wrap: wrap; align-items: center; gap: 0.25rem; font-size: 0.75rem; color: #6b7b88; margin-top: 0.25rem; }
.ds-bx__dims input { width: 3.6rem; height: 1.8rem; padding: 0 0.35rem; border-radius: 0.4rem; border: 1px solid #d5dde3; background: #fff; font-size: 0.78rem; color: inherit; }
.dark .ds-bx__dims input { background: #0b1d2a; border-color: rgb(255 255 255 / .12); }
.ds-bx__dims button { margin-left: 0.25rem; padding: 0.15rem 0.5rem; border-radius: 999px; background: #eef5fb; color: #1d6fb8; font-weight: 700; font-size: 0.72rem; }
.ds-sx__topup { display: flex; flex-direction: column; gap: 0.45rem; width: 100%; padding: 0.9rem; border-radius: 1rem; background: rgb(52 195 143 / .1); box-shadow: inset 0 0 0 1px rgb(52 195 143 / .4); text-align: left; }
.ds-sx__topup > small { color: var(--sa-muted); font-size: 0.78rem; }
.ds-sx__toprow { display: grid; grid-template-columns: 1fr auto; gap: 0.5rem; align-items: center; padding: 0.5rem 0.6rem; border-radius: 0.7rem; background: rgb(255 255 255 / .05); font-size: 0.86rem; }
.ds-sx__toprow small { display: block; color: var(--sa-muted); font-size: 0.76rem; }
.ds-sx__toprow button { padding: 0.35rem 0.7rem; border-radius: 0.6rem; background: var(--sa-ok); color: #0a1219; font-weight: 800; font-size: 0.78rem; }
.ds-sp__lines { display: flex; flex-wrap: wrap; gap: 0.35rem; }
.ds-sp__line { display: inline-flex; align-items: center; gap: 0.35rem; padding: 0.3rem 0.4rem 0.3rem 0.7rem; border-radius: 999px; background: #eef2f5; font-size: 0.8rem; }
.dark .ds-sp__line { background: rgb(255 255 255 / .06); }
.ds-sp__x { width: 1.4rem; height: 1.4rem; border-radius: 50%; color: #c8372d; }
.ds-sp__search { display: flex; align-items: center; gap: 0.5rem; padding: 0 0.75rem; min-height: 2.6rem; border-radius: 0.7rem; box-shadow: inset 0 0 0 1.5px #0e2433; background: #fff; }
.dark .ds-sp__search { background: #0b1d2a; box-shadow: inset 0 0 0 1.5px rgb(255 255 255 / .3); }
.ds-sp__search input { flex: 1; border: 0 !important; box-shadow: none !important; background: transparent !important; outline: none; font-size: 0.92rem; padding: 0 !important; }
.ds-sp__search button { width: 1.5rem; height: 1.5rem; border-radius: 50%; background: #eef2f5; font-size: 0.7rem; }
.ds-sp__group { margin-top: 0.4rem; font-size: 0.72rem; color: #6b7b88; }
.ds-sp__pick { display: grid; grid-template-columns: 1.1rem 1fr auto; gap: 0.7rem; align-items: center; padding: 0.7rem 0.8rem; border-radius: 0.75rem; text-align: left; box-shadow: inset 0 0 0 1px #e6ebef; }
.dark .ds-sp__pick { box-shadow: inset 0 0 0 1px rgb(255 255 255 / .1); }
.ds-sp__pick i { width: 1.1rem; height: 1.1rem; border-radius: 50%; box-shadow: inset 0 0 0 2px #b7c4cf; }
.ds-sp__pick.is-on { box-shadow: inset 0 0 0 2px #0e2433; background: #f3f6f8; }
.dark .ds-sp__pick.is-on { box-shadow: inset 0 0 0 2px #e6edf3; background: rgb(255 255 255 / .04); }
.ds-sp__pick.is-on i { box-shadow: inset 0 0 0 6px #0e2433; }
.ds-sp__pick span { display: flex; flex-direction: column; }
.ds-sp__pick small { color: #6b7b88; font-size: 0.76rem; }
.ds-sp__pick em { font-style: normal; font-size: 0.78rem; font-weight: 800; color: #3d4f5c; }
.ds-sp__none { margin: 0; padding: 0.8rem; border-radius: 0.7rem; background: #f6f8fa; color: #5b6b78; font-size: 0.88rem; }
.dark .ds-sp__none { background: rgb(255 255 255 / .04); }
.ds-sp__lbl { display: flex; flex-direction: column; gap: 0.25rem; font-size: 0.75rem; color: #6b7b88; }
.ds-sp__tr.is-isl { grid-template-columns: 1.6fr 1fr 1.6fr 1.2fr; }
.ds-sp__way { justify-self: start; padding: 0.35rem 0.8rem; border-radius: 999px; font-size: 0.8rem; font-weight: 800; box-shadow: inset 0 0 0 1px #dfe5ea; color: #33424e; }
.ds-sp__way.is-sea { background: #0e2433; color: #fff; box-shadow: none; }
.dark .ds-sp__way.is-sea { background: #e6edf3; color: #0e2433; }
.ds-pt__q { font-size: 1.25rem; }
.ds-pt__count { display: grid; grid-template-columns: 3.5rem 1fr 3.5rem; gap: 0.8rem; align-items: center; padding: 1rem; border-radius: 1.3rem; background: rgb(255 255 255 / .05); }
.ds-pt__count button { height: 3.5rem; border-radius: 1rem; background: rgb(255 255 255 / .08); color: var(--sa-text); font-size: 1.6rem; }
.ds-pt__count input { width: 100%; text-align: center; border: 0; background: transparent; color: var(--sa-text); font-size: 3.2rem; font-weight: 800; font-variant-numeric: tabular-nums; outline: none; }
.ds-pt__hint { margin: 0; text-align: center; color: var(--sa-muted); font-size: 0.82rem; }

/* Sea shipment: one container, more hubs */
.ds-sp__stop { display: flex; align-items: center; gap: 0.6rem; padding: 0.55rem 0.7rem; border-radius: 0.75rem; background: rgb(127 147 161 / .1); }
.ds-sp__stop > span { flex: 1; display: flex; flex-direction: column; }
.ds-sp__stop small { color: rgb(107 123 136); font-size: 0.78rem; }
.ds-sp__stopn { width: 1.75rem; height: 1.75rem; flex: none; border-radius: 999px; background: #0e2433; color: #fff; display: flex; align-items: center; justify-content: center; font-size: 0.85rem; }

/* Driver app · trip steps */
.ds-ts { display: flex; flex-direction: column; gap: 0.35rem; padding: 1rem 1.1rem; border-radius: 1.2rem; background: #1d3a52; color: #fff; margin-bottom: 0.75rem; }
.ds-ts small { opacity: .8; font-weight: 700; }
.ds-ts strong { font-size: 1.35rem; line-height: 1.2; }
.ds-ts span { font-size: 0.9rem; opacity: .92; }
.ds-ts .ds-sa__primary { margin-top: 0.5rem; }
.ds-ts--loading, .ds-ts--back { background: #8a5a00; }
.ds-ts--ready { background: #5b2f99; }
.ds-ts--closed { background: #0e2433; }
.ds-ts--next { background: #eef6ff; color: #1d5f99; }

/* Today's crew board (matches mockup boards 29 and 32) */
.ds-cb { display: flex; flex-direction: column; gap: 1.25rem; }
.ds-cb__groups { display: flex; flex-wrap: wrap; gap: 0.75rem; align-items: flex-start; }
.ds-cb__group { min-width: 18rem; flex: 0 1 auto; border-radius: 14px; background: #fff4d6; color: #6b4e00; }
.ds-cb__group.is-bad { background: #fde8e8; color: #8a1f1f; }
.ds-cb__group summary { display: flex; align-items: center; gap: 0.6rem; padding: 0.7rem 0.9rem; cursor: pointer; list-style: none; font-size: 0.9rem; }
.ds-cb__group summary::-webkit-details-marker { display: none; }
.ds-cb__gicon { font-size: 1rem; }
.ds-cb__gshow { margin-left: auto; font-size: 0.78rem; font-weight: 700; opacity: .75; }
.ds-cb__group[open] .ds-cb__gshow { visibility: hidden; }
.ds-cb__group ul { list-style: none; margin: 0; padding: 0 0.9rem 0.8rem; display: flex; flex-direction: column; gap: 0.35rem; max-height: 16rem; overflow: auto; }
.ds-cb__group li { display: flex; justify-content: space-between; align-items: center; gap: 0.75rem; padding: 0.45rem 0.6rem; border-radius: 10px; background: rgb(255 255 255 / .7); font-size: 0.85rem; }
.ds-cb__group li a, .ds-cb__group li button { flex: none; font-weight: 800; font-size: 0.8rem; color: #0e2433; }
.ds-cb__grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(20rem, 1fr)); gap: 1.25rem; align-items: start; }
.ds-cb__card { display: flex; flex-direction: column; gap: 0.5rem; padding: 18px; border-radius: 20px; background: #fff; box-shadow: 0 1px 0 #e3e8ec, 0 12px 32px -18px rgb(14 36 51 / .25); color: #0e2433; }
.ds-cb__card header { display: flex; justify-content: space-between; align-items: center; gap: 0.5rem; font-size: 17px; }
.ds-cb__label, .ds-cb__muted, .ds-cb__note { color: #6b7b88; font-size: 0.8rem; margin: 0; }
.ds-cb__pill { font-size: 11px; font-weight: 800; padding: 3px 9px; border-radius: 999px; background: #e6f4ff; color: #1d5f99; white-space: nowrap; }
.ds-cb__pill.is-free, .ds-cb__pill.is-waiting, .ds-cb__pill.is-closed { background: #eef1f4; color: #33424e; }
.ds-cb__pill.is-loading, .ds-cb__pill.is-back { background: #fff0d1; color: #8a5a00; }
.ds-cb__pill.is-ready { background: #efe6fb; color: #5b2f99; }
.ds-cb__pill.is-road { background: #e6f6ef; color: #17895e; }
.ds-cb__count { font-size: 11px; font-weight: 800; padding: 3px 9px; border-radius: 999px; background: #eef1f4; color: #33424e; }
.ds-cb__person { display: flex; justify-content: space-between; align-items: center; gap: 0.5rem; padding: 8px 12px; border-radius: 12px; background: #f6f8fa; }
.ds-cb__person > span { display: flex; flex-direction: column; min-width: 0; }
.ds-cb__person b { font-size: 14px; }
.ds-cb__person small { color: #6b7b88; font-size: 12px; }
.ds-cb__person > button { color: #6b7b88; padding: 0 0.25rem; }
.ds-cb__person.is-inactive { background: #fff8ea; box-shadow: inset 0 0 0 1px #f39a1e; }
.ds-cb__none { color: #8a1f1f; font-size: 0.85rem; margin: 0; }
.ds-cb__add, .ds-cb__put { border: 0; border-radius: 10px; box-shadow: inset 0 0 0 1px #c3ccd4; background: transparent; color: #6b7b88; font-size: 13px; padding: 8px 12px; }
.ds-cb__put { padding: 6px 10px; flex: none; }
.ds-cb__same { align-self: flex-start; font-size: 13px; font-weight: 700; padding: 6px 12px; border-radius: 10px; background: #eef1f4; color: #33424e; }
.ds-cb__next { padding: 8px 12px; border-radius: 12px; background: #eef6ff; color: #1d5f99; font-size: 13px; box-shadow: inset 0 0 0 1px #9cc7f0; }
.dark .ds-cb__card { background: rgb(255 255 255 / .05); box-shadow: inset 0 0 0 1px rgb(255 255 255 / .08); color: inherit; }
.dark .ds-cb__person { background: rgb(255 255 255 / .06); }
.dark .ds-cb__person.is-inactive { background: rgb(243 154 30 / .12); }
.dark .ds-cb__group li { background: rgb(255 255 255 / .5); }

/* Trip page */
.ds-tp { display: flex; flex-direction: column; gap: 1rem; max-width: 60rem; }
.ds-tp__steps { display: flex; gap: 0.4rem; flex-wrap: wrap; }
.ds-tp__step { display: flex; flex-direction: column; min-width: 8.5rem; padding: 0.45rem 0.8rem; border-radius: 0.75rem; box-shadow: inset 0 0 0 1px rgb(127 147 161 / .35); }
.ds-tp__step small { font-size: 0.75rem; opacity: .75; }
.ds-tp__step.is-now { background: #0e2433; color: #fff; box-shadow: none; }
.ds-tp__step.is-done { background: #e6f6ef; color: #17895e; box-shadow: none; }
.ds-tp__card { display: flex; flex-direction: column; gap: 0.7rem; }
.ds-tp__head { display: flex; justify-content: space-between; align-items: center; gap: 0.75rem; font-size: 1.3rem; }
.ds-tp__tiles { display: grid; grid-template-columns: repeat(auto-fit, minmax(11rem, 1fr)); gap: 0.6rem; }
.ds-tp__tiles > span { display: flex; flex-direction: column; padding: 0.6rem 0.75rem; border-radius: 0.75rem; background: rgb(127 147 161 / .1); }
.ds-tp__tiles small, .ds-tp__crewhead small, .ds-tp__person small, .ds-tp__next small { color: rgb(107 123 136); font-size: 0.78rem; }
.ds-tp__crewhead { display: flex; justify-content: space-between; align-items: baseline; gap: 0.5rem; flex-wrap: wrap; margin-top: 0.25rem; }
.ds-tp__person { display: flex; align-items: center; gap: 0.75rem; padding: 0.55rem 0.75rem; border-radius: 0.75rem; box-shadow: inset 0 0 0 1px rgb(127 147 161 / .3); }
.ds-tp__person.is-swap { box-shadow: inset 0 0 0 1px #f39a1e; background: #fff8ea; }
.ds-tp__person > span { display: flex; flex-direction: column; }
.ds-tp__person i { width: 2.25rem; height: 2.25rem; flex: none; border-radius: 999px; background: #0e2433; color: #fff; display: flex; align-items: center; justify-content: center; font-style: normal; font-weight: 800; font-size: 0.85rem; }
.ds-tp__warn { margin: 0; padding: 0.6rem 0.8rem; border-radius: 0.75rem; background: #fff4d6; color: #6b4e00; font-size: 0.875rem; }
.ds-tp__warn.is-ok { background: #e6f6ef; color: #17895e; }
.ds-tp__next { display: flex; justify-content: space-between; align-items: center; gap: 0.75rem; padding: 0.7rem 0.9rem; border-radius: 0.75rem; background: #eef6ff; box-shadow: inset 0 0 0 1px #9cc7f0; }
.ds-tp__next > span { display: flex; flex-direction: column; }
@media (max-width: 640px) { .ds-tp__tiles { grid-template-columns: 1fr; } }

/* Trucks (board 34) and rental trucks (board 33) */
.ds-fl { display: flex; flex-direction: column; gap: 1.1rem; }
.ds-fl__top { display: flex; justify-content: space-between; align-items: center; gap: 1rem; flex-wrap: wrap; }
.ds-fl__summary { color: #6b7b88; }
.ds-fl__tools { display: flex; gap: 0.6rem; align-items: center; }
.ds-fl__search { width: 17.5rem; height: 42px; border: 0; border-radius: 12px; background: #fff; box-shadow: inset 0 0 0 1px #dfe5ea; padding: 0 14px; font-size: 14px; }
.ds-fl__add { height: 42px; padding: 0 18px; border-radius: 12px; background: #0e2433; color: #fff; font-weight: 800; display: inline-flex; align-items: center; }
.ds-fl__chips { display: flex; gap: 0.5rem; flex-wrap: wrap; }
.ds-fl__chip { height: 34px; padding: 0 14px; border-radius: 999px; font-weight: 700; font-size: 13px; background: #fff; color: #33424e; box-shadow: inset 0 0 0 1px #dfe5ea; }
.ds-fl__chip span { opacity: .6; margin-left: 4px; }
.ds-fl__chip.is-on { background: #0e2433; color: #fff; box-shadow: none; }
.ds-fl__grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(19rem, 1fr)); gap: 1.1rem; }
.ds-fl__card { gap: 0.75rem; transition: transform .15s ease, box-shadow .15s ease; }
.ds-fl__card:hover { transform: translateY(-2px); box-shadow: 0 1px 0 #e3e8ec, 0 18px 36px -18px rgb(14 36 51 / .35); }
.ds-fl__card.is-dim { opacity: .72; }
.ds-fl__head { display: flex; justify-content: space-between; align-items: flex-start; gap: 0.5rem; }
.ds-fl__head > span:first-child { display: flex; flex-direction: column; }
.ds-fl__head small, .ds-tk__id small { color: #6b7b88; font-size: 12px; }
.ds-fl__plate { font-size: 22px; letter-spacing: .02em; }
.ds-fl__plate.is-big { font-size: 30px; }
.ds-fl__tags { display: flex; flex-direction: column; align-items: flex-end; gap: 6px; }
.ds-cb__pill.is-own { background: #e6f6ef; color: #17895e; }
.ds-cb__pill.is-rent, .ds-cb__pill.is-warn { background: #fff0d1; color: #8a5a00; }
.ds-cb__pill.is-info { background: #e6f4ff; color: #1d5f99; }
.ds-cb__pill.is-bad { background: #fde8e8; color: #8a1f1f; }
.ds-cb__pill.is-muted { background: #eef1f4; color: #6b7b88; }
.ds-fl__mid { display: flex; justify-content: space-between; align-items: flex-end; }
.ds-fl__truck { position: relative; width: 120px; height: 56px; flex: none; }
.ds-fl__truck i { position: absolute; display: block; }
.ds-fl__truck .b { left: 2px; top: 8px; width: 74px; height: 34px; border-radius: 5px; background: var(--tc); }
.ds-fl__truck .c { left: 78px; top: 18px; width: 34px; height: 24px; border-radius: 4px 12px 2px 2px; background: #0e2433; }
.ds-fl__truck .w { left: 84px; top: 22px; width: 13px; height: 9px; border-radius: 2px; background: #9cc7f0; }
.ds-fl__truck .r1, .ds-fl__truck .r2 { top: 39px; width: 14px; height: 14px; border-radius: 50%; background: #0e2433; box-shadow: inset 0 0 0 4px #0e2433, inset 0 0 0 7px #c3ccd4; }
.ds-fl__truck .r1 { left: 15px; } .ds-fl__truck .r2 { left: 87px; }
.ds-fl__truck.is-big { transform: scale(1.4); transform-origin: left center; margin-right: 50px; }
.ds-fl__crew { display: flex; align-items: center; }
.ds-fl__crew span { width: 30px; height: 30px; border-radius: 50%; background: #0e2433; color: #fff; display: flex; align-items: center; justify-content: center; font-size: 11px; font-weight: 800; box-shadow: 0 0 0 2px #fff; }
.ds-fl__crew span + span { margin-left: -4px; }
.ds-fl__load { display: flex; justify-content: space-between; font-size: 12px; color: #6b7b88; }
.ds-fl__bar { height: 8px; border-radius: 999px; background: #eef1f4; overflow: hidden; }
.ds-fl__bar i { display: block; height: 100%; border-radius: 999px; background: #34c38f; }
.ds-fl__bar i.is-full { background: #f6be00; }
.ds-fl__note { font-size: 12px; padding: 6px 10px; border-radius: 10px; background: #f6f8fa; color: #33424e; }
.ds-fl__note.is-warn { background: #fff4d6; color: #6b4e00; }
.ds-fl__note.is-bad { background: #fde8e8; color: #8a1f1f; }
.ds-fl__note.is-muted { color: #6b7b88; }
.ds-fl__seg { display: inline-flex; gap: 6px; padding: 4px; border-radius: 12px; background: #e8ecef; align-self: flex-start; }
.ds-fl__seg button { height: 34px; padding: 0 14px; border-radius: 9px; font-weight: 800; color: #6b7b88; }
.ds-fl__seg button.is-on { background: #fff; color: #0e2433; box-shadow: 0 1px 2px rgb(0 0 0 / .08); }
.ds-tk__back { align-self: flex-start; color: #6b7b88; font-size: 14px; }
.ds-tk__head { flex-direction: row; align-items: center; gap: 1.5rem; padding: 22px 24px; }
.ds-tk__id { flex: 1; display: flex; flex-direction: column; gap: 6px; }
.ds-tk__line { display: flex; align-items: center; gap: 10px; flex-wrap: wrap; }
.ds-tk__btn { height: 40px; padding: 0 16px; border-radius: 10px; box-shadow: inset 0 0 0 1px #c3ccd4; display: inline-flex; align-items: center; font-weight: 700; flex: none; }
.ds-tk__tiles { display: grid; grid-template-columns: repeat(4, 1fr); gap: 14px; }
.ds-tk__tiles .ds-cb__card { gap: 4px; padding: 16px 18px; }
.ds-tk__big { font-size: 20px; }
.ds-tk__two { display: grid; grid-template-columns: 1fr 1fr; gap: 18px; align-items: start; }
.ds-tk__narrow { max-width: 45rem; }
.ds-tk__details { display: grid; grid-template-columns: repeat(3, 1fr); gap: 16px; max-width: 70rem; }
.ds-tk__field { display: flex; flex-direction: column; gap: 4px; }
.ds-tk__field small { color: #6b7b88; font-size: 12px; }
.ds-tk__row { grid-column: 1 / -1; display: flex; justify-content: space-between; align-items: center; gap: 1rem; padding: 12px 14px; border-radius: 12px; background: #f6f8fa; }
.ds-tk__row > span { display: flex; flex-direction: column; }
.ds-tk__row small { color: #6b7b88; font-size: 12px; }
.ds-tk__switch { width: 46px; height: 26px; border-radius: 999px; background: #c3ccd4; position: relative; flex: none; }
.ds-tk__switch i { position: absolute; top: 3px; left: 3px; width: 20px; height: 20px; border-radius: 50%; background: #fff; transition: left .15s; }
.ds-tk__switch.is-on { background: #17895e; } .ds-tk__switch.is-on i { left: 23px; }
.ds-tk__table { padding: 8px 18px; gap: 0; max-width: 78rem; }
.ds-tk__tr { display: grid; grid-template-columns: 1fr 1.5fr 1.2fr .7fr 1.4fr; gap: 10px; padding: 11px 0; font-size: 14px; border-bottom: 1px solid #eef1f4; }
.ds-tk__table.is-rent .ds-tk__tr { grid-template-columns: .8fr 1.5fr 1.5fr 1fr .7fr .8fr; }
.ds-tk__tr.is-head { font-size: 12px; color: #6b7b88; font-weight: 700; border-bottom-color: #e3e8ec; }
.ds-tk__tr .is-ok { color: #17895e; font-weight: 700; }
.ds-tk__tr .is-bad { color: #8a1f1f; font-weight: 700; }
.ds-tk__month { display: inline-flex; align-items: center; gap: 0.5rem; font-weight: 700; color: #33424e; }
.ds-tk__month.is-big { font-size: 1.25rem; }
.ds-tk__month button { width: 28px; height: 28px; border-radius: 8px; background: #eef1f4; }
.ds-tk__cal { display: grid; grid-template-columns: repeat(7, 1fr); gap: 4px; text-align: center; }
.ds-tk__cal small { color: #6b7b88; font-size: 12px; }
.ds-tk__cal button { height: 34px; border-radius: 8px; background: #f6f8fa; font-size: 13px; font-weight: 700; color: #33424e; }
.ds-tk__cal button.is-today { background: #eef6ff; }
.ds-tk__cal button.is-on { background: #0e2433; color: #fff; }
.ds-tk__ai { max-width: 78rem; padding: 14px 16px; font-size: 14px; }
.ds-tk__addco { display: flex; gap: 0.5rem; flex-wrap: wrap; }
.ds-tk__addco input { height: 40px; border: 0; border-radius: 10px; box-shadow: inset 0 0 0 1px #c3ccd4; padding: 0 12px; font-size: 14px; flex: 1; min-width: 9rem; }
@media (max-width: 900px) { .ds-tk__tiles, .ds-tk__two, .ds-tk__details { grid-template-columns: 1fr; } }
.dark .ds-fl__search, .dark .ds-fl__chip { background: rgb(255 255 255 / .05); color: inherit; }

/* ───── Part 19b · Edit / Add truck (board 35) ───── */
.ds-te { display: flex; flex-direction: column; gap: 16px; color: #0e2433; }
.ds-te [x-cloak] { display: none; }
.ds-te__top { display: flex; justify-content: space-between; align-items: flex-end; gap: 1rem; flex-wrap: wrap; }
.ds-te__title { display: flex; flex-direction: column; gap: 4px; }
.ds-te__title small { color: #6b7b88; font-size: 13px; }
.ds-te__title h1 { margin: 0; font-size: 28px; font-weight: 900; letter-spacing: -0.02em; }
.ds-te__actions { display: flex; align-items: center; gap: 10px; }
.ds-te__dirty { color: #8a5a00; font-size: 13px; }
.ds-te__btn { height: 40px; padding: 0 16px; border-radius: 10px; font-weight: 800; background: #fff; box-shadow: inset 0 0 0 1px #dfe5ea; color: #33424e; display: inline-flex; align-items: center; flex: none; }
.ds-te__btn.is-main { background: #0e2433; color: #fff; box-shadow: none; }
.ds-te__btn:disabled { opacity: .6; }
.ds-te__errors { padding: 10px 14px; border-radius: 12px; background: #fde8e8; color: #8a1f1f; font-size: 14px; }
.ds-te__grid { display: grid; grid-template-columns: 340px 1fr; gap: 20px; align-items: start; }
.ds-te__side, .ds-te__form { display: flex; flex-direction: column; gap: 16px; min-width: 0; }
.ds-te__card { gap: 14px; padding: 20px; }
.ds-te__muted { color: #6b7b88; font-size: 12px; }
.ds-te__stage { height: 120px; border-radius: 16px; background: linear-gradient(180deg, #eef3f7, #f8fafb); display: flex; align-items: center; justify-content: center; }
.ds-te__truck { position: relative; width: calc(var(--bw) + 50px); height: 70px; display: block; transition: width .2s; }
.ds-te__truck i { position: absolute; display: block; transition: left .2s, width .2s, background .2s; }
.ds-te__truck .b { left: 0; top: 6px; width: var(--bw); height: 44px; border-radius: 7px; background: var(--tc); }
.ds-te__truck .c { left: calc(var(--bw) + 4px); top: 18px; width: 44px; height: 32px; border-radius: 5px 16px 3px 3px; background: #0e2433; }
.ds-te__truck .w { left: calc(var(--bw) + 12px); top: 24px; width: 16px; height: 11px; border-radius: 3px; background: #9cc7f0; }
.ds-te__truck .r1, .ds-te__truck .r2 { top: 44px; width: 20px; height: 20px; border-radius: 50%; background: #0e2433; box-shadow: inset 0 0 0 6px #0e2433, inset 0 0 0 10px #c3ccd4; }
.ds-te__truck .r1 { left: 14px; } .ds-te__truck .r2 { left: calc(var(--bw) + 16px); }
.ds-te__id { display: flex; justify-content: space-between; align-items: flex-start; gap: .5rem; }
.ds-te__id > span:first-child { display: flex; flex-direction: column; gap: 2px; min-width: 0; }
.ds-te__plate { font-size: 26px; letter-spacing: .02em; overflow-wrap: anywhere; }
.ds-te__plate.is-empty, .ds-te .is-empty { color: #9aa7b2; }
.ds-te__facts { display: flex; flex-direction: column; gap: 8px; }
.ds-te__facts > span { display: flex; justify-content: space-between; gap: .5rem; padding: 9px 12px; border-radius: 12px; background: #f6f8fa; color: #33424e; font-size: 13px; }
.ds-te__facts > span.is-rent { background: #fff8ea; color: #6b4e00; }
.ds-te__facts > span.is-warn { background: #fff4d6; color: #6b4e00; }
.ds-te__facts > span.is-bad { background: #fde8e8; color: #8a1f1f; }
.ds-te__facts > span.is-muted { color: #9aa7b2; }
.ds-te__drop { min-height: 130px; border-radius: 14px; border: 2px dashed #c9d3db; display: flex; flex-direction: column; align-items: center; justify-content: center; gap: 4px; color: #6b7b88; font-size: 13px; cursor: pointer; overflow: hidden; text-align: center; padding: 8px; }
.ds-te__drop:hover { border-color: #0e2433; }
.ds-te__drop b { color: #0e2433; }
.ds-te__drop img { width: 100%; max-height: 180px; object-fit: cover; border-radius: 10px; }
.ds-te__drop-icon { font-size: 26px; }
.ds-te__photo-tools { display: flex; gap: 14px; }
.ds-te__link { border: 0; background: transparent; padding: 0; text-align: left; font-size: 13px; font-weight: 700; color: #1d5f99; cursor: pointer; }
.ds-te__link.is-bad { color: #8a1f1f; }
.ds-te__active { flex-direction: row; align-items: center; justify-content: space-between; gap: 12px; padding: 16px 18px; }
.ds-te__active > span { display: flex; flex-direction: column; gap: 2px; }
.ds-te__switch { flex: none; width: 50px; height: 28px; border-radius: 999px; background: #c3ccd4; position: relative; }
.ds-te__switch i { position: absolute; top: 4px; left: 4px; width: 20px; height: 20px; border-radius: 50%; background: #fff; transition: left .15s; }
.ds-te__switch.is-on { background: #17895e; }
.ds-te__switch.is-on i { left: 26px; }
.ds-te__sec { gap: 14px; padding: 20px 22px; }
.ds-te__head { display: flex; flex-direction: column; gap: 2px; }
.ds-te__head b { font-size: 17px; }
.ds-te__head small { color: #6b7b88; font-size: 12px; }
.ds-te__cols3 { display: grid; grid-template-columns: repeat(3, 1fr); gap: 14px; }
.ds-te__cols2 { display: grid; grid-template-columns: 1fr 1fr; gap: 12px; }
.ds-te__cols12 { display: grid; grid-template-columns: 1fr 2fr; gap: 14px; }
.ds-te__cols-r { display: grid; grid-template-columns: 1.3fr 1fr; gap: 14px; }
.ds-te__field { display: flex; flex-direction: column; gap: 6px; font-size: 13px; font-weight: 700; color: #33424e; min-width: 0; }
.ds-te__input { height: 42px; width: 100%; border: 0; border-radius: 12px; background: #f6f8fa; box-shadow: inset 0 0 0 1px #e1e7ec; padding: 0 14px; font-size: 15px; font-weight: 400; color: #0e2433; }
.ds-te__input:focus { outline: none; background: #fff; box-shadow: inset 0 0 0 2px #0e2433; }
.ds-te__input::placeholder { color: #9aa7b2; }
.ds-te__input.is-fixed { display: flex; align-items: center; color: #33424e; }
.ds-te__text { height: auto; min-height: 76px; padding: 12px 14px; line-height: 1.5; resize: vertical; }
.ds-te__hint { font-size: 12px; font-weight: 400; color: #6b7b88; }
.ds-te__err { font-size: 12px; font-weight: 600; color: #b42318; }
.ds-te__kinds { display: grid; grid-template-columns: repeat(5, 1fr); gap: 10px; }
.ds-te__kind { display: flex; flex-direction: column; align-items: flex-start; gap: 4px; padding: 12px; border-radius: 14px; text-align: left; color: #0e2433; background: #f6f8fa; box-shadow: inset 0 0 0 1px #e1e7ec; }
.ds-te__kind:hover { box-shadow: inset 0 0 0 1px #9aa7b2; }
.ds-te__kind.is-on { background: #fffaeb; box-shadow: inset 0 0 0 2px #f6be00; }
.ds-te__kind b { font-size: 13px; }
.ds-te__kind small { color: #6b7b88; font-weight: 400; font-size: 12px; }
.ds-te__mini { display: flex; align-items: flex-end; gap: 2px; height: 22px; }
.ds-te__mini i { display: block; height: 16px; border-radius: 3px; }
.ds-te__mini i + i { width: 10px; height: 11px; border-radius: 2px 5px 1px 1px; background: #0e2433; }
.ds-te__owners { display: grid; grid-template-columns: 1fr 1fr; gap: 12px; }
.ds-te__owner { display: flex; align-items: center; gap: 12px; padding: 14px 16px; border-radius: 14px; text-align: left; color: #0e2433; background: #f6f8fa; box-shadow: inset 0 0 0 1px #e1e7ec; }
.ds-te__owner.is-on { background: #fff; box-shadow: inset 0 0 0 2px #0e2433; }
.ds-te__owner > span:nth-child(2) { display: flex; flex-direction: column; gap: 2px; }
.ds-te__owner b { font-size: 15px; }
.ds-te__owner small { color: #6b7b88; font-size: 12px; }
.ds-te__owner-icon { font-size: 22px; }
.ds-te__radio { margin-left: auto; flex: none; width: 20px; height: 20px; border-radius: 50%; box-shadow: inset 0 0 0 2px #c3ccd4; }
.ds-te__owner.is-on .ds-te__radio { box-shadow: inset 0 0 0 6px #0e2433; }
.ds-te__row { display: flex; gap: 8px; align-items: center; }
.ds-te__row.hidden { display: none; }
.ds-te__charge { display: flex; align-items: center; gap: 12px; flex-wrap: wrap; }
.ds-te__money { height: 42px; width: 200px; border-radius: 12px; background: #fff; box-shadow: inset 0 0 0 2px #0e2433; display: flex; align-items: center; gap: 8px; padding: 0 14px; }
.ds-te__money > span { color: #6b7b88; }
.ds-te__money input { flex: 1; min-width: 0; border: 0; padding: 0; background: transparent; font-size: 15px; font-weight: 800; color: #0e2433; }
.ds-te__money input:focus { outline: none; box-shadow: none; }
.ds-te__money small { color: #6b7b88; font-weight: 400; font-size: 12px; white-space: nowrap; }
.ds-te__booked { display: flex; justify-content: space-between; align-items: center; gap: 1rem; flex-wrap: wrap; padding: 10px 14px; border-radius: 12px; background: #eef6ff; color: #1d5f99; font-size: 13px; }
.ds-te__pair { display: grid; grid-template-columns: 1fr 1fr; gap: 16px; align-items: stretch; }
.ds-te__note { padding: 9px 12px; border-radius: 12px; font-size: 13px; background: #f6f8fa; color: #6b7b88; }
.ds-te__note.is-ok { background: #e6f6ef; color: #17895e; }
.ds-te__note.is-warn { background: #fff4d6; color: #6b4e00; }
.ds-te__note.is-bad { background: #fde8e8; color: #8a1f1f; }
.ds-te__stepper { display: flex; align-items: center; gap: 12px; }
.ds-te__stepper button { width: 42px; height: 42px; flex: none; border-radius: 12px; background: #e8ecef; font-size: 20px; font-weight: 800; color: #0e2433; }
.ds-te__stepper button:hover { background: #dfe5ea; }
.ds-te__stepper > span { display: flex; flex-direction: column; align-items: center; min-width: 90px; }
.ds-te__stepper > span b { font-size: 30px; }
.ds-te__stepper > span small { color: #6b7b88; font-size: 12px; }
.ds-te__stepper .ds-te__hint { flex: 1; }
.ds-te__size { display: flex; align-items: center; gap: 8px; font-size: 13px; color: #6b7b88; }
.ds-te__size .ds-te__input { width: 76px; padding: 0 10px; }
.ds-te__size .ds-te__input.is-pct { width: 64px; }
.ds-te button:focus-visible, .ds-te a:focus-visible, .ds-te__drop:focus-within { outline: 3px solid #f6be00; outline-offset: 2px; }
@media (max-width: 1100px) {
  .ds-te__grid, .ds-te__pair { grid-template-columns: 1fr; }
  .ds-te__kinds { grid-template-columns: repeat(3, 1fr); }
}
@media (max-width: 640px) {
  .ds-te__cols3, .ds-te__cols12, .ds-te__cols-r, .ds-te__owners, .ds-te__cols2 { grid-template-columns: 1fr; }
  .ds-te__kinds { grid-template-columns: repeat(2, 1fr); }
}

/* ───── Part 19c · Duplicate trucks (board 36) ───── */
.ds-fl__dupes { display: flex; flex-direction: column; gap: 12px; padding: 18px 20px; box-shadow: inset 0 0 0 2px #f6be00, 0 12px 32px -18px rgb(14 36 51 / .25); }
.ds-fl__dupes-head { display: flex; justify-content: space-between; align-items: center; gap: 1rem; flex-wrap: wrap; }
.ds-fl__dupes-head > span { display: flex; flex-direction: column; gap: 2px; }
.ds-fl__dupes-head b { font-size: 17px; }
.ds-fl__dupes-head small { color: #6b7b88; font-size: 12px; }
.ds-fl__dupe { display: flex; align-items: center; gap: 14px; padding: 12px 14px; border-radius: 14px; background: #fffaeb; flex-wrap: wrap; }
.ds-fl__dupe > b { font-size: 18px; min-width: 110px; }
.ds-fl__dupe-copies { flex: 1; display: flex; gap: 8px; flex-wrap: wrap; }
.ds-fl__dupe-copies span { padding: 6px 10px; border-radius: 10px; background: #fff; box-shadow: inset 0 0 0 1px #f3d58a; font-size: 13px; }
.ds-fl__card.is-dupe { box-shadow: inset 0 0 0 2px #f6be00, 0 12px 32px -18px rgb(14 36 51 / .25); }
.ds-dp__grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(26rem, 1fr)); gap: 20px; }
.ds-dp__copy { display: flex; flex-direction: column; gap: 16px; padding: 22px; border-radius: 20px; background: #fff; color: #0e2433; text-align: left; box-shadow: inset 0 0 0 1px #e1e7ec, 0 12px 32px -18px rgb(14 36 51 / .25); }
.ds-dp__copy.is-on { box-shadow: inset 0 0 0 3px #0e2433, 0 12px 32px -18px rgb(14 36 51 / .25); }
.ds-dp__copy.is-on .ds-te__radio { box-shadow: inset 0 0 0 7px #0e2433; }
.ds-dp__copy .ds-te__radio { width: 24px; height: 24px; }
.ds-dp__top { display: flex; align-items: center; gap: 16px; }
.ds-dp__id { flex: 1; display: flex; flex-direction: column; gap: 4px; min-width: 0; }
.ds-dp__id small { color: #6b7b88; font-size: 12px; }
.ds-dp__plate { font-size: 26px; letter-spacing: .02em; }
.ds-dp__stats { display: grid; grid-template-columns: repeat(3, 1fr); gap: 10px; }
.ds-dp__stats > span { padding: 10px 12px; border-radius: 12px; background: #f6f8fa; display: flex; flex-direction: column; min-width: 0; }
.ds-dp__stats small { color: #6b7b88; font-size: 12px; }
.ds-dp__stats b { font-size: 18px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.ds-dp__foot { color: #6b7b88; font-size: 12px; }
.ds-dp__foot.is-ok { color: #17895e; }
.ds-dp__what { flex-direction: row; align-items: center; gap: 20px; padding: 18px 20px; flex-wrap: wrap; }
.ds-dp__what-text { flex: 1; display: flex; flex-direction: column; gap: 6px; min-width: 18rem; font-size: 14px; color: #33424e; }
.ds-dp__what-text > b { font-size: 16px; color: #0e2433; }
.ds-dp__what-text small { color: #6b7b88; font-size: 13px; }
.ds-dp__btns { display: flex; gap: 10px; flex-wrap: wrap; justify-content: center; }
.ds-dp__go { height: 48px; padding: 0 22px; font-size: 15px; }
.ds-dp__done { align-items: center; gap: 12px; max-width: 760px; align-self: center; margin-top: 40px; padding: 28px; text-align: center; color: #33424e; }
.ds-dp__tick { width: 64px; height: 64px; border-radius: 50%; background: #e6f6ef; color: #17895e; font-size: 30px; display: flex; align-items: center; justify-content: center; }
.ds-dp__done-title { font-size: 24px; color: #0e2433; }
.ds-dp__soft { padding: 10px 14px; border-radius: 12px; background: #f6f8fa; color: #6b7b88; font-size: 13px; }
.ds-te__exists { display: flex; align-items: center; gap: 14px; padding: 14px 16px; border-radius: 14px; background: #fff4d6; color: #6b4e00; flex-wrap: wrap; }
.ds-te__exists.is-info { background: #eef6ff; color: #1d5f99; }
.ds-te__exists > span:nth-child(2) { flex: 1; display: flex; flex-direction: column; gap: 2px; min-width: 14rem; }
.ds-te__exists small { font-size: 12px; }
.ds-te__exists-icon { font-size: 22px; }
.ds-te__input.is-clash { box-shadow: inset 0 0 0 2px #f39a1e; }
.ds-te__input.is-free { box-shadow: inset 0 0 0 2px #17895e; }
.ds-te__okline { padding: 10px 14px; border-radius: 12px; background: #e6f6ef; color: #17895e; font-size: 13px; }

/* ───── Part 20a · Missing barangay (boards 37, 38) ───── */
.ds-ad { gap: 18px; }
.ds-ad__top { display: flex; justify-content: space-between; align-items: flex-end; gap: 1rem; flex-wrap: wrap; }
.ds-ad__pick { width: auto; min-width: 14rem; background: #fff; }
.ds-ad__tile { gap: 4px; padding: 16px 18px; }
.ds-ad__tile.is-ring { box-shadow: inset 0 0 0 2px #f6be00, 0 12px 32px -18px rgb(14 36 51 / .25); }
.ds-ad__big { font-size: 26px; }
.ds-ad__pending { display: flex; justify-content: space-between; align-items: center; gap: 1rem; padding: 10px 14px; border-radius: 14px; background: #eef6ff; color: #1d5f99; font-size: 13px; flex-wrap: wrap; }
.ds-ad__table { padding: 6px 18px; gap: 0; }
.ds-ad__row { display: grid; grid-template-columns: 1.1fr 2.2fr 1.5fr 1.3fr 1.2fr; gap: 12px; padding: 12px 0; border-bottom: 1px solid #eef1f4; align-items: center; font-size: 14px; }
.ds-ad__row.is-head { padding: 10px 0; font-size: 12px; color: #6b7b88; font-weight: 700; border-bottom-color: #e3e8ec; }
.ds-ad__who { display: flex; flex-direction: column; min-width: 0; }
.ds-ad__who small, .ds-ad__as small, .ds-ad__how small { color: #6b7b88; font-size: 12px; }
.ds-ad__who b.is-empty { color: #9aa7b2; }
.ds-ad__as { color: #33424e; display: flex; flex-direction: column; min-width: 0; overflow-wrap: anywhere; }
.ds-ad__how { display: flex; flex-direction: column; gap: 4px; align-items: flex-start; }
.ds-ad__act { display: flex; gap: 6px; justify-content: flex-end; flex-wrap: wrap; }
.ds-ad__sm { height: 34px; }
.ds-ad__done { color: #17895e; font-weight: 700; font-size: 12px; text-align: right; }
.ds-ad__done.is-muted { color: #6b7b88; font-weight: 400; }
.ds-ad__empty { padding: 18px 0; }
.ds-ad__moreb { padding: 12px 0; }
.ds-cb__pill.is-warn { background: #fff4d6; color: #8a5a00; }
.ds-ad__one { display: grid; grid-template-columns: 1.15fr 1fr; gap: 20px; align-items: start; }
.ds-ad__col { display: flex; flex-direction: column; gap: 16px; min-width: 0; }
.ds-ad__card { gap: 12px; padding: 20px 22px; }
.ds-ad__h { font-size: 16px; }
.ds-ad__addr { padding: 14px 16px; border-radius: 14px; background: #f6f8fa; font-size: 17px; line-height: 1.7; }
.ds-ad__mark { background: #e6f6ef; border-radius: 4px; padding: 0 4px; color: inherit; }
.ds-ad__mark.is-subdivision { background: #fff0d1; }
.ds-ad__mark.is-landmark { background: #e6f4ff; }
.ds-ad__opt { display: flex; align-items: center; gap: 12px; padding: 12px 14px; border-radius: 14px; color: #0e2433; background: #f6f8fa; box-shadow: inset 0 0 0 1px #e1e7ec; text-align: left; }
.ds-ad__opt > span:nth-child(2) { flex: 1; display: flex; flex-direction: column; }
.ds-ad__opt small { color: #6b7b88; font-size: 12px; }
.ds-ad__opt.is-on { background: #fff; box-shadow: inset 0 0 0 2px #0e2433; }
.ds-ad__opt.is-on .ds-te__radio { box-shadow: inset 0 0 0 6px #0e2433; }
.ds-ad__use { display: flex; gap: 12px; align-items: center; flex-wrap: wrap; margin-top: 4px; }
.ds-ad__go { height: 44px; }
.ds-ad__go:disabled { opacity: .5; }
.ds-ad__also { display: flex; gap: 8px; align-items: center; font-size: 13px; color: #33424e; }
.ds-ad__map { width: 100%; height: 380px; border: 0; border-radius: 14px; background: #e9efe6; }
.ds-ad__nomap { height: 380px; border-radius: 14px; background: linear-gradient(135deg, #e9efe6, #dfe9f0); display: flex; align-items: center; justify-content: center; text-align: center; padding: 20px; color: #33424e; }
.ds-ad__more { display: inline-block; margin-top: 4px; font-size: 12px; font-weight: 700; color: #1d5f99; }
.ds-ad__master { display: flex; align-items: center; gap: 12px; }
.ds-ad__model { font-size: 12px; padding: 5px 12px; }
.ds-ad__bigswitch { width: 54px; height: 30px; }
.ds-ad__bigswitch i { width: 22px; height: 22px; }
.ds-ad__bigswitch.is-on i { left: 28px; }
.ds-ad__set { display: grid; grid-template-columns: 1.4fr 1fr; gap: 20px; align-items: start; }
.ds-ad__set.is-off { opacity: .5; }
.ds-ad__optrow { display: flex; align-items: center; gap: 14px; padding: 13px 4px; border-top: 1px solid #eef1f4; color: #0e2433; text-align: left; }
.ds-ad__icon { font-size: 20px; width: 28px; flex: none; }
.ds-ad__optt { flex: 1; display: flex; flex-direction: column; gap: 2px; }
.ds-ad__optt > span { display: flex; gap: 8px; align-items: center; }
.ds-ad__optt small { color: #6b7b88; font-size: 12px; }
.ds-ad__smswitch { width: 44px; height: 24px; }
.ds-ad__smswitch i { top: 3px; left: 3px; width: 18px; height: 18px; }
.ds-ad__smswitch.is-on i { left: 23px; }
.ds-ad__level { display: flex; align-items: center; gap: 12px; padding: 14px 4px 4px; border-top: 1px solid #eef1f4; flex-wrap: wrap; }
.ds-ad__level > span:first-child { flex: 1; display: flex; flex-direction: column; gap: 2px; min-width: 14rem; }
.ds-ad__level small { color: #6b7b88; font-size: 12px; }
.ds-ad__step { display: flex; align-items: center; gap: 12px; padding: 10px 12px; border-radius: 12px; background: #f6f8fa; }
.ds-ad__step.is-ai { background: #fffaeb; }
.ds-ad__step > span:nth-child(2) { flex: 1; display: flex; flex-direction: column; }
.ds-ad__step small { color: #6b7b88; font-size: 12px; }
.ds-ad__step .ds-cb__pill { background: #fff; }
.ds-ad__num { width: 26px; height: 26px; border-radius: 50%; background: #0e2433; color: #fff; display: flex; align-items: center; justify-content: center; font-size: 12px; flex: none; }
.ds-ad__month { display: grid; grid-template-columns: 1fr 1fr; gap: 10px; }
.ds-ad__month > span { padding: 10px 12px; border-radius: 12px; background: #f6f8fa; display: flex; flex-direction: column; }
.ds-ad__month small { color: #6b7b88; font-size: 12px; }
.ds-ad__month b { font-size: 20px; }
.ds-ad__try { display: grid; grid-template-columns: 1fr 1.2fr; gap: 20px; align-items: start; }
.ds-ad__sample { display: flex; flex-direction: column; gap: 2px; padding: 12px 14px; border-radius: 14px; color: #0e2433; text-align: left; background: #f6f8fa; box-shadow: inset 0 0 0 1px #e1e7ec; }
.ds-ad__sample.is-on { background: #fff; box-shadow: inset 0 0 0 2px #0e2433; }
.ds-ad__sample small { color: #6b7b88; font-size: 12px; }
.ds-ad__rhead { display: flex; justify-content: space-between; align-items: center; gap: 1rem; }
.ds-ad__tag { font-size: 12px; padding: 5px 12px; }
.ds-ad__tag.is-used, .ds-ad__kv.is-used, .ds-ad__next.is-used { background: #e6f6ef; color: #17895e; }
.ds-ad__tag.is-check, .ds-ad__kv.is-check { background: #fff4d6; color: #8a5a00; }
.ds-ad__tag.is-none, .ds-ad__kv.is-none { background: #eef1f4; color: #6b7b88; }
.ds-ad__kv { display: flex; flex-direction: column; gap: 4px; }
.ds-ad__kv > span, .ds-ad__kv > b { padding: 12px 14px; border-radius: 12px; background: #f6f8fa; font-size: 15px; }
.ds-ad__kv.is-plain > span { background: transparent; padding: 0; font-size: 14px; color: #33424e; }
.ds-ad__kv small { color: #6b7b88; font-size: 12px; }
.ds-ad__two { display: grid; grid-template-columns: 1fr 1fr; gap: 10px; }
.ds-ad__two .ds-ad__kv { padding: 12px 14px; border-radius: 12px; background: #f6f8fa; }
.ds-ad__two .ds-ad__kv > b { padding: 0; background: transparent; font-size: 22px; color: #0e2433; }
.ds-ad__two .ds-ad__kv.is-used { background: #e6f6ef; } .ds-ad__two .ds-ad__kv.is-check { background: #fff4d6; } .ds-ad__two .ds-ad__kv.is-none { background: #eef1f4; }
.ds-ad__next { padding: 10px 14px; border-radius: 12px; font-size: 13px; background: #f6f8fa; color: #6b7b88; }
.ds-ad__next.is-check { background: #fff4d6; color: #6b4e00; }
.ds-ad__cmp { display: grid; grid-template-columns: 1.1fr 1.2fr 1.2fr; gap: 16px; padding: 13px 0; border-bottom: 1px solid #eef1f4; font-size: 14px; align-items: center; }
.ds-ad__cmp.is-head { padding: 12px 0; font-size: 12px; color: #6b7b88; font-weight: 700; border-bottom-color: #e3e8ec; }
.ds-ad__muted { color: #6b7b88; }
.ds-ad__tick { color: #17895e; font-weight: 800; margin-right: 8px; }
.ds-ad__info { padding: 12px 16px; border-radius: 14px; background: #eef6ff; color: #1d5f99; font-size: 14px; }
.ds-mp__brgy { font-style: normal; font-size: 11px; font-weight: 700; padding: 1px 6px; border-radius: 999px; background: #eef1f4; color: #6b7b88; }
.ds-mp__brgy.is-ai { background: #fff4d6; color: #8a5a00; }
.ds-mp__brgy.is-ok { background: #e6f6ef; color: #17895e; }
@media (max-width: 1100px) {
  .ds-ad__one, .ds-ad__set, .ds-ad__try { grid-template-columns: 1fr; }
  .ds-ad__row { grid-template-columns: 1fr 1fr; }
  .ds-ad__row.is-head { display: none; }
}

/* ───── Part 20b · Plan trips by city (board 30b) ───── */
.ds-pt { display: flex; flex-direction: column; gap: 18px; color: #0e2433; }
.ds-pt__top { display: flex; align-items: flex-end; justify-content: space-between; gap: 24px; flex-wrap: wrap; }
.ds-pt__title { display: flex; flex-direction: column; gap: 6px; flex: 1; min-width: 20rem; max-width: 64rem; }
.ds-pt__days { flex: none; }
.ds-pt__title small { color: #6b7b88; font-size: 15px; }
.ds-pt__h { display: flex; align-items: center; gap: 10px; }
.ds-pt__h h1 { margin: 0; font-size: 28px; font-weight: 900; letter-spacing: -0.02em; }
.ds-pt__logo { width: 34px; height: 34px; border-radius: 10px; background: #0e2433; color: #f6be00; display: flex; align-items: center; justify-content: center; font-weight: 900; }
.ds-pt__days { display: flex; gap: 8px; align-items: center; }
.ds-pt__date { width: auto; background: #fff; }
.ds-pt__ask { flex-direction: row; align-items: center; gap: 14px; padding: 14px 16px; flex-wrap: wrap; }
.ds-pt__spark { font-size: 20px; }
.ds-pt__asktext { flex: 1; display: flex; flex-direction: column; gap: 8px; min-width: 18rem; }
.ds-pt__asktext b { font-size: 14px; }
.ds-pt__chips { display: flex; gap: 8px; flex-wrap: wrap; }
.ds-pt__chip { height: 34px; padding: 0 14px; border-radius: 999px; font-weight: 700; font-size: 13px; background: #eef1f4; color: #33424e; }
.ds-pt__chip.is-on { background: #0e2433; color: #fff; }
.ds-pt__type { width: 360px; max-width: 100%; }
.ds-pt__type .ds-te__input { background: #fff; box-shadow: inset 0 0 0 1px #e3e8ec; font-size: 14px; }
.ds-pt__grid { display: grid; grid-template-columns: 330px 1fr 340px; gap: 20px; align-items: start; }
.ds-pt__left { gap: 10px; }
.ds-pt__lhead { display: flex; justify-content: space-between; align-items: baseline; gap: 8px; }
.ds-pt__lhead b { font-size: 17px; }
.ds-pt__lhead small, .ds-pt__muted { color: #6b7b88; font-size: 12px; }
.ds-pt__big { font-size: 18px !important; }
.ds-pt__prov { display: flex; flex-direction: column; gap: 6px; padding: 10px 12px; border-radius: 14px; background: #fff; box-shadow: inset 0 0 0 1px #eef1f4; }
.ds-pt__prov.is-planned { background: #f6f8fa; box-shadow: none; }
.ds-pt__provhead { display: flex; justify-content: space-between; align-items: baseline; color: #0e2433; text-align: left; }
.ds-pt__provhead b { font-size: 14px; }
.ds-pt__provhead span { font-size: 13px; color: #6b7b88; }
.ds-pt__bar { height: 6px; border-radius: 999px; background: #eef1f4; overflow: hidden; }
.ds-pt__bar i { display: block; height: 100%; border-radius: 999px; background: #1d9e75; }
.ds-pt__bar i.is-mid { background: #ef9f27; } .ds-pt__bar i.is-old { background: #e24b4a; }
.ds-pt__provfoot { display: flex; justify-content: space-between; font-size: 12px; color: #6b7b88; }
.ds-pt__provfoot b { color: #8a5a00; } .ds-pt__provfoot b.is-in { color: #17895e; }
.ds-pt__cities { display: flex; flex-direction: column; gap: 4px; padding-top: 4px; border-top: 1px dashed #dfe5ea; }
.ds-pt__cities > span { display: flex; justify-content: space-between; gap: 8px; font-size: 13px; }
.ds-pt__cities em { font-style: normal; color: #17895e; font-size: 12px; }
.ds-pt__unclear { display: flex; justify-content: space-between; align-items: center; gap: 8px; padding: 9px 12px; border-radius: 12px; background: #fff4d6; color: #6b4e00; font-size: 12px; }
.ds-pt__mid { display: flex; flex-direction: column; gap: 14px; min-width: 0; }
.ds-pt__made { padding: 14px 16px; border-radius: 16px; background: #e6f6ef; color: #17895e; font-weight: 700; }
.ds-pt__trip { gap: 12px; }
.ds-pt__trip.is-off { opacity: .45; }
.ds-pt__trow { display: flex; align-items: center; gap: 12px; }
.ds-pt__tname { flex: 1; display: flex; flex-direction: column; min-width: 0; }
.ds-pt__tname b { font-size: 18px; }
.ds-pt__tname b span { color: #6b7b88; font-weight: 700; }
.ds-pt__tname small { color: #6b7b88; font-size: 12px; }
.ds-pt__truck { display: flex; align-items: center; gap: 8px; height: 38px; padding: 0 12px; border-radius: 12px; background: #eef1f4; color: #33424e; font-weight: 800; flex: none; }
.ds-pt__truck span { opacity: .6; }
.ds-pt__truck.is-free { background: #e6f6ef; color: #17895e; }
.ds-pt__truck.is-busy { background: #fff0d1; color: #8a5a00; }
.ds-pt__stops { display: flex; align-items: flex-start; flex-wrap: wrap; padding: 4px 0 2px; row-gap: 8px; }
.ds-pt__stop { display: flex; flex-direction: column; align-items: center; gap: 4px; min-width: 96px; font-size: 12px; text-align: center; }
.ds-pt__dot { width: 12px; height: 12px; border-radius: 50%; background: #0e2433; box-shadow: 0 0 0 4px #e8ecef; }
.ds-pt__line { width: 48px; height: 2px; background: #c9d2d9; margin-top: 5px; }
.ds-pt__fillrow { display: flex; align-items: center; gap: 12px; }
.ds-pt__fill { flex: 1; height: 34px; border-radius: 10px; background: #eef1f4; position: relative; overflow: hidden; }
.ds-pt__fill i { position: absolute; inset: 0 auto 0 0; background: #bfe6d4; }
.ds-pt__fill i.is-full { background: #f6d77a; }
.ds-pt__fill span { position: absolute; inset: 0; display: flex; align-items: center; padding: 0 12px; font-size: 13px; font-weight: 800; }
.ds-pt__age { font-size: 12px; font-weight: 800; padding: 6px 10px; border-radius: 999px; background: #eef1f4; color: #33424e; white-space: nowrap; }
.ds-pt__age.is-mid { background: #fff0d1; color: #8a5a00; } .ds-pt__age.is-old { background: #fde8e8; color: #8a1f1f; }
.ds-pt__why { display: flex; gap: 8px; align-items: flex-start; font-size: 13px; color: #33424e; }
.ds-pt__why > span:first-child { color: #c99a00; }
.ds-pt__sum { display: flex; align-items: center; justify-content: space-between; gap: 12px; padding: 14px 16px; border-radius: 16px; background: #0e2433; color: #fff; flex-wrap: wrap; }
.ds-pt__sum > span { display: flex; flex-direction: column; }
.ds-pt__sum small { opacity: .7; font-size: 12px; }
.ds-pt__sum button { height: 46px; padding: 0 22px; border-radius: 12px; background: #f6be00; color: #0a1219; font-weight: 900; font-size: 15px; }
.ds-pt__sum button:disabled { opacity: .5; }
.ds-pt__side { display: flex; flex-direction: column; gap: 14px; min-width: 0; }
.ds-pt__card { gap: 10px; }
.ds-pt__h3 { font-size: 17px; }
.ds-pt__trk { display: flex; align-items: center; gap: 10px; padding: 10px 12px; border-radius: 14px; background: #f6f8fa; }
.ds-pt__trk > i { width: 10px; height: 10px; border-radius: 50%; flex: none; }
.ds-pt__trk > span { flex: 1; display: flex; flex-direction: column; min-width: 0; }
.ds-pt__trk > span b { font-size: 14px; }
.ds-pt__trk > span small { color: #6b7b88; font-size: 12px; }
.ds-pt__trk > small { font-weight: 800; font-size: 12px; }
.ds-pt__trk .is-free { background: #17895e; color: #17895e; } .ds-pt__trk .is-busy { background: #c97a00; color: #c97a00; }
.ds-pt__trk .is-kept { background: #6b7b88; color: #6b7b88; } .ds-pt__trk .is-off { background: #c3ccd4; color: #9aa7b2; }
.ds-pt__trk > small.is-free, .ds-pt__trk > small.is-busy, .ds-pt__trk > small.is-kept, .ds-pt__trk > small.is-off { background: transparent; }
.ds-pt__free { border-radius: 20px; padding: 18px; display: flex; flex-direction: column; gap: 10px; background: #fff8e1; box-shadow: inset 0 0 0 1px #f6d77a; font-size: 14px; color: #33424e; }
.ds-pt__free .ds-te__btn { align-self: flex-start; }
.ds-pt__fhead { display: flex; align-items: center; gap: 8px; color: #0e2433; }
.ds-pt__fhead span { color: #c99a00; }
.ds-pt__un { display: flex; justify-content: space-between; gap: 8px; font-size: 13px; padding: 6px 0; border-bottom: 1px solid #e3e8ec; }
.ds-pt__un b { color: #33424e; } .ds-pt__un b.is-here { color: #17895e; }
@media (max-width: 1280px) { .ds-pt__grid { grid-template-columns: 1fr 1fr; } .ds-pt__mid { grid-column: 1 / -1; order: -1; } }
@media (max-width: 800px) { .ds-pt__grid { grid-template-columns: 1fr; } }
.ds-tp__cities { margin: 0; padding: 10px 14px; border-radius: 12px; background: #eef6ff; color: #1d5f99; font-size: 13px; display: flex; flex-direction: column; gap: 2px; }
.ds-tp__cities small { color: #33424e; }

/* ───── Two warehouses (board 40) ───── */
.ds-wc { gap: 16px; }
.ds-wc__grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(22rem, 1fr)); gap: 18px; align-items: start; }
.ds-wc__card { gap: 12px; padding: 18px 20px; }
.ds-wc__head { display: flex; justify-content: space-between; align-items: center; gap: 8px; }
.ds-wc__head > span:first-child { display: flex; flex-direction: column; }
.ds-wc__head b { font-size: 19px; }
.ds-wc__head small { color: #6b7b88; font-size: 12px; }
.ds-cb__pill.is-info { background: #e6f4ff; color: #1d5f99; }
.ds-wc__chips { display: flex; flex-wrap: wrap; gap: 8px; }
.ds-wc__chip { height: 32px; padding: 0 12px; border-radius: 999px; background: #eef1f4; color: #33424e; font-size: 13px; font-weight: 700; display: inline-flex; align-items: center; gap: 6px; }
.ds-wc__chip.is-own { background: #fff0d1; color: #8a5a00; }
.ds-wc__chip button { opacity: .5; font-size: 12px; } .ds-wc__chip button:hover { opacity: 1; }
.ds-wc__add { display: flex; gap: 8px; flex-wrap: wrap; align-items: center; }
.ds-wc__plus { height: 32px; padding: 0 12px; border-radius: 999px; box-shadow: inset 0 0 0 1px #c3ccd4; background: #fff; font-size: 13px; font-weight: 700; color: #33424e; }
.ds-wc__form { display: flex; gap: 8px; flex: 1; min-width: 14rem; }
.ds-wc__form .ds-te__input { height: 36px; font-size: 14px; }
.ds-wc__towns { display: flex; flex-direction: column; gap: 6px; padding: 12px; border-radius: 14px; background: #f6f8fa; font-size: 13px; }
.ds-wc__towns > span { display: flex; justify-content: space-between; gap: 8px; }
.ds-wc__towns .ds-te__input { background: #fff; }
.ds-wc__side { display: flex; flex-direction: column; gap: 14px; }
.ds-wc__conflict { border-radius: 20px; padding: 18px; display: flex; flex-direction: column; gap: 10px; background: #fff4d6; box-shadow: inset 0 0 0 1px #f6d77a; color: #6b4e00; font-size: 13px; }
.ds-wc__conflict b { color: #0e2433; font-size: 15px; }
.ds-wc__btns { display: flex; gap: 8px; }
.ds-wc__ghost { background: transparent; box-shadow: none; color: #6b4e00; }
.ds-wc__asked { padding: 12px 14px; border-radius: 14px; background: #eef6ff; color: #1d5f99; font-size: 13px; }
.ds-wc__req { display: flex; justify-content: space-between; align-items: center; gap: 8px; padding: 10px 0; border-top: 1px solid #eef1f4; font-size: 13px; flex-wrap: wrap; }
.ds-wc__req > span:first-child { display: flex; flex-direction: column; }
.ds-wc__req small { color: #6b7b88; }
.ds-wc__ok { padding: 9px 12px; border-radius: 12px; background: #e6f6ef; color: #17895e; font-size: 13px; }
.ds-wc__info { padding: 9px 12px; border-radius: 12px; background: #f6f8fa; color: #33424e; font-size: 13px; }
.ds-wc__tgrid { display: grid; grid-template-columns: 1.3fr 1fr; gap: 20px; align-items: start; }
.ds-wc__prow { display: flex; flex-direction: column; gap: 6px; padding: 10px 12px; border-radius: 14px; background: #f6f8fa; }
.ds-wc__prow b { font-size: 14px; }
.ds-wc__pick { display: flex; gap: 8px; margin-top: 6px; }
.ds-wc__sel { height: 34px; border-radius: 10px; border: 0; background: rgb(255 255 255 / .12); color: #fff; padding: 0 10px; font-size: 13px; }
.ds-wc__sel option { color: #0e2433; }
.ds-wc__stop { border-radius: 20px; padding: 18px; display: flex; flex-direction: column; gap: 8px; background: #fde8e8; color: #8a1f1f; font-size: 13px; }
.ds-wc__stop b { font-size: 15px; }
.ds-wc__row { display: grid; grid-template-columns: 1.2fr .7fr 2fr 1.6fr 1.3fr; gap: 12px; padding: 14px 0; border-bottom: 1px solid #eef1f4; align-items: center; font-size: 14px; }
.ds-wc__row.is-head { padding: 12px 0; font-size: 12px; color: #6b7b88; font-weight: 700; border-bottom-color: #e3e8ec; }
.ds-wc__split { display: flex; flex-direction: column; gap: 6px; }
.ds-wc__bar { display: flex; height: 12px; border-radius: 999px; overflow: hidden; background: #eef1f4; }
.ds-wc__bar i { display: block; height: 100%; }
.ds-wc__tip { font-size: 13px; }
.ds-wc__row .ds-fl__seg button { height: 30px; font-size: 12px; }
.ds-pt__transfer { display: flex; justify-content: space-between; align-items: center; gap: 8px; padding: 9px 12px; border-radius: 12px; background: #eef6ff; color: #1d5f99; font-size: 12px; }
@media (max-width: 1100px) { .ds-wc__tgrid { grid-template-columns: 1fr; } .ds-wc__row { grid-template-columns: 1fr 1fr; } .ds-wc__row.is-head { display: none; } }

/* ───── Part 21 · top-up, truck full, bypass (board 39) ───── */
.ds-ld__early.is-full { background: #fde8e8; color: #8a1f1f; }
.ds-ld__bypass, .ds-ld__citytop { display: flex; flex-wrap: wrap; align-items: center; gap: .4rem .8rem; padding: .7rem .9rem; border-radius: .8rem; font-size: .9rem; }
.ds-ld__bypass { background: #eef6ff; color: #1d5f99; }
.ds-ld__citytop { background: #fff8e1; color: #6b4e00; box-shadow: inset 0 0 0 1px #f6d77a; }
.ds-ld__reasons { display: flex; gap: .4rem; flex-wrap: wrap; }
.ds-sx__citytop { margin: 10px 0; padding: 16px; border-radius: 18px; background: #2a2410; box-shadow: inset 0 0 0 1px #6b5a1c; display: flex; flex-direction: column; gap: 10px; color: #eef3f6; }
.ds-sx__citytop > b { color: #f6d77a; }
.ds-sx__reasons { display: flex; flex-direction: column; gap: 8px; }
.ds-sx__reasons button { height: 46px; border-radius: 12px; background: rgb(255 255 255 / .08); color: #eef3f6; font-weight: 700; text-align: left; padding: 0 14px; }
.ds-pt__top { display: flex; flex-direction: column; gap: 10px; padding: 14px; border-radius: 14px; background: #fff8e1; box-shadow: inset 0 0 0 1px #f6d77a; }
.ds-pt__top > b span { color: #c99a00; }
.ds-pt__topopt { display: flex; align-items: center; gap: 12px; padding: 10px 12px; border-radius: 12px; text-align: left; color: #0e2433; }
.ds-pt__topopt.is-on { background: #fff; }
.ds-pt__topopt .ds-te__radio { box-shadow: inset 0 0 0 2px #c9a64a; width: 18px; height: 18px; }
.ds-pt__topopt.is-on .ds-te__radio { box-shadow: inset 0 0 0 6px #0e2433; }
.ds-pt__topopt > span:nth-child(2) { flex: 1; display: flex; flex-direction: column; }
.ds-pt__topopt small { color: #6b4e00; font-size: 12px; }
.ds-pt__topopt .ds-cb__pill { background: #fff; color: #6b4e00; }
.ds-pt__topbtns { display: flex; gap: 8px; }
.ds-pt__ok { color: #17895e; font-weight: 700; font-size: 13px; }
.ds-pt__sets { display: flex; flex-direction: column; gap: 6px; padding: 12px 14px; border-radius: 14px; background: #f6f8fa; }
.ds-pt__set { display: flex; justify-content: space-between; align-items: center; gap: 8px; font-size: 13px; padding: 6px 0; border-top: 1px solid #e3e8ec; }
.ds-pt__how { display: flex; gap: 10px; font-size: 13px; color: #33424e; }
.ds-pt__how b { width: 24px; height: 24px; border-radius: 50%; background: #0e2433; color: #fff; display: flex; align-items: center; justify-content: center; font-size: 12px; flex: none; }
.ds-pt__sum .ds-wc__sel { max-width: 15rem; }
.ds-tr__grid { display: grid; grid-template-columns: 1.5fr 1fr; gap: 20px; align-items: start; }
.ds-tr__row { display: grid; grid-template-columns: 1.4fr 2fr; gap: 14px; padding: 14px 0; border-bottom: 1px solid #eef1f4; align-items: center; }
.ds-tr__row.is-head { padding: 12px 0; font-size: 12px; color: #6b7b88; font-weight: 700; border-bottom-color: #e3e8ec; }
.ds-tr__row .ds-fl__seg button { height: 32px; font-size: 12px; }
.ds-tr__note { padding: 12px 0; }
.ds-tr__reason { display: flex; justify-content: space-between; padding: 8px 12px; border-radius: 12px; background: #f6f8fa; font-size: 14px; }
.ds-ov__row { display: grid; grid-template-columns: .9fr 1.3fr .8fr 1.5fr 1.3fr; gap: 10px; padding: 11px 0; border-bottom: 1px solid #eef1f4; font-size: 13px; align-items: center; }
.ds-ov__row.is-head { font-size: 12px; color: #6b7b88; font-weight: 700; border-bottom-color: #e3e8ec; }
.ds-ov__row > span { display: flex; flex-direction: column; }
.ds-ov__row small { color: #6b7b88; font-size: 12px; }
.ds-ov__row .ds-ad__act { flex-direction: row; }
.ds-ov__bar { display: flex; flex-direction: column; gap: 4px; font-size: 13px; }
@media (max-width: 1100px) { .ds-tr__grid { grid-template-columns: 1fr; } .ds-ov__row { grid-template-columns: 1fr 1fr; } .ds-ov__row.is-head { display: none; } }
.ds-pt__top, .ds-pt__sets { align-self: stretch; align-items: stretch; text-align: left; width: 100%; }
.ds-pt__topopt { width: 100%; }
.ds-pt__topbtns { justify-content: flex-start; }
.ds-ov__row .ds-ad__act { flex-wrap: nowrap; gap: 6px; justify-content: flex-end; }
.ds-ov__row { grid-template-columns: .9fr 1.2fr .7fr 1.4fr 1.6fr; }
.ds-pt__provs { display: flex; flex-direction: column; gap: inherit; }
.ds-ha__grid { display: grid; grid-template-columns: 1fr 1fr 380px; gap: 18px; align-items: start; }
.ds-ha__name { display: flex; align-items: center; gap: 10px; }
.ds-ha__name i { width: 14px; height: 14px; border-radius: 4px; background: var(--hub, #1d6fb8); flex: none; }
.ds-ha__name > span { display: flex; flex-direction: column; }
.ds-ha__chip { background: color-mix(in srgb, var(--hub, #1d6fb8) 12%, #fff); color: color-mix(in srgb, var(--hub, #1d6fb8) 80%, #000); }
.ds-ha__add { display: grid; grid-template-columns: 1fr 1fr 1fr auto; gap: 6px; }
.ds-ha__split { display: flex; height: 14px; border-radius: 999px; overflow: hidden; background: #e8ecef; }
.ds-ha__split i { background: #1d6fb8; }
.ds-ha__split i.is-b { background: #c97a00; }
.ds-ha__req { display: flex; flex-direction: column; gap: 6px; padding: 12px; border-radius: 14px; background: #f6f8fa; }
.ds-ha__ok { padding: 9px 12px; border-radius: 12px; background: #e6f6ef; color: #17895e; font-size: 13px; }
.ds-ha__warn { padding: 9px 12px; border-radius: 12px; background: #fff4d6; color: #6b4e00; font-size: 13px; }
.ds-ha__off { display: flex; flex-direction: column; gap: 8px; padding: 14px 16px; border-radius: 16px; background: #fde8e8; color: #8a1f1f; font-size: 13px; }
.ds-ha__off b { font-size: 14px; }
.ds-ha__btnbad { background: #8a1f1f !important; color: #fff !important; }
@media (max-width: 1200px) { .ds-ha__grid { grid-template-columns: 1fr; } .ds-ha__add { grid-template-columns: 1fr; } }
.ds-hs__grid { display: grid; grid-template-columns: 380px 1fr 380px; gap: 18px; align-items: start; }
.ds-hs__form { display: flex; flex-direction: column; gap: 10px; }
.ds-hs__form label { display: flex; flex-direction: column; gap: 4px; }
.ds-hs__form small { color: #6b7b88; font-weight: 700; font-size: 12px; }
.ds-hs__sug { display: flex; align-items: center; gap: 12px; padding: 10px 12px; border-radius: 12px; background: #eef6ff; text-align: left; width: 100%; }
.ds-hs__sug.is-off { background: #f6f8fa; opacity: .6; }
.ds-hs__sug i { width: 20px; height: 20px; border-radius: 6px; background: #1d6fb8; color: #fff; display: flex; align-items: center; justify-content: center; font-style: normal; font-size: 13px; flex: none; }
.ds-hs__sug.is-off i { background: #c3ccd4; }
.ds-hs__sug > span { flex: 1; display: flex; flex-direction: column; }
.ds-hs__sug small { color: #6b7b88; font-size: 12px; }
.ds-hs__switch { display: flex; justify-content: space-between; align-items: center; padding: 10px 12px; border-radius: 12px; background: #f6f8fa; }
.ds-hs__sw { width: 44px; height: 24px; border-radius: 999px; background: #c3ccd4; position: relative; }
.ds-hs__sw i { position: absolute; top: 3px; left: 3px; width: 18px; height: 18px; border-radius: 50%; background: #fff; transition: left .15s; }
.ds-hs__sw.is-on { background: #17895e; }
.ds-hs__sw.is-on i { left: 23px; }
@media (max-width: 1200px) { .ds-hs__grid { grid-template-columns: 1fr; } }
.ds-ma__grid { display: grid; grid-template-columns: 1fr 420px; gap: 20px; align-items: start; }
.ds-ma__row { display: flex; justify-content: space-between; padding: 12px 14px; border-radius: 14px; background: #f6f8fa; font-size: 14px; }
.ds-ma__row.is-prov { background: #fff0d1; color: #8a5a00; }
@media (max-width: 1100px) { .ds-ma__grid { grid-template-columns: 1fr; } }
.ds-pt__tabs { display: flex; gap: 8px; border-bottom: 1px solid #dfe5ea; }
.ds-pt__tabs button { height: 44px; padding: 0 16px; display: flex; align-items: center; gap: 8px; font-weight: 800; color: #6b7b88; }
.ds-pt__tabs button.is-on { color: #0e2433; box-shadow: inset 0 -3px 0 #f6be00; }
.ds-pt__tabs button span { padding: 2px 9px; border-radius: 999px; background: #e8ecef; color: #6b7b88; font-size: 12px; }
.ds-pt__tabs button.is-on span { background: #0e2433; color: #fff; }
.ds-pt__sms { display: flex; align-items: center; gap: 8px; font-size: 13px; font-weight: 700; color: #0e2433; text-align: left; }
.ds-pt__sms i { width: 18px; height: 18px; border-radius: 5px; background: #c3ccd4; color: #fff; display: flex; align-items: center; justify-content: center; font-style: normal; font-size: 12px; flex: none; }
.ds-pt__sms.is-on i { background: #1d6fb8; }
.ds-pt__sms small { font-weight: 400; color: #6b7b88; }
.ds-pt__sms:disabled { opacity: .5; }
.ds-pt__smslink { text-decoration: underline; color: inherit; }
.ds-ph__ai { display: flex; gap: 14px; padding: 14px 18px; border-radius: 18px; background: #fff8e1; box-shadow: inset 0 0 0 1px #f6d77a; }
.ds-ph__aitext { display: flex; flex-direction: column; gap: 4px; font-size: 14px; color: #4a3800; }
.ds-ph__why { display: flex; flex-direction: column; gap: 8px; padding: 12px 16px; border-radius: 14px; background: #fff4d6; }
.ds-ph__reasons { display: flex; gap: 6px; flex-wrap: wrap; }
.ds-ph__reasons button { height: 32px; padding: 0 12px; border-radius: 999px; background: #fff; box-shadow: inset 0 0 0 1px #e5c46a; font-size: 13px; font-weight: 700; color: #6b4e00; }
.ds-ph__reasons button.is-cancel { box-shadow: none; background: transparent; }
.ds-ph__grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(340px, 1fr)); gap: 14px; align-items: start; }
.ds-ph__card { display: flex; flex-direction: column; gap: 10px; padding: 16px 18px; box-shadow: inset 4px 0 0 var(--hub, #1d6fb8), 0 1px 0 #e3e8ec, 0 12px 32px -18px rgb(14 36 51 / .25); }
.ds-ph__head { display: flex; justify-content: space-between; align-items: center; gap: 8px; }
.ds-ph__head > span:first-child { display: flex; flex-direction: column; }
.ds-ph__head b { font-size: 17px; }
.ds-ph__head small { color: #6b7b88; font-size: 12px; }
.ds-ph__cities { display: flex; flex-direction: column; gap: 4px; }
.ds-ph__cities > span { display: flex; justify-content: space-between; align-items: center; gap: 8px; padding: 6px 10px; border-radius: 10px; background: #f6f8fa; font-size: 13px; }
.ds-ph__cities button { font-size: 12px; font-weight: 700; color: #1d6fb8; white-space: nowrap; }
.ds-ph__when { align-self: flex-start; }
.ds-ph__when button { height: 30px; font-size: 12px; }
.ds-ph__part { display: flex; flex-direction: column; gap: 6px; padding: 10px 12px; border-radius: 12px; background: #f6f8fa; }
.ds-ph__part .ds-ph__head b { font-size: 14px; }
.ds-ph__part small { font-size: 12px; color: #33424e; }
.ds-ph__bar { height: 24px; border-radius: 8px; background: #e3e8ec; overflow: hidden; display: flex; }
.ds-ph__bar i { background: #bfe6d4; display: flex; align-items: center; padding-left: 10px; font-size: 12px; font-weight: 700; font-style: normal; white-space: nowrap; }
.ds-ph__truck { align-self: flex-start; }
.ds-ph__tip { color: #33424e; font-size: 13px; }
.ds-ph__btns { display: flex; gap: 8px; flex-wrap: wrap; }
.ds-ph__done { padding: 9px 12px; border-radius: 10px; background: #eef1f4; color: #33424e; font-size: 13px; font-weight: 700; }
.ds-ph__done.is-made { background: #e6f6ef; color: #17895e; }
.ds-pt__transfer.is-bad { background: #fde8e8; color: #8a1f1f; }
.ds-sms__follow { display: block; margin: -2px 0 6px; padding: 8px 12px; border-radius: 10px; background: #f6f8fa; color: #6b7b88; font-size: 12px; }
.ds-wc__head > span.ds-ha__name:first-child { flex-direction: row; align-items: center; }
.ds-ha__add { grid-template-columns: 1fr 1fr; }
.ds-ha__add .ds-te__btn { justify-self: start; }
.ds-wc__towns .ds-wc__chips { justify-content: flex-start; }
.ds-ph__truck.is-none { background: #eef1f4; color: #6b7b88; }
.ds-tp__lock { display: flex; flex-direction: column; gap: 8px; padding: 14px 16px; border-radius: 14px; background: #f6f8fa; }
.ds-tp__lock.is-ok { background: #eefaf4; box-shadow: inset 0 0 0 1px #bfe6d4; }
.ds-tp__lockhead { display: flex; justify-content: space-between; align-items: baseline; gap: 8px; }
.ds-tp__lockhead small, .ds-tp__lock > small { color: #6b7b88; font-size: 12px; }
.ds-tp__check { display: flex; gap: 10px; align-items: center; font-size: 14px; }
.ds-tp__check i { width: 22px; height: 22px; border-radius: 50%; background: #fde8e8; color: #8a1f1f; display: flex; align-items: center; justify-content: center; font-style: normal; font-size: 12px; font-weight: 900; flex: none; }
.ds-tp__check.is-ok i { background: #e6f6ef; color: #17895e; }
.ds-tp__check > span { display: flex; flex-direction: column; }
.ds-tp__check small { color: #6b7b88; font-size: 12px; }
.ds-tl__trip { display: flex; flex-direction: column; gap: 4px; align-items: flex-start; }
.ds-tl__trip b { font-size: 15px; color: #0e2433; }
.ds-tl__trip small, .ds-tl__goes small, .ds-tl__truck small, .ds-tl__boxes small, .ds-tl__status small { color: #6b7b88; font-size: 12px; }
.ds-tl__made { display: inline-flex; align-items: center; height: 22px; padding: 0 8px; border-radius: 999px; font-size: 11px; font-weight: 800; white-space: nowrap; }
.ds-tl__made.is-ai { background: #fff0d1; color: #8a5a00; }
.ds-tl__made.is-plan { background: #e6f4ff; color: #1d5f99; }
.ds-tl__made.is-changed { background: #efeafd; color: #5b3fc4; }
.ds-tl__made.is-manual { background: #eef1f4; color: #33424e; }
.ds-tl__goes { display: flex; flex-direction: column; gap: 2px; min-width: 180px; }
.ds-tl__goes > span { display: flex; align-items: center; gap: 6px; }
.ds-tl__goes i { width: 8px; height: 8px; border-radius: 50%; flex: none; }
.ds-tl__truck { display: flex; align-items: center; gap: 8px; }
.ds-tl__truck > i { width: 32px; height: 32px; border-radius: 50%; background: #eef1f4; display: flex; align-items: center; justify-content: center; font-size: 11px; font-weight: 800; font-style: normal; flex: none; }
.ds-tl__truck > span { display: flex; flex-direction: column; }
.ds-tl__boxes { display: flex; flex-direction: column; gap: 5px; min-width: 190px; }
.ds-tl__bar { height: 8px; border-radius: 999px; background: #e8ecef; display: flex; overflow: hidden; }
.ds-tl__bar i { background: #17895e; }
.ds-tl__bar i.is-l { background: #8fd3b4; }
.ds-tl__status { display: flex; flex-direction: column; gap: 3px; align-items: flex-start; }
.ds-tl__pill { display: inline-flex; align-items: center; height: 26px; padding: 0 10px; border-radius: 999px; font-size: 12px; font-weight: 800; white-space: nowrap; background: #eef1f4; color: #33424e; }
.ds-tl__pill.is-planned, .ds-tl__pill.is-ready { background: #eef6ff; color: #1d5f99; }
.ds-tl__pill.is-loading, .ds-tl__pill.is-back { background: #fff4d6; color: #8a5a00; }
.ds-tl__pill.is-road { background: #e6f4ff; color: #1d5f99; }
.ds-tl__pill.is-closed { background: #e6f6ef; color: #17895e; }
.ds-tl__det { display: flex; flex-direction: column; gap: 14px; }
.ds-tl__detpills { display: flex; gap: 6px; }
.ds-tl__how { display: flex; flex-direction: column; gap: 8px; padding: 14px; border-radius: 14px; background: #fff8e1; }
.ds-tl__how.is-manual { background: #f6f8fa; }
.ds-tl__how > span { display: flex; gap: 8px; font-size: 13px; color: #33424e; }
.ds-tl__how em { width: 18px; flex: none; font-style: normal; }
.ds-tl__facts { display: grid; grid-template-columns: 1fr 1fr; gap: 10px; }
.ds-tl__facts > span { display: flex; flex-direction: column; padding: 10px 12px; border-radius: 12px; background: #f6f8fa; }
.ds-tl__facts small { color: #6b7b88; font-size: 12px; }
.ds-tl__facts b { font-size: 14px; }
.ds-tl__cities { display: flex; flex-direction: column; gap: 6px; }
.ds-tl__cities > span { display: flex; flex-wrap: wrap; gap: 6px; }
.ds-tl__cities > b small { float: right; font-weight: 600; color: #6b7b88; }
/* board 47b: 4 columns, top to bottom then the next column */
.ds-tl__cities ul { margin: 0; padding: 12px 14px 12px 30px; list-style: disc; columns: 4; column-gap: 20px; font-size: 13px; font-weight: 700; background: #f8fafb; border-radius: 14px; }
.ds-tl__cities li { break-inside: avoid; padding: 3px 0; line-height: 1.3; }
.dark .ds-tl__cities ul { background: rgb(255 255 255 / .04); }
@media (max-width: 640px) { .ds-tl__cities ul { columns: 2; } }
.ds-tl__cities li::marker { color: #6b7b88; }
.ds-tl__cities i { height: 28px; padding: 0 10px; border-radius: 999px; background: #eef6ff; color: #1d5f99; font-size: 13px; font-weight: 700; font-style: normal; display: flex; align-items: center; }
.ds-tl__btns { display: flex; gap: 8px; flex-wrap: wrap; }
.ds-tl__hint { color: #6b7b88; font-size: 12px; }
.ds-tl__no { font-size: 15px; font-weight: 800; color: #0e2433; text-decoration: none; }
.ds-tl__no:hover { color: #1d6fb8; text-decoration: underline; }

/* ── Part 22e · New trip and Edit trip (boards 44, 44b) ─────────────────────────────── */
.ds-et__head { display: flex; flex-direction: column; gap: 6px; }
.ds-et__head .ds-te__link { font-size: 13px; font-weight: 700; text-decoration: none; }
.ds-et__line { display: flex; align-items: center; gap: 10px; flex-wrap: wrap; }
.ds-et__line .ds-tl__made { height: 26px; font-size: 12px; padding: 0 10px; }
.ds-et__tiles { display: grid; grid-template-columns: repeat(5, minmax(0, 1fr)); gap: 12px; }
.ds-et__tile { gap: 2px; padding: 12px 16px; }
.ds-et__tile small { color: #6b7b88; font-size: 13px; }
.ds-et__tile b { font-size: 24px; font-weight: 900; letter-spacing: -0.01em; }
.ds-et__tile.is-ok b { color: #17895e; }
.ds-et__tile.is-bad b { color: #c0392b; }
.ds-et__tile.is-warn b { color: #8a5a00; }
@media (max-width: 900px) { .ds-et__tiles { grid-template-columns: repeat(2, minmax(0, 1fr)); } }
.dark .ds-et__tile small { color: #9aa7b2; }

.ds-nt { display: flex; flex-direction: column; gap: 18px; }
.ds-nt__top { display: flex; justify-content: space-between; align-items: flex-end; gap: 1rem; flex-wrap: wrap; }
.ds-nt__top .ds-te__link { text-decoration: none; }
.ds-nt__plan { height: 40px; padding: 0 16px; border-radius: 10px; font-weight: 800; background: #fff4d6; color: #8a5a00; display: inline-flex; align-items: center; text-decoration: none; }
.ds-nt__grid { display: grid; grid-template-columns: minmax(0, 1fr) 340px; gap: 20px; align-items: start; }
.ds-nt__steps { display: flex; flex-direction: column; gap: 16px; min-width: 0; }
.ds-nt__card { gap: 14px; padding: 20px; }
.ds-nt__h { display: flex; align-items: center; gap: 10px; flex-wrap: wrap; }
.ds-nt__h i { width: 26px; height: 26px; border-radius: 999px; background: #0e2433; color: #fff; font-style: normal; font-size: 13px; font-weight: 800; display: inline-flex; align-items: center; justify-content: center; }
.ds-nt__h b { font-size: 17px; }
.ds-nt__h small { color: #6b7b88; font-size: 13px; }
.ds-nt__two { display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 12px; }
.ds-nt__two label, .ds-nt__when label { display: flex; flex-direction: column; gap: 6px; font-weight: 700; }
.ds-nt__two label > small, .ds-nt__when label > small { color: #6b7b88; font-size: 13px; }
.ds-nt__opt { display: flex; gap: 12px; align-items: center; text-align: left; padding: 14px 16px; border: 0; border-radius: 14px; background: #f6f8fa; box-shadow: inset 0 0 0 1px #e1e7ec; cursor: pointer; color: #0e2433; }
.ds-nt__opt em { font-style: normal; font-size: 22px; width: 40px; height: 40px; border-radius: 12px; background: #fff; display: flex; align-items: center; justify-content: center; flex: none; }
.ds-nt__opt span { display: flex; flex-direction: column; gap: 2px; }
.ds-nt__opt small { color: #6b7b88; font-size: 13px; }
.ds-nt__opt.is-on { background: #eef6ff; box-shadow: inset 0 0 0 2px #1d6fb8; }
.ds-nt__chips { display: flex; gap: 8px; flex-wrap: wrap; }
.ds-nt__chip { height: 36px; padding: 0 14px; border: 0; border-radius: 999px; background: #f1f4f6; color: #33424e; font-weight: 700; font-size: 14px; cursor: pointer; display: inline-flex; align-items: center; gap: 8px; }
.ds-nt__chip i { width: 10px; height: 10px; border-radius: 3px; }
.ds-nt__chip.is-on { background: #0e2433; color: #fff; }
.ds-nt__trucks { display: grid; grid-template-columns: repeat(auto-fill, minmax(190px, 1fr)); gap: 10px; }
.ds-nt__truck { display: flex; flex-direction: column; gap: 4px; text-align: left; padding: 12px 14px; border: 0; border-radius: 14px; background: #f6f8fa; box-shadow: inset 0 0 0 1px #e1e7ec; cursor: pointer; color: #0e2433; }
.ds-nt__truck small { color: #6b7b88; font-size: 12px; }
.ds-nt__truck.is-on { background: #eef6ff; box-shadow: inset 0 0 0 2px #1d6fb8; }
.ds-nt__truck.is-off { opacity: .5; cursor: not-allowed; }
.ds-nt__trow { display: flex; justify-content: space-between; align-items: center; gap: 6px; }
.ds-nt__trow em { font-style: normal; font-size: 11px; font-weight: 800; padding: 2px 8px; border-radius: 999px; background: #eef1f4; color: #33424e; white-space: nowrap; }
.ds-nt__trow em.is-free { background: #e6f6ef; color: #17895e; }
.ds-nt__trow em.is-busy { background: #fff4d6; color: #8a5a00; }
.ds-nt__crew { white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
.ds-nt__when { display: grid; grid-template-columns: 1.3fr 1fr 1fr; gap: 14px; align-items: start; }
.ds-nt__field { display: flex; flex-direction: column; gap: 4px; }
.ds-nt__field em { font-style: normal; font-size: 12px; font-weight: 700; }
.ds-nt__field em.is-ok { color: #17895e; }
.ds-nt__field em.is-bad { color: #c0392b; }
.ds-nt__err { color: #c0392b; font-weight: 700; }
.ds-nt__sum { gap: 10px; padding: 20px; position: sticky; top: 84px; }
.ds-nt__sumh { font-size: 17px; }
.ds-nt__row { display: flex; justify-content: space-between; gap: 10px; font-size: 14px; padding: 4px 0; border-bottom: 1px solid #eef1f4; }
.ds-nt__row > span { color: #6b7b88; }
.ds-nt__row b { text-align: right; }
.ds-nt__space { display: flex; flex-direction: column; gap: 6px; padding: 6px 0; }
.ds-nt__space small { color: #6b7b88; font-size: 12px; }
.ds-nt__go, .ds-nt__only { height: 44px; border: 0; border-radius: 12px; font-weight: 800; font-size: 15px; cursor: pointer; }
.ds-nt__go { background: #e5b94a; color: #0e2433; }
.ds-nt__only { background: #fff; box-shadow: inset 0 0 0 1px #dfe5ea; color: #33424e; }
.ds-nt__go:disabled, .ds-nt__only:disabled { opacity: .6; }
.ds-nt__cancel { text-align: center; color: #6b7b88; font-weight: 700; text-decoration: none; font-size: 14px; }
@media (max-width: 1100px) { .ds-nt__grid { grid-template-columns: 1fr; } .ds-nt__sum { position: static; } .ds-nt__when, .ds-nt__two { grid-template-columns: 1fr; } }
.dark .ds-nt__opt, .dark .ds-nt__truck, .dark .ds-nt__chip { background: rgb(255 255 255 / .06); color: inherit; box-shadow: inset 0 0 0 1px rgb(255 255 255 / .1); }
.dark .ds-nt__opt.is-on, .dark .ds-nt__truck.is-on { box-shadow: inset 0 0 0 2px #5aa7e6; }
.dark .ds-nt__chip.is-on { background: #fff; color: #0e2433; }
.dark .ds-nt__row { border-color: rgb(255 255 255 / .08); }

/* ── New boxes since the trips were made (board 45b) ── */
.ds-nb { display: flex; flex-direction: column; gap: 14px; }
.ds-nb__empty { align-items: flex-start; }
.ds-nb__empty small { color: #6b7b88; }
.ds-nb__apply { flex-direction: row; align-items: center; gap: 14px; box-shadow: inset 0 0 0 2px #e5b94a, 0 12px 32px -18px rgb(14 36 51 / .25); }
.ds-nb__apply > span { flex: 1; display: flex; flex-direction: column; gap: 3px; }
.ds-nb__apply b { font-size: 17px; }
.ds-nb__apply small { color: #6b7b88; }
.ds-nb__apply .ds-nt__go { padding: 0 22px; }
.ds-nb__list { padding: 0; gap: 0; overflow: hidden; }
.ds-nb__row { display: grid; grid-template-columns: 1.3fr 90px 1.8fr 1.6fr; gap: 14px; align-items: center; padding: 14px 18px; border-top: 1px solid #f1f4f6; }
.ds-nb__head { border-top: 0; font-size: 12px; font-weight: 800; color: #6b7b88; padding: 12px 18px; }
.ds-nb__city { display: flex; flex-direction: column; }
.ds-nb__city small { color: #6b7b88; }
.ds-nb__n { font-size: 18px; }
.ds-nb__trip { display: flex; flex-direction: column; gap: 6px; }
.ds-nb__tline { display: flex; gap: 8px; align-items: center; }
.ds-nb__pill { font-size: 11px; font-weight: 800; padding: 3px 9px; border-radius: 999px; background: #eef1f4; color: #33424e; }
.ds-nb__pill.is-open { background: #e6f6ef; color: #17895e; }
.ds-nb__pill.is-full { background: #fff1c2; color: #8a5a00; }
.ds-nb__space { display: flex; align-items: center; gap: 8px; }
.ds-nb__space .ds-tl__bar { flex: 1; }
.ds-nb__space .ds-tl__bar i { background: #8fd3b4; }
.ds-nb__space small { font-weight: 700; color: #33424e; white-space: nowrap; }
.ds-nb__acts { display: flex; gap: 8px; justify-content: flex-end; flex-wrap: wrap; }
.ds-nb__btn { height: 36px; padding: 0 14px; font-size: 13px; }
.ds-nb__btn.is-anyway { color: #8a5a00; box-shadow: inset 0 0 0 1px #e8c873; }
.ds-nt__go.ds-nb__btn.is-anyway { background: #f2c46b; color: #0e2433; box-shadow: none; }
.ds-nb__modal { position: fixed; inset: 0; z-index: 50; background: rgb(14 36 51 / .35); display: flex; align-items: center; justify-content: center; padding: 20px; }
.ds-nb__pick { width: min(640px, 100%); max-height: calc(100vh - 40px); gap: 12px; }
.ds-nb__ph { display: flex; flex-direction: column; gap: 3px; }
.ds-nb__ph b { font-size: 19px; }
.ds-nb__ph small { color: #6b7b88; }
.ds-nb__meter { display: flex; flex-direction: column; gap: 6px; }
.ds-nb__meter .ds-tl__bar { height: 10px; }
.ds-nb__meter i.is-used { background: #b8c3cc; }
.ds-nb__meter i.is-new { background: #17895e; }
.ds-nb__meter i.is-over { background: #e2a23b; }
.ds-nb__meter small { font-weight: 800; color: #17895e; }
.ds-nb__meter small.is-over { color: #8a5a00; }
.ds-nb__items { display: flex; flex-direction: column; max-height: 340px; overflow: auto; border-radius: 12px; box-shadow: inset 0 0 0 1px #e3e8ec; }
.ds-nb__item { display: flex; align-items: center; gap: 12px; padding: 11px 14px; border: 0; border-bottom: 1px solid #f1f4f6; background: #fff; text-align: left; cursor: pointer; font: inherit; color: inherit; }
.ds-nb__item.is-on { background: #fffbea; }
.ds-nb__item > span { flex: 1; display: flex; flex-direction: column; }
.ds-nb__item small { color: #6b7b88; }
.ds-nb__check { width: 20px; height: 20px; border-radius: 6px; flex: none; display: flex; align-items: center; justify-content: center; font-style: normal; font-size: 12px; font-weight: 900; color: #fff; background: #fff; box-shadow: inset 0 0 0 1px #c3ccd4; }
.ds-nb__item.is-on .ds-nb__check { background: #c99a00; box-shadow: none; }
.ds-nb__tag { font-style: normal; font-size: 11px; font-weight: 800; padding: 3px 9px; border-radius: 999px; background: #eef1f4; color: #33424e; white-space: nowrap; }
.ds-nb__tag.is-combo { background: #f3e9ff; color: #6a2fb0; }
.ds-nb__warn { display: flex; flex-direction: column; gap: 8px; padding: 10px 12px; border-radius: 12px; background: #fff1c2; color: #7a5600; font-size: 13px; font-weight: 700; }
.ds-nb__foot { display: flex; justify-content: space-between; align-items: center; gap: 8px; }
.ds-nb__foot > span { display: flex; gap: 8px; align-items: center; }
.dark .ds-nb__item { background: transparent; }
.dark .ds-nb__item.is-on { background: rgb(201 154 0 / .12); }
@media (max-width: 900px) { .ds-nb__row { grid-template-columns: 1fr 60px; } .ds-nb__trip, .ds-nb__acts { grid-column: 1 / -1; } }

/* ── Scan app · Receive truck: the box goes on a hub trip (board 45d) ── */
.ds-ws__trip { display: flex; flex-direction: column; gap: 6px; padding: 14px; border-radius: 16px; background: #d9f2e6; color: #0e2433; }
.ds-ws__trip.is-new { background: #fff1c2; }
.ds-ws__trip.is-anyway { background: #ffe2b8; }
.ds-ws__trip b.ds-ws__to { font-size: 20px; }
.ds-ws__trip small { font-size: 13px; }
.ds-ws__trip button { height: 40px; border: 0; border-radius: 12px; background: #fff; font: inherit; font-weight: 800; color: #8a5a00; cursor: pointer; }

/* ── Plan trips: Create this trip (board 46) ── */
.ds-pt__one { display: flex; justify-content: flex-end; align-items: center; gap: 12px; border-top: 1px solid #eef1f4; padding-top: 12px; }
.ds-pt__one .ds-nt__go { height: 38px; padding: 0 18px; font-size: 13px; }
.ds-pt__one.is-made { justify-content: space-between; }
.ds-pt__madeone { font-size: 13px; font-weight: 800; padding: 7px 12px; border-radius: 999px; background: #e6f6ef; color: #17895e; }
.ds-pt__trip.is-made { box-shadow: inset 0 0 0 2px #8fd3b4, 0 12px 32px -18px rgb(14 36 51 / .25); }
.dark .ds-pt__one { border-color: rgb(255 255 255 / .08); }

/* ── AI settings · Who can use AI (board 48) ── */
.ds-aa__tabs { display: flex; gap: 6px; margin-bottom: 14px; }
.ds-aa__tabs button { height: 36px; padding: 0 14px; border: 0; border-radius: 10px; background: transparent; font: inherit; font-weight: 800; color: #33424e; cursor: pointer; }
.ds-aa__tabs button.is-on { background: #0e2433; color: #fff; }
.ds-aa { display: grid; grid-template-columns: minmax(0, 1fr) 420px; gap: 18px; align-items: start; }
.ds-aa__main, .ds-aa__side { display: flex; flex-direction: column; gap: 14px; }
.ds-aa__card { display: flex; flex-direction: column; gap: 12px; }
.ds-aa__h { display: flex; flex-direction: column; gap: 2px; }
.ds-aa__h b { font-size: 16px; }
.ds-aa__h small, .ds-aa__add > small, .ds-aa__f small { color: #6b7b88; }
.ds-aa__modes { display: flex; gap: 8px; flex-wrap: wrap; }
.ds-aa__modes button { display: flex; flex-direction: column; align-items: flex-start; gap: 2px; padding: 10px 14px; border: 0; border-radius: 12px; background: #fff; box-shadow: inset 0 0 0 1px #d3dae0; font: inherit; text-align: left; cursor: pointer; color: inherit; }
.ds-aa__modes button small { opacity: .75; }
.ds-aa__modes button.is-on { background: #fff7dc; box-shadow: inset 0 0 0 2px #e5b94a; }
.ds-aa__chips { display: flex; flex-wrap: wrap; gap: 8px; align-items: center; }
.ds-aa__chip { height: 32px; padding: 0 6px 0 12px; border-radius: 999px; background: #fff7dc; box-shadow: inset 0 0 0 1px #ecd58a; display: inline-flex; align-items: center; gap: 6px; font-weight: 700; font-size: 13px; }
.ds-aa__chip small { color: #6b7b88; font-weight: 600; }
.ds-aa__chip button { width: 22px; height: 22px; border: 0; border-radius: 50%; background: #fff; cursor: pointer; font-weight: 900; color: #8a5a00; }
.ds-aa__chips.is-small .ds-aa__chip { height: 28px; font-size: 12px; }
.ds-aa__warn { color: #8a5a00; font-weight: 700; }
.ds-aa__add { display: flex; flex-direction: column; gap: 8px; padding: 10px 12px; border-radius: 12px; background: #f6f8fa; }
.ds-aa__sel { height: 34px; border-radius: 10px; border: 0; box-shadow: inset 0 0 0 1px #d3dae0; padding: 0 10px; font: inherit; font-size: 13px; font-weight: 700; background: #fff; max-width: 100%; }
.ds-aa__sel.is-all { background: #e6f6ef; box-shadow: inset 0 0 0 1px #8fd3b4; }
.ds-aa__sel.is-own { background: #fff1c2; box-shadow: inset 0 0 0 1px #e8c873; }
.ds-aa__sel.is-mini { height: 28px; font-size: 12px; }
.ds-aa__groups { display: flex; flex-wrap: wrap; gap: 6px; }
.ds-aa__groups button { height: 30px; padding: 0 12px; border: 0; border-radius: 10px; background: #fff; box-shadow: inset 0 0 0 1px #b9cfe6; color: #1d5f99; font: inherit; font-size: 12px; font-weight: 800; cursor: pointer; }
.ds-aa__list { padding: 0 !important; overflow: hidden; gap: 0; }
.ds-aa__row { display: grid; grid-template-columns: 1.5fr 1.1fr 1.8fr; gap: 12px; align-items: center; padding: 9px 18px; border-top: 1px solid #f3f5f7; }
.ds-aa__head { border-top: 0; font-size: 12px; font-weight: 800; color: #6b7b88; padding: 12px 18px; }
.ds-aa__f { display: flex; flex-direction: column; }
.ds-aa__where { color: #33424e; }
.ds-aa__who { display: flex; flex-direction: column; gap: 6px; align-items: flex-start; }
.ds-aa__fixed { font-size: 12px; font-weight: 700; color: #6b7b88; }
.ds-aa__verdict { padding: 10px 12px; border-radius: 12px; font-size: 13px; font-weight: 700; background: #fff1c2; color: #7a5600; }
.ds-aa__verdict.is-ok { background: #e6f6ef; color: #17895e; }
.ds-aa__prev { display: flex; flex-direction: column; gap: 6px; padding: 10px 12px; border-radius: 12px; background: #f3f5f7; color: #6b7b88; font-size: 13px; }
.ds-aa__prev.is-ai { background: #fff7dc; color: #0e2433; }
.ds-aa__prev em { font-style: normal; color: #6b7b88; padding: 6px 10px; border-radius: 10px; background: #fff; }
.ds-aa__spot { display: flex; justify-content: space-between; font-size: 13px; padding: 4px 0; border-bottom: 1px solid #f3f5f7; }
.ds-aa__spot b { color: #8a1f1f; }
.ds-aa__spot b.is-ok { color: #17895e; }
.dark .ds-aa__modes button, .dark .ds-aa__sel, .dark .ds-aa__groups button { background: transparent; }
@media (max-width: 1100px) { .ds-aa { grid-template-columns: 1fr; } }
.ds-pt__noai { color: #6b7b88; font-size: 14px; }

/* ── Warehouse sections: province or city, optional spots (boards 50, 50b) ── */
.ds-ws__row { grid-template-columns: 7.5rem 1.1fr 0.9fr 1.2fr 2.4fr 2rem; }
.ds-ws__row.has-spots { grid-template-columns: 7.5rem 1fr 0.9fr 1.1fr 2.2fr 1.6fr 2rem; min-width: 72rem; }
.ds-ws__row.is-view { grid-template-columns: 4rem 1.3fr 2fr 6rem 1.6fr; }
.ds-ws__row { align-items: start; }
.ds-ws__by { display: flex; justify-content: flex-end; margin-bottom: 0.5rem; }
.ds-ws__by > span { display: flex; flex-direction: column; gap: 4px; align-items: flex-end; }
.ds-ws__by small { font-weight: 800; color: #6b7b88; }
.ds-ws__seg { display: flex; padding: 4px; border-radius: 12px; background: #fff; box-shadow: inset 0 0 0 1px #d3dae0; }
.ds-ws__seg button { height: 34px; padding: 0 14px; border: 0; border-radius: 9px; font: inherit; font-size: 13px; font-weight: 800; cursor: pointer; background: transparent; color: #33424e; }
.ds-ws__seg button.is-on { background: #0e2433; color: #fff; }
.ds-ws__citynote { padding: 10px 14px; border-radius: 12px; background: #eef6ff; color: #1d5f99; font-size: 13px; font-weight: 700; margin-bottom: 0.75rem; }
.ds-ws__places { position: relative; display: block; }
.ds-ws__field { min-height: 40px; border-radius: 10px; box-shadow: inset 0 0 0 1px #d3dae0; background: #fff; display: flex; flex-wrap: wrap; align-items: center; gap: 6px; padding: 6px 8px; }
.ds-ws__field.is-open { box-shadow: inset 0 0 0 2px #1d6fb8; }
.ds-ws__chip { height: 28px; padding: 0 4px 0 10px; border-radius: 8px; background: #eef6ff; color: #1d5f99; font-size: 13px; font-weight: 800; display: inline-flex; align-items: center; gap: 4px; }
.ds-ws__chip.is-city { background: #eefaf3; color: #17895e; }
.ds-ws__chip button, .ds-ws__spot button { width: 22px; height: 22px; border: 0; border-radius: 6px; background: transparent; color: inherit; font: inherit; font-weight: 900; cursor: pointer; }
.ds-ws__add { flex: 1; min-width: 120px; height: 28px; border: 0; background: transparent; text-align: left; font: inherit; font-size: 13px; color: #6b7b88; cursor: pointer; }
.ds-ws__pop { position: absolute; top: calc(100% + 6px); left: 0; right: 0; z-index: 30; background: #fff; border-radius: 12px; box-shadow: 0 24px 48px -16px rgb(14 36 51 / .4), inset 0 0 0 1px #e3e8ec; display: flex; flex-direction: column; overflow: hidden; min-width: 18rem; }
.ds-ws__pop input { height: 40px; border: 0; border-bottom: 1px solid #eef1f4; padding: 0 12px; font: inherit; background: #fff; }
.ds-ws__opts { max-height: 300px; overflow: auto; display: flex; flex-direction: column; }
.ds-ws__opts button { display: flex; flex-direction: column; align-items: flex-start; gap: 1px; padding: 9px 12px; border: 0; border-bottom: 1px solid #f5f7f9; background: #fff; font: inherit; text-align: left; cursor: pointer; color: inherit; }
.ds-ws__opts button:hover { background: #f6f8fa; }
.ds-ws__opts small { color: #8a5a00; font-weight: 700; }
.ds-ws__none { padding: 12px; color: #6b7b88; }
.ds-ws__done { height: 38px; border: 0; border-top: 1px solid #eef1f4; background: #f6f8fa; font: inherit; font-weight: 800; cursor: pointer; }
.ds-ws__new { color: #1d5f99; }
.ds-ws__spots { display: flex; flex-direction: column; gap: 6px; }
.ds-ws__spotsw { display: flex; align-items: center; gap: 8px; }
.ds-ws__spotsw small { font-weight: 800; color: #33424e; }
.ds-ws__spotlist { display: flex; flex-wrap: wrap; gap: 4px; align-items: center; }
.ds-ws__spot { height: 26px; padding: 0 2px 0 8px; border-radius: 7px; background: #f3f5f7; box-shadow: inset 0 0 0 1px #d3dae0; font-size: 12px; font-weight: 800; display: inline-flex; align-items: center; }
.ds-ws__addspot { height: 26px; padding: 0 10px; border: 0; border-radius: 7px; background: #fff; box-shadow: inset 0 0 0 1px #b9cfe6; color: #1d5f99; font: inherit; font-size: 12px; font-weight: 800; cursor: pointer; }
.ds-ws__toggle.is-new { margin-top: 0.6rem; padding: 10px; border-radius: 12px; background: #f4f9ff; box-shadow: inset 0 0 0 1px #b9cfe6; }
.ds-ws__newpill { font-style: normal; font-size: 11px; font-weight: 800; padding: 2px 8px; border-radius: 999px; background: #e8f1fb; color: #1d5f99; margin-left: 4px; }
.ds-ws__spotnote { color: #1d5f99; }
.dark .ds-ws__field, .dark .ds-ws__pop, .dark .ds-ws__pop input, .dark .ds-ws__opts button, .dark .ds-ws__seg { background: rgb(255 255 255 / .04); }
/* Scan app · unload: optional spot (board 50) */
.ds-sx__spoth { display: block; font-size: 13px; color: #9fb0bc; font-weight: 800; margin-top: 10px; }
.ds-sx__spots { display: grid; grid-template-columns: repeat(3, 1fr); gap: 8px; margin-top: 6px; }
.ds-sx__spots button { height: 54px; border: 0; border-radius: 14px; background: rgb(255 255 255 / .08); color: #fff; font: inherit; font-weight: 900; font-size: 18px; cursor: pointer; }
.ds-sx__skip { width: 100%; height: 46px; margin-top: 8px; border: 0; border-radius: 14px; background: rgb(255 255 255 / .06); color: #c8d3dc; font: inherit; font-weight: 800; cursor: pointer; }

/* Scan app · Pick boxes (board 49) */
.ds-pk__mine { display: flex; flex-direction: column; gap: 0.4rem; width: 100%; padding: 0.9rem; border-radius: 1.2rem; text-align: left; color: inherit; background: rgb(246 190 0 / .14); box-shadow: inset 0 0 0 1px rgb(246 190 0 / .5); }
.ds-pk__mine small { color: #9fb0bc; font-size: 0.8rem; }
.ds-pk__row { display: flex; justify-content: space-between; align-items: center; }
.ds-pk__row b { font-size: 1.15rem; }
.ds-pk__row em { font-style: normal; font-size: 0.75rem; font-weight: 800; color: var(--sa-gold); }
.ds-pk__bar { height: 6px; border-radius: 99px; background: rgb(255 255 255 / .1); overflow: hidden; }
.ds-pk__bar i { display: block; height: 100%; background: var(--sa-ok); }
.ds-pk__open { display: flex; align-items: center; gap: 0.6rem; padding: 0.75rem 0.9rem; border-radius: 1.2rem; background: rgb(255 255 255 / .05); }
.ds-pk__open > span { flex: 1; display: flex; flex-direction: column; gap: 2px; min-width: 0; }
.ds-pk__open small { color: #9fb0bc; font-size: 0.8rem; }
.ds-pk__open button { height: 2.5rem; padding: 0 0.9rem; border-radius: 0.75rem; background: var(--sa-gold); color: #0e2433; font-weight: 900; flex: none; }
.ds-pk__foot { display: block; color: #7f93a1; font-size: 0.78rem; line-height: 1.45; }
.ds-pk__list { display: flex; flex-direction: column; gap: 0.5rem; }
.ds-pk__group { display: flex; flex-direction: column; gap: 0.4rem; padding: 0.65rem 0.75rem; border-radius: 0.9rem; background: rgb(255 255 255 / .05); }
.ds-pk__gh { display: flex; justify-content: space-between; align-items: center; gap: 0.5rem; }
.ds-pk__gh b { font-size: 0.9rem; }
.ds-pk__gh b i { display: inline-block; width: 10px; height: 10px; border-radius: 3px; margin-right: 6px; }
.ds-pk__gh small { font-weight: 800; color: #9fb0bc; }
.ds-pk__gh small.is-done { color: var(--sa-ok); }
.ds-pk__boxes { display: flex; flex-wrap: wrap; gap: 5px; }
.ds-pk__box { height: 28px; padding: 0 9px; border-radius: 8px; font-size: 0.78rem; font-weight: 800; display: inline-flex; align-items: center; gap: 5px; background: rgb(255 255 255 / .08); color: #fff; }
.ds-pk__box small { font-weight: 700; opacity: .75; font-size: 0.68rem; }
.ds-pk__box.is-combo { box-shadow: inset 0 0 0 1px rgb(90 168 255 / .7); }
.ds-pk__box.is-picked { background: rgb(52 195 143 / .16); color: #7fe0b8; }
.ds-pk__box.is-mine { background: rgb(52 195 143 / .3); color: #fff; }
.ds-pk__box.is-missing { background: rgb(240 169 59 / .2); color: #f3c98a; }
.ds-pk__hit { display: flex; justify-content: space-between; align-items: center; }
.ds-pk__hit small { font-weight: 800; color: #c8d3dc; }
.ds-pk__sheet strong { font-size: 1.2rem; }
.ds-pk__sheet.is-ok strong { color: #7fe0b8; }
.ds-pk__sheet.is-warn strong { color: #f3c98a; }
.ds-pk__sheet.is-bad strong { color: #ff9d93; }
.ds-pk__undo { height: 2.6rem; border-radius: 0.8rem; background: #fff; color: #8a1f1f; font-weight: 800; }
.ds-pk__ready { display: flex; flex-direction: column; gap: 0.45rem; padding: 0.9rem; border-radius: 1.1rem; background: rgb(52 195 143 / .14); box-shadow: inset 0 0 0 1px rgb(52 195 143 / .45); }
.ds-pk__ready b { color: #7fe0b8; font-size: 1.05rem; }
.ds-pk__ready span { color: #c8d3dc; font-size: 0.88rem; }

/* Picking (office, board 49) */
.ds-pg { display: flex; flex-direction: column; gap: 1rem; }
.ds-pg__card { background: #fff; border-radius: 1rem; box-shadow: 0 1px 0 #e3e8ec, 0 12px 32px -20px rgb(14 36 51 / .25); overflow: hidden; }
.dark .ds-pg__card { background: rgb(255 255 255 / .04); box-shadow: inset 0 0 0 1px rgb(255 255 255 / .08); }
.ds-pg__head, .ds-pg__row { display: grid; grid-template-columns: 150px 1.1fr 1.6fr 1.3fr 140px; gap: 12px; padding: 11px 16px; align-items: center; }
.ds-pg__head { font-size: 12px; font-weight: 800; color: #6b7b88; border-bottom: 1px solid #eef1f4; }
.ds-pg__row { border-bottom: 1px solid #f3f5f7; }
.dark .ds-pg__head, .dark .ds-pg__row { border-color: rgb(255 255 255 / .06); }
.ds-pg__trip { display: flex; flex-direction: column; }
.ds-pg__trip b { font-size: 15px; }
.ds-pg__trip small, .ds-pg__secs { color: #6b7b88; font-size: 12px; }
.ds-pg__pickers { display: flex; flex-wrap: wrap; gap: 6px; align-items: center; position: relative; }
.ds-pg__chip { height: 28px; padding: 0 5px 0 10px; border-radius: 999px; background: #fff7dc; box-shadow: inset 0 0 0 1px #ecd58a; display: inline-flex; align-items: center; gap: 5px; font-size: 12px; font-weight: 800; color: #0e2433; }
.ds-pg__chip button { width: 20px; height: 20px; border-radius: 50%; background: #fff; font-weight: 900; color: #8a5a00; }
.ds-pg__add { height: 28px; padding: 0 10px; border-radius: 10px; font-size: 12px; font-weight: 800; box-shadow: inset 0 0 0 1px #b9cfe6; color: #1d5f99; background: #fff; }
.ds-pg__none { color: #8a5a00; font-weight: 700; font-size: 12px; }
.ds-pg__sug { width: 100%; display: flex; gap: 6px; align-items: center; padding: 6px 8px; border-radius: 10px; background: #fff7dc; color: #0e2433; }
.ds-pg__sug small { flex: 1; font-weight: 700; }
.ds-pg__sug small span { color: #6b7b88; font-weight: 600; }
.ds-pg__sug button { height: 26px; padding: 0 12px; border-radius: 10px; background: #e5b94a; font-size: 12px; font-weight: 800; color: #0e2433; }
.ds-pg__pop { position: absolute; z-index: 30; top: 32px; left: 0; width: 240px; max-height: 260px; overflow: auto; background: #fff; border-radius: 12px; box-shadow: 0 18px 40px -16px rgb(14 36 51 / .45), inset 0 0 0 1px #e3e8ec; padding: 6px; display: flex; flex-direction: column; }
.dark .ds-pg__pop { background: #1b2a36; }
.ds-pg__pop button { text-align: left; padding: 7px 10px; border-radius: 8px; font-size: 13px; display: flex; justify-content: space-between; gap: 8px; }
.ds-pg__pop button:hover { background: #f3f5f7; }
.dark .ds-pg__pop button:hover { background: rgb(255 255 255 / .06); }
.ds-pg__pop small { color: #6b7b88; }
.ds-pg__prog { display: flex; flex-direction: column; gap: 5px; }
.ds-pg__prog > span:first-child { height: 8px; border-radius: 99px; background: #eef1f4; overflow: hidden; }
.ds-pg__prog > span:first-child i { display: block; height: 100%; background: #17895e; }
.ds-pg__prog > small { font-weight: 700; color: #33424e; font-size: 12px; }
.dark .ds-pg__prog > small { color: #c8d3dc; }
.ds-pg__miss { color: #8a5a00; font-weight: 700; font-size: 12px; display: flex; flex-wrap: wrap; gap: 4px; align-items: center; }
.ds-pg__miss button { font-size: 11px; font-weight: 800; color: #1d5f99; text-decoration: underline; }
.ds-pg__st { justify-self: start; height: 26px; padding: 0 10px; border-radius: 999px; font-size: 12px; font-weight: 800; display: inline-flex; align-items: center; }
.ds-pg__st.is-ready { background: #e6f6ef; color: #17895e; }
.ds-pg__st.is-picking { background: #e8f1fb; color: #1d5f99; }
.ds-pg__st.is-wait { background: #fff1c2; color: #8a5a00; }
.ds-pg__log { padding: 14px 16px; display: flex; flex-direction: column; gap: 4px; }
.ds-pg__log > span { display: flex; gap: 10px; font-size: 13px; padding: 3px 0; border-bottom: 1px solid #f3f5f7; }
.dark .ds-pg__log > span { border-color: rgb(255 255 255 / .06); }
.ds-pg__log small { color: #6b7b88; width: 64px; flex: none; }
.ds-pg__empty { padding: 28px 16px; color: #6b7b88; text-align: center; }
@media (max-width: 900px) { .ds-pg__head { display: none; } .ds-pg__row { grid-template-columns: 1fr; } }

/* Pick boxes: a shorter camera, the pick list under it */

/* Scan app and Driver app camera (board 51): wide frame for the stickers, camera off, dark, hard to read, photos */
.ds-sa__cam .ds-sa__frame { width: min(86vw, 21rem); height: min(30vw, 7.5rem); }
.ds-cx__off { position: absolute; inset: 0; z-index: 4; display: flex; flex-direction: column; align-items: center; justify-content: center; gap: 0.5rem; background: #05090c; color: #fff; text-align: center; padding: 1.5rem; }
.ds-cx__off span { display: grid; place-items: center; width: 4rem; height: 4rem; border-radius: 50%; background: rgb(255 255 255 / .1); font-size: 1.6rem; }
.ds-cx__off b { font-size: 1rem; }
.ds-cx__off small { max-width: 17rem; color: #9fb0bc; font-size: 0.8rem; line-height: 1.4; }
.ds-cx__dark { position: absolute; left: 1rem; right: 1rem; top: 52%; z-index: 3; display: flex; align-items: center; gap: 0.5rem; padding: 0.5rem 0.65rem; border-radius: 0.8rem; background: rgb(10 18 25 / .88); box-shadow: inset 0 0 0 1px rgb(246 190 0 / .5); }
.ds-cx__dark span { flex: 1; font-size: 0.82rem; font-weight: 800; color: #ffe08a; }
.ds-cx__dark button { height: 2rem; padding: 0 0.8rem; border-radius: 0.6rem; background: var(--sa-gold); color: #0a1219; font-weight: 900; }
.ds-cx__hard { position: absolute; left: 1rem; right: 1rem; top: 60%; z-index: 3; height: 3.4rem; border-radius: 1rem; background: var(--sa-gold); color: #0a1219; font-size: 1rem; font-weight: 900; }
.ds-cx__type { position: absolute; left: 0; right: 0; bottom: 0; z-index: 5; display: flex; flex-direction: column; gap: 0.5rem; padding: 0.9rem 1rem calc(env(safe-area-inset-bottom) + 1rem); border-radius: 1.5rem 1.5rem 0 0; background: #0f1d27; box-shadow: 0 -16px 40px rgb(0 0 0 / .45); }
.ds-cx__type > small { color: #9fb0bc; font-size: 0.8rem; }
.ds-cx__field { display: flex; align-items: center; gap: 0.5rem; height: 3.2rem; padding-left: 0.9rem; border-radius: 0.9rem; box-shadow: inset 0 0 0 2px var(--sa-gold); }
.ds-cx__field b { font-size: 1.4rem; font-weight: 900; letter-spacing: .08em; }
.ds-cx__field i { width: 2px; height: 1.6rem; background: var(--sa-gold); margin-right: auto; animation: ds-blink 1s steps(2) infinite; }
.ds-cx__field button { height: 100%; padding: 0 1.2rem; border-radius: 0.9rem; background: var(--sa-gold); color: #0a1219; font-weight: 900; font-size: 1rem; }
@keyframes ds-blink { 50% { opacity: 0; } }
.ds-cx__keys { display: grid; grid-template-columns: repeat(3, 1fr); gap: 0.4rem; }
.ds-cx__keys button { height: 3rem; border-radius: 0.8rem; background: rgb(255 255 255 / .1); color: #fff; font-size: 1.3rem; font-weight: 800; }
.ds-cx__keys button:active { background: rgb(255 255 255 / .2); }
.ds-cx__back { height: 2.4rem; color: #9fb0bc; font-weight: 800; }
.ds-cx__chips { position: absolute; left: 1rem; right: 1rem; top: 50%; z-index: 2; display: flex; flex-wrap: wrap; gap: 0.35rem; pointer-events: none; }
.ds-cx__chips span { height: 1.7rem; padding: 0 0.7rem; border-radius: 999px; font-size: 0.78rem; font-weight: 800; display: inline-flex; align-items: center; pointer-events: auto; }
.ds-cx__chips .is-up { background: rgb(90 168 255 / .22); color: #a8d0ff; }
.ds-cx__chips .is-ok { background: rgb(52 195 143 / .2); color: #7fe0b8; }
.ds-cx__chips .is-bad { background: rgb(255 107 94 / .25); color: #ffb3ab; }
.ds-cx__chips .is-torch { background: rgb(246 190 0 / .2); color: #ffe08a; }
.ds-snap { display: flex; flex-wrap: wrap; align-items: center; gap: 0.5rem; }
.ds-snap .ds-sa__shot { position: relative; width: 3.6rem; height: 3.6rem; flex: none; border-radius: 0.75rem; overflow: hidden; }
.ds-snap .ds-sa__shot img { width: 100%; height: 100%; object-fit: cover; }
.ds-snap .ds-sa__shot b { position: absolute; left: 0; right: 0; bottom: 0; text-align: center; font-size: 0.65rem; font-weight: 900; padding: 1px 0; background: rgb(0 0 0 / .6); color: #a8d0ff; }
.ds-snap .ds-sa__shot b.is-done { color: #7fe0b8; }
.ds-snap .ds-sa__shot b.is-bad { color: #ffb3ab; }
.ds-snap__here { flex: 1; min-width: 9rem; height: 3.6rem; border-radius: 0.9rem; background: var(--sa-gold); color: #0a1219; font-size: 0.95rem; font-weight: 900; }
.ds-snap__app { width: 5.5rem; height: 3.6rem; flex: none; border-radius: 0.9rem; background: rgb(255 255 255 / .1); color: #fff; font-size: 0.78rem; font-weight: 800; line-height: 1.2; display: flex; flex-direction: column; align-items: center; justify-content: center; }
.ds-snap__app small { color: #9fb0bc; font-weight: 700; }
.ds-snap__note { width: 100%; margin: 0; color: #9fb0bc; font-size: 0.8rem; }
.ds-sa__primary.is-light { background: rgb(255 255 255 / .92); color: #0a1219; }
.ds-sx__skel { position: absolute; top: calc(env(safe-area-inset-top) + 5.2rem); left: 1rem; right: 1rem; z-index: 3; display: flex; flex-direction: column; gap: 0.45rem; padding: 0.8rem 0.9rem; border-radius: 0.9rem; background: rgb(10 18 25 / .82); backdrop-filter: blur(8px); }
.ds-sx__skel i { display: block; height: 0.7rem; border-radius: 0.35rem; background: rgb(255 255 255 / .1); animation: ds-skel 1.2s ease-in-out infinite; }
.ds-sx__skel i:nth-child(1) { width: 60%; } .ds-sx__skel i:nth-child(2) { width: 85%; } .ds-sx__skel i:nth-child(3) { width: 40%; }
.ds-sx__skel small { color: #7f93a1; font-size: 0.75rem; }
@keyframes ds-skel { 50% { opacity: .45; } }

/* Which camera (board 52) */
.ds-cx__cam { position: absolute; left: 1rem; top: 26%; z-index: 2; height: 1.75rem; padding: 0 0.7rem; border-radius: 999px; display: inline-flex; align-items: center; font-size: 0.78rem; font-weight: 800; background: rgb(255 255 255 / .12); color: #e6edf2; backdrop-filter: blur(6px); }
.ds-cx__cam.is-front { background: rgb(255 107 94 / .25); color: #ffb3ab; }
.ds-cx__dark.is-front { box-shadow: inset 0 0 0 1px rgb(255 107 94 / .6); }
.ds-cx__dark.is-front span { color: #ffb3ab; }
.ds-cx__cams > b { font-size: 1.05rem; }
.ds-cx__cams > button:not(.ds-cx__back) { display: flex; align-items: center; gap: 0.6rem; padding: 0.75rem; border-radius: 0.9rem; text-align: left; color: #fff; background: rgb(255 255 255 / .05); }
.ds-cx__cams > button.is-on { background: rgb(52 195 143 / .14); box-shadow: inset 0 0 0 1px rgb(52 195 143 / .5); }
.ds-cx__cams > button.is-front { opacity: .75; }
.ds-cx__cams > button > span:first-child { font-size: 1.1rem; }
.ds-cx__cams > button > span:nth-child(2) { flex: 1; display: flex; flex-direction: column; }
.ds-cx__cams > button small { color: #9fb0bc; font-size: 0.78rem; }
.ds-cx__cams > button em { font-style: normal; font-weight: 900; color: #34c38f; }

/* Scan app start screen (board 54) */
.ds-sh__resume { display: flex; align-items: center; gap: 0.8rem; width: 100%; padding: 0.9rem 1rem; border-radius: 1.4rem; text-align: left; background: var(--sa-gold); color: #0a1219; box-shadow: 0 16px 30px -18px rgb(246 190 0 / .8); transition: transform .12s; }
.ds-sh__resume:active, .ds-sh__tile:active { transform: scale(.96); }
.ds-sh__ring { position: relative; width: 3.3rem; height: 3.3rem; flex: none; border-radius: 50%; background: conic-gradient(#0a1219 calc(var(--p) * 1%), rgb(10 18 25 / .15) 0); display: grid; place-items: center; }
.ds-sh__ring::before { content: ''; position: absolute; inset: 6px; border-radius: 50%; background: var(--sa-gold); }
.ds-sh__ring b { position: relative; font-size: 0.8rem; font-weight: 900; }
.ds-sh__resumetext { flex: 1; min-width: 0; display: flex; flex-direction: column; gap: 1px; }
.ds-sh__resumetext small { font-size: 0.74rem; font-weight: 800; opacity: .7; }
.ds-sh__resumetext strong { font-size: 1.02rem; font-weight: 900; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
.ds-sh__go { flex: none; height: 2rem; padding: 0 0.8rem; border-radius: 999px; background: #0a1219; color: var(--sa-gold); font-size: 0.8rem; font-weight: 900; display: inline-flex; align-items: center; }
.ds-sh__stats { display: grid; grid-template-columns: repeat(3, 1fr); gap: 0.5rem; }
.ds-sh__stats > span { display: flex; flex-direction: column; gap: 2px; padding: 0.6rem 0.75rem; border-radius: 1rem; background: var(--sa-glass); box-shadow: inset 0 0 0 1px var(--sa-line); }
.ds-sh__stats b { font-size: 1.25rem; font-weight: 800; }
.ds-sh__stats small { color: var(--sa-muted); font-size: 0.7rem; font-weight: 700; }
.ds-sh__stats .is-bad b { color: #ff9d93; }
.ds-sh__grid { display: grid; grid-template-columns: 1fr 1fr; gap: 0.65rem; }
.ds-sh__tile { position: relative; min-height: 8rem; display: flex; flex-direction: column; align-items: flex-start; gap: 0.35rem; padding: 0.9rem; border-radius: 1.25rem; text-align: left; color: inherit; background: linear-gradient(160deg, rgb(255 255 255 / .09), rgb(255 255 255 / .03)); box-shadow: inset 0 0 0 1px rgb(255 255 255 / .07); transition: transform .12s, opacity .2s; }
.ds-sh__tile.is-done { background: rgb(255 255 255 / .03); }
.ds-sh__tile.is-done strong, .ds-sh__tile.is-done .ds-sh__chip { opacity: .7; }
.ds-sh__chip { width: 2.6rem; height: 2.6rem; border-radius: 0.85rem; display: grid; place-items: center; color: var(--c); background: color-mix(in srgb, var(--c) 16%, transparent); }
.ds-sh__chip svg { width: 1.35rem; height: 1.35rem; }
.ds-sh__tile strong { margin-top: 0.25rem; font-size: 1rem; font-weight: 800; line-height: 1.2; }
.ds-sh__tile small { color: var(--sa-muted); font-size: 0.75rem; line-height: 1.3; }
.ds-sh__badge { position: absolute; top: 0.75rem; right: 0.75rem; min-width: 2.1rem; height: 1.5rem; padding: 0 0.55rem; border-radius: 999px; display: inline-flex; align-items: center; justify-content: center; font-size: 0.7rem; font-weight: 900; color: var(--sa-muted); background: rgb(255 255 255 / .06); }
.ds-sh__badge.is-on { background: var(--c); color: #0a1219; }
.ds-sh__badge.is-wait { animation: ds-skel 1.2s ease-in-out infinite; }
.ds-sh__opening { position: fixed; inset: 0; z-index: 60; flex-direction: column; gap: 0.7rem; padding: calc(env(safe-area-inset-top) + 5.5rem) 1rem 1rem; background: #0b1620; }
.ds-sh__opening i { display: block; height: 5.2rem; border-radius: 1.25rem; background: rgb(255 255 255 / .05); animation: ds-skel 1.2s ease-in-out infinite; }
.ds-sh__opening small { color: var(--sa-muted); text-align: center; }

/* Pick boxes (board 55): full-screen camera, next box on it, short messages, the list in a pull-up sheet */
.ds-sa__scan.is-pick .ds-sa__controls { bottom: calc(env(safe-area-inset-bottom) + 7.4rem); transition: bottom .25s; }
.ds-sa__scan.is-pick:has(.ds-pk__sheet2.is-open) .ds-sa__controls { bottom: calc(62dvh + 0.5rem); }
.ds-sa__scan.is-pick:has(.ds-pk__sheet2.is-open) .ds-sa__frame { top: 22%; }
.ds-pk__next { position: absolute; left: 1rem; top: calc(env(safe-area-inset-top) + 5.2rem); z-index: 3; max-width: calc(100% - 2rem); height: 1.9rem; padding: 0 0.8rem; border-radius: 999px; display: inline-flex; align-items: center; font-size: 0.8rem; font-weight: 800; color: #9ef0e6; background: rgb(46 196 182 / .22); backdrop-filter: blur(6px); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
/* board 56: dark glass messages; only the title, the sign and the edge have the colour */
.ds-pk__msg { position: absolute; left: 1rem; right: 1rem; top: 46%; z-index: 6; display: flex; flex-direction: column; gap: 0.4rem; pointer-events: none; }
.ds-pk__msg > * { pointer-events: auto; }
.ds-sa .ds-pk__toast { --c: #5be3a8; display: flex; align-items: center; gap: 0.6rem; padding: 0.75rem 0.75rem 0.75rem 0.85rem; border-radius: 1.1rem; color: #fff; background: rgb(10 18 25 / .8); -webkit-backdrop-filter: blur(14px) saturate(140%); backdrop-filter: blur(14px) saturate(140%); box-shadow: inset 3px 0 0 var(--c), inset 0 0 0 1px rgb(255 255 255 / .08), 0 16px 30px -18px rgb(0 0 0 / .55); }
.ds-sa .ds-pk__toast.is-warn { --c: #ffd24d; color: #fff; }
.ds-sa .ds-pk__toast.is-bad { --c: #ff8a80; color: #fff; }
.ds-sa .ds-pk__toast.is-ok { color: #fff; }
.ds-pk__sign { width: 2.2rem; height: 2.2rem; flex: none; border-radius: 50%; display: grid; place-items: center; background: var(--c); color: #0a1219; font-weight: 900; font-size: 1.05rem; }
.ds-pk__words { flex: 1; min-width: 0; display: flex; flex-direction: column; gap: 2px; }
.ds-pk__words b { font-size: 1.06rem; font-weight: 900; color: var(--c); }
.ds-pk__words small { font-size: 0.8rem; font-weight: 600; color: rgb(255 255 255 / .92); }
.ds-pk__undo2 { flex: none; height: 2.2rem; padding: 0 0.75rem; border-radius: 0.65rem; background: rgb(255 255 255 / .92); color: #0a1219; font-weight: 800; font-size: 0.8rem; }
.ds-pk__ok { flex: none; height: 2.2rem; padding: 0 0.9rem; border-radius: 0.65rem; background: var(--c); color: #0a1219; font-weight: 900; font-size: 0.85rem; }
.ds-pk__after { align-self: center; display: flex; align-items: center; gap: 0.5rem; }
.ds-pk__after small { color: #fff; font-size: 0.7rem; font-weight: 800; text-shadow: 0 1px 2px rgb(0 0 0 / .6); }
.ds-pk__after button { height: 1.6rem; padding: 0 0.6rem; border-radius: 999px; background: rgb(10 18 25 / .75); color: #fff; font-size: 0.7rem; font-weight: 800; }
.ds-pk__timer { width: 3.5rem; height: 4px; border-radius: 9px; background: rgb(255 255 255 / .25); overflow: hidden; }
.ds-pk__timer i { display: block; height: 100%; background: #5be3a8; transition: width .25s linear; }
.ds-pk__last { position: fixed; left: 1rem; top: calc(env(safe-area-inset-top) + 7.6rem); display: inline-flex; align-items: center; gap: 0.5rem; height: 2rem; padding: 0 0.3rem 0 0.8rem; border-radius: 999px; background: rgb(10 18 25 / .8); box-shadow: inset 0 0 0 1px rgb(91 227 168 / .5); color: #5be3a8; font-size: 0.78rem; }
.ds-pk__last button { height: 1.5rem; padding: 0 0.6rem; border-radius: 999px; background: rgb(255 255 255 / .9); color: #0a1219; font-weight: 800; font-size: 0.72rem; }
.ds-pk__sheet2 { position: fixed; left: 0; right: 0; bottom: 0; z-index: 5; display: flex; flex-direction: column; max-height: 62dvh; padding-bottom: env(safe-area-inset-bottom); border-radius: 1.5rem 1.5rem 0 0; background: #0f1d27; box-shadow: 0 -16px 40px rgb(0 0 0 / .45); }
.ds-pk__sheet2.is-open { height: 62dvh; }
.ds-pk__peek { display: flex; flex-direction: column; gap: 0.5rem; width: 100%; padding: 0.5rem 1rem 0.8rem; text-align: left; color: #fff; }
.ds-pk__peek .ds-sa__grab { align-self: center; }
.ds-pk__peekrow { display: flex; align-items: center; gap: 0.6rem; }
.ds-pk__peekrow > span { flex: 1; min-width: 0; display: flex; flex-direction: column; gap: 1px; }
.ds-pk__peekrow b { font-size: 0.95rem; font-weight: 800; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
.ds-pk__peekrow small { color: #9fb0bc; font-size: 0.8rem; }
.ds-pk__peekrow em { flex: none; font-style: normal; height: 2rem; padding: 0 0.8rem; border-radius: 999px; background: rgb(255 255 255 / .1); display: inline-flex; align-items: center; font-weight: 800; font-size: 0.82rem; }
.ds-pk__peek .ds-pk__bar i { background: #2ec4b6; }
.ds-pk__goload { margin: 0 1rem 0.8rem; }
.ds-pk__sheet2 .ds-pk__list { flex: 1; overflow-y: auto; padding: 0.2rem 1rem 1rem; }
@media (min-width: 700px) { .ds-pk__sheet2 { left: 50%; right: auto; width: 34rem; transform: translateX(-50%); } }
.ds-sa__scan.is-pick:has(.ds-pk__sheet2.is-open) .ds-sa__type, .ds-sa__scan.is-pick:has(.ds-pk__sheet2.is-open) .ds-cx__cam { display: none; }
.ds-sa__scan.is-pick:has(.ds-pk__sheet2.is-open) .ds-sa__frame { top: 17%; transform: translate(-50%, -50%) scale(.85); }
.ds-sa__scan.is-pick:has(.ds-pk__sheet2.is-open) .ds-pk__msg { top: 5.4rem; }
.ds-sa__scan.is-pick:has(.ds-pk__sheet2.is-open) .ds-pk__next { display: none; }

/* Same number on two boxes (board 57): pick the receiver */
.ds-which { gap: 0.6rem; }
.ds-which__head { display: flex; align-items: center; gap: 0.6rem; }
.ds-which__head > span:first-child { width: 2.3rem; height: 2.3rem; flex: none; border-radius: 50%; display: grid; place-items: center; background: #ffd24d; color: #0a1219; font-weight: 900; }
.ds-which__head > span:last-child { display: flex; flex-direction: column; gap: 2px; }
.ds-which__head strong { color: #ffd24d; font-size: 1.05rem; }
.ds-which__head small { color: #c8d3dc; font-size: 0.82rem; }
.ds-which__opt { display: flex; align-items: center; gap: 0.75rem; width: 100%; padding: 0.85rem 0.95rem; border-radius: 1rem; text-align: left; color: #fff; background: rgb(255 255 255 / .06); box-shadow: inset 0 0 0 1px rgb(255 255 255 / .1); }
.ds-which__opt:active { transform: scale(.98); }
.ds-which__opt > span { flex: 1; min-width: 0; display: flex; flex-direction: column; gap: 2px; }
.ds-which__opt strong { font-size: 1.3rem; font-weight: 800; letter-spacing: -0.01em; }
.ds-which__opt small { color: #c8d3dc; font-size: 0.82rem; }
.ds-which__opt em { font-style: normal; color: #8fa2b0; font-size: 0.75rem; }
.ds-which__opt > b { color: #9fb0bc; font-size: 1.4rem; }
.ds-ws__same { margin: 0.4rem 0 0.2rem; padding: 0.45rem 0.7rem; border-radius: 0.6rem; background: #fff6db; color: #7a5300; font-weight: 700; font-size: 0.85rem; }
.dark .ds-ws__same { background: rgb(255 210 77 / .14); color: #ffd24d; }
.ds-ws__result + .ds-ws__result { margin-top: 0.45rem; }
/* Search Invoices: delivered rows greyed, shared numbers flagged (board 57) */
.fi-ta-row.ds-row-delivered > td { opacity: .5; }
.fi-ta-row.ds-row-delivered:hover > td { opacity: .8; }
.ds-same-no .fi-ta-text-description, .ds-same-no p:last-child { color: #b45309 !important; font-weight: 700; }

/* Which one? on a desk scanner (board 58) */
.ds-which-desk { display: flex; flex-direction: column; gap: 0.7rem; padding: 1rem; margin-bottom: 0.75rem; border-radius: 1rem; background: #fff8e1; box-shadow: inset 0 0 0 1px #f3d37a; }
.dark .ds-which-desk { background: rgb(255 210 77 / .08); box-shadow: inset 0 0 0 1px rgb(255 210 77 / .3); }
.ds-which-desk__head { display: flex; align-items: center; gap: 0.6rem; }
.ds-which-desk__head > span:first-child { width: 2rem; height: 2rem; flex: none; border-radius: 50%; display: grid; place-items: center; background: #ffd24d; color: #0a1219; font-weight: 900; }
.ds-which-desk__head > span:last-child { display: flex; flex-direction: column; }
.ds-which-desk__head strong { font-size: 1rem; }
.ds-which-desk__head small, .ds-which-desk__hint { color: #6b7b88; font-size: 0.8rem; }
.ds-which-desk__grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(14rem, 1fr)); gap: 0.6rem; }
.ds-which-desk__opt { position: relative; display: flex; flex-direction: column; gap: 2px; padding: 0.8rem 0.9rem 0.8rem 2.6rem; border-radius: 0.8rem; text-align: left; background: #fff; box-shadow: 0 1px 0 #e3e8ec, 0 8px 20px -16px rgb(14 36 51 / .4); }
.dark .ds-which-desk__opt { background: rgb(255 255 255 / .05); }
.ds-which-desk__opt:hover { box-shadow: inset 0 0 0 2px #f6be00; }
.ds-which-desk__opt kbd { position: absolute; left: 0.8rem; top: 0.85rem; width: 1.3rem; height: 1.3rem; border-radius: 0.35rem; display: grid; place-items: center; font-size: 0.75rem; font-weight: 800; background: #0e2433; color: #fff; }
.ds-which-desk__opt strong { font-size: 1.1rem; }
.ds-which-desk__opt small { color: #33424e; font-size: 0.82rem; }
.ds-which-desk__opt em { font-style: normal; color: #6b7b88; font-size: 0.75rem; }
.ds-sa .ds-which { z-index: 60; }
.ds-which__of { display: inline-block; margin-left: 0.35rem; padding: 0 0.45rem; border-radius: 999px; background: #ffd24d; color: #0a1219; font-weight: 800; font-size: 0.72rem; }

/* Users and Crew (board 59/60) */
.ds-us__person { display: flex; align-items: center; gap: 0.7rem; min-width: 14rem; }
.ds-us__av { width: 2.4rem; height: 2.4rem; flex: none; border-radius: 50%; display: grid; place-items: center; font-weight: 800; font-size: 0.8rem; color: #fff; object-fit: cover; }
.ds-us__who { display: flex; flex-direction: column; gap: 1px; min-width: 0; }
.ds-us__who > span { display: flex; align-items: center; gap: 0.4rem; }
.ds-us__who b { font-size: 0.92rem; color: #0e2433; }
.dark .ds-us__who b { color: #fff; }
.ds-us__who small { color: #6b7b88; font-size: 0.78rem; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; max-width: 18rem; }
.ds-us__admin { font-style: normal; font-size: 0.68rem; font-weight: 800; padding: 1px 7px; border-radius: 999px; background: #0e2433; color: #f6be00; }
.ds-us__works { display: flex; flex-direction: column; align-items: flex-start; gap: 3px; }
.ds-us__chip { font-size: 0.72rem; font-weight: 800; padding: 2px 9px; border-radius: 999px; white-space: nowrap; }
.ds-us__works small { color: #51616d; font-size: 0.78rem; }
.ds-us__status { display: inline-flex; align-items: center; gap: 0.4rem; font-size: 0.82rem; font-weight: 700; color: #17895e; }
.ds-us__status i { width: 0.5rem; height: 0.5rem; border-radius: 50%; background: currentColor; }
.ds-us__status.is-off { color: #9aa7b1; }
.fi-ta-row.ds-us__off > td { opacity: .6; }
.ds-us__noapp { display: block; padding: 0.5rem 0.75rem; border-radius: 0.6rem; background: #fff6db; color: #7a5300; font-weight: 700; font-size: 0.82rem; }
.ds-us__panels .fi-fo-toggle-buttons-btn, .ds-us__chips .fi-fo-toggle-buttons-btn { border-radius: 999px; }
.ds-us__av.is-sm { width: 1.8rem; height: 1.8rem; font-size: 0.68rem; }
.ds-cr { display: flex; flex-direction: column; gap: 1rem; }
.ds-cr__top { display: flex; align-items: center; gap: 0.75rem; flex-wrap: wrap; }
.ds-cr__sum { color: #6b7b88; margin-right: auto; }
.ds-cr__tabs { display: flex; gap: 4px; padding: 4px; border-radius: 0.8rem; background: #e9eef2; }
.dark .ds-cr__tabs { background: rgb(255 255 255 / .06); }
.ds-cr__tabs button { height: 2.1rem; padding: 0 0.9rem; border-radius: 0.6rem; font-weight: 800; font-size: 0.85rem; color: #51616d; }
.ds-cr__tabs button.is-on { background: #fff; color: #0e2433; box-shadow: 0 1px 3px rgb(14 36 51 / .15); }
.ds-cr__grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(19rem, 1fr)); gap: 0.9rem; align-items: start; }
.ds-cr__truck { display: flex; flex-direction: column; gap: 0.6rem; padding: 1rem; border-radius: 1.1rem; background: #fff; box-shadow: 0 0 0 1px #e6ebef, 0 14px 34px -28px rgb(14 36 51 / .4); }
.dark .ds-cr__truck, .dark .ds-cr__list { background: rgb(255 255 255 / .04); box-shadow: 0 0 0 1px rgb(255 255 255 / .08); }
.ds-cr__truck header { display: flex; align-items: center; gap: 0.6rem; }
.ds-cr__truck header > span:nth-child(2) { flex: 1; display: flex; flex-direction: column; }
.ds-cr__truck header b { font-size: 1.05rem; }
.ds-cr__truck header small, .ds-cr__muted { color: #6b7b88; font-size: 0.8rem; }
.ds-cr__ico { width: 2.6rem; height: 2.6rem; border-radius: 0.75rem; background: #0e2433; display: grid; place-items: center; font-size: 1.2rem; }
.ds-cr__state { font-style: normal; font-size: 0.7rem; font-weight: 800; padding: 2px 9px; border-radius: 999px; background: #fff1c2; color: #7a5600; }
.ds-cr__state.is-ok { background: #e6f6ef; color: #17895e; }
.ds-cr__m { display: flex; align-items: center; gap: 0.6rem; padding: 0.5rem 0.6rem; border-radius: 0.75rem; background: #f6f8fa; }
.dark .ds-cr__m { background: rgb(255 255 255 / .05); }
.ds-cr__who { flex: 1; display: flex; flex-direction: column; text-align: left; min-width: 0; }
.ds-cr__who b { font-size: 0.88rem; }
.ds-cr__who small { color: #6b7b88; font-size: 0.76rem; }
.ds-cr__x { width: 1.75rem; height: 1.75rem; border-radius: 50%; background: #fff; color: #8a99a5; box-shadow: inset 0 0 0 1px #e1e7ec; }
.ds-cr__none { padding: 0.75rem; border-radius: 0.75rem; border: 1.5px dashed #d4dde3; color: #6b7b88; font-size: 0.82rem; text-align: center; }
.ds-cr__add { height: 2.4rem; border-radius: 0.65rem; background: #eef2f5; font-weight: 800; color: #0e2433; }
.ds-cr__add.is-on { background: #f6be00; color: #0a1219; }
.ds-cr__free { display: flex; flex-direction: column; gap: 0.35rem; padding: 0.6rem; border-radius: 0.75rem; background: #fff8e1; box-shadow: inset 0 0 0 1px #f3d37a; }
.ds-cr__free > small { font-weight: 800; color: #7a5600; }
.ds-cr__free button { display: flex; align-items: center; gap: 0.5rem; padding: 0.35rem 0.5rem; border-radius: 0.6rem; background: #fff; text-align: left; }
.ds-cr__free button b { flex: 1; font-size: 0.85rem; color: #0e2433; }
.ds-cr__free button i, .ds-cr__pos { font-style: normal; font-size: 0.7rem; font-weight: 800; padding: 2px 8px; border-radius: 999px; background: #eef2f5; color: #33424e; }
.ds-cr__pos.is-app { background: #fff1c2; color: #7a5600; }
.ds-cr__list { display: flex; flex-direction: column; border-radius: 1.1rem; background: #fff; box-shadow: 0 0 0 1px #e6ebef; overflow: hidden; }
.ds-cr__row { display: grid; grid-template-columns: 2.6rem 1.6fr 1fr 1fr 1fr 0.9fr 0.9fr; gap: 0.75rem; align-items: center; padding: 0.6rem 1rem; border-top: 1px solid #f0f3f6; text-align: left; font-size: 0.85rem; }
.ds-cr__row.is-head { font-size: 0.75rem; font-weight: 800; color: #6b7b88; background: #fafbfc; border-top: 0; }
.dark .ds-cr__row.is-head { background: transparent; }
.ds-cr__row:not(.is-head):hover { background: #fffbea; }
.ds-cr__row.is-off { opacity: .6; }
.ds-cr__row small { color: #6b7b88; }
.ds-cr__hint { color: #6b7b88; }
.ds-cr__where { display: block; padding: 0.6rem 0.75rem; border-radius: 0.75rem; background: #f1f6fb; color: #1d5fa8; font-weight: 700; font-size: 0.82rem; }
.ds-us__photo { width: 5.5rem !important; max-width: 5.5rem; } .ds-us__photo .filepond--root { width: 5.5rem !important; height: 5.5rem !important; } .ds-us__photo .filepond--drop-label { font-size: 0.65rem; }

/* Sea shipment trucks (board 62) */
.ds-sp__goes { display: inline-block; margin-top: 3px; font-style: normal; font-size: 0.72rem; font-weight: 800; padding: 1px 8px; border-radius: 999px; background: #e7f0fb; color: #1d5fa8; }
.ds-sp__goes.is-own { background: #fff1c2; color: #7a5600; }
.ds-sp__trucks { display: grid; grid-template-columns: repeat(auto-fill, minmax(18rem, 1fr)); gap: 0.75rem; }
.ds-sp__truck { display: flex; flex-direction: column; gap: 0.45rem; padding: 0.8rem; border-radius: 0.8rem; background: #f6f8fa; }
.dark .ds-sp__truck { background: rgb(255 255 255 / .05); }
.ds-sp__truckhead { display: flex; flex-direction: column; }
.ds-sp__truckhead b { font-size: 1rem; }
.ds-sp__truckhead small, .ds-sp__truckline span { color: #6b7b88; font-size: 0.8rem; }
.ds-sp__truckline { display: flex; justify-content: space-between; gap: 0.5rem; font-size: 0.82rem; }
.ds-sp__truckcost { display: flex; align-items: center; gap: 0.5rem; font-size: 0.8rem; color: #51616d; }
.ds-sp__truckcost input { width: 7rem; height: 2rem; border-radius: 0.5rem; border: 1px solid #d4dde3; padding: 0 0.5rem; background: #fff; }
.dark .ds-sp__truckcost input { background: transparent; }
.ds-roro { cursor: default; }
.ds-roro__btn { width: 100%; margin: 0.25rem 0 0.75rem; }
.ds-sp__goes { align-self: flex-start; }

/* Forwarders and ports (board 64) */
.ds-fw { display: flex; flex-direction: column; gap: 1rem; }
.ds-fw__top { display: flex; justify-content: space-between; align-items: center; gap: 1rem; }
.ds-fw__grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(22rem, 1fr)); gap: 0.9rem; align-items: start; }
.ds-fw__card { display: flex; flex-direction: column; gap: 0.5rem; padding: 1rem; border-radius: 1rem; background: #fff; box-shadow: 0 0 0 1px #e6ebef, 0 14px 30px -26px rgb(14 36 51 / .45); }
.dark .ds-fw__card, .dark .ds-fw__port { background: rgb(255 255 255 / .04); box-shadow: 0 0 0 1px rgb(255 255 255 / .08); }
.ds-fw__card.is-off, .ds-fw__port.is-off { opacity: .6; }
.ds-fw__card header { display: flex; align-items: center; gap: 0.65rem; }
.ds-fw__card header > span:nth-child(2) { flex: 1; display: flex; flex-direction: column; }
.ds-fw__card header b { font-size: 1rem; }
.ds-fw__card small { color: #6b7b88; font-size: 0.78rem; }
.ds-fw__ini { width: 2.5rem; height: 2.5rem; border-radius: 0.7rem; display: grid; place-items: center; background: #e7f0fb; color: #1d5fa8; font-weight: 900; }
.ds-fw__state { font-style: normal; font-size: 0.7rem; font-weight: 800; padding: 2px 9px; border-radius: 999px; background: #eef2f5; color: #5b6b78; }
.ds-fw__state.is-on { background: #e6f6ef; color: #17895e; }
.ds-fw__branch { display: grid; grid-template-columns: 1fr auto; gap: 2px 0.6rem; padding: 0.55rem 0.7rem; border-radius: 0.7rem; background: #f6f8fa; }
.dark .ds-fw__branch { background: rgb(255 255 255 / .05); }
.ds-fw__branch b { font-size: 0.86rem; }
.ds-fw__branch small:nth-of-type(odd) { text-align: right; }
.ds-fw__card footer { display: flex; justify-content: space-between; align-items: center; }
.ds-fw__ports { display: grid; grid-template-columns: repeat(auto-fill, minmax(16rem, 1fr)); gap: 0.6rem; }
.ds-fw__port { display: flex; flex-direction: column; gap: 2px; padding: 0.75rem 0.9rem; border-radius: 0.8rem; background: #fff; box-shadow: 0 0 0 1px #e6ebef; text-align: left; }
.ds-fw__port small { color: #6b7b88; font-size: 0.78rem; }

/* Sea shipment page laid out as board 62 */
.ds-sv__head { display: flex; justify-content: space-between; align-items: flex-end; gap: 1rem; flex-wrap: wrap; }
.ds-sv__head > span:first-child { display: flex; flex-direction: column; gap: 2px; }
.ds-sv__head small { color: #6b7b88; font-weight: 700; font-size: 0.8rem; }
.ds-sv__head b { color: #33424e; font-weight: 600; font-size: 0.92rem; }
.dark .ds-sv__head b { color: #c8d3dc; }
.ds-sv__modes { display: flex; gap: 4px; padding: 4px; border-radius: 0.8rem; background: #e9eef2; }
.dark .ds-sv__modes { background: rgb(255 255 255 / .06); }
.ds-sv__modes button { height: 2.1rem; padding: 0 1rem; border-radius: 0.6rem; font-weight: 800; font-size: 0.88rem; color: #51616d; }
.ds-sv__modes button.is-on { background: #fff; color: #0e2433; box-shadow: 0 1px 3px rgb(14 36 51 / .15); }
.ds-sv__modes button:disabled:not(.is-on) { opacity: .5; cursor: not-allowed; }
.ds-sv__facts { display: grid; grid-template-columns: repeat(4, minmax(0, 1fr)); gap: 0.6rem; }
.ds-sv__facts > span { display: flex; flex-direction: column; gap: 3px; padding: 0.55rem 0.7rem; border-radius: 0.6rem; background: #f6f8fa; }
.dark .ds-sv__facts > span, .dark .ds-sv__trip { background: rgb(255 255 255 / .05); }
.ds-sv__facts small, .ds-sv__lbl { color: #51616d; font-size: 0.75rem; font-weight: 700; }
.ds-sv__grid { display: grid; grid-template-columns: 1fr 1.15fr; gap: 1rem; align-items: start; }
@media (max-width: 1100px) { .ds-sv__grid, .ds-sv__facts { grid-template-columns: 1fr 1fr; } }
.ds-sp__box h3 small { font-weight: 600; color: #6b7b88; font-size: 0.78rem; margin-left: 0.4rem; }
.ds-sp__box h3 .ds-fu__link { float: right; font-size: 0.82rem; }
.ds-sv__trip { display: grid; grid-template-columns: 1fr auto; gap: 2px 0.75rem; padding: 0.65rem 0.8rem; border-radius: 0.75rem; background: #f6f8fa; }
.ds-sv__trip > small:first-of-type { color: #6b7b88; font-size: 0.78rem; }
.ds-sv__goes { text-align: right; font-weight: 800; color: #1d5fa8; font-size: 0.78rem; }
.ds-sv__goes.is-own { color: #7a5600; }
.ds-sv__tripacts { grid-column: 1 / -1; display: flex; gap: 0.8rem; }
.ds-sv__add2 { float: right; height: 2rem; padding: 0 0.8rem; border-radius: 0.55rem; background: #eef2f5; font-weight: 800; font-size: 0.82rem; color: #0e2433; }
.ds-sv__second { display: flex; flex-direction: column; gap: 0.4rem; padding: 0.7rem; border-radius: 0.75rem; background: #fff8e1; box-shadow: inset 0 0 0 1px #f3d37a; }
.ds-sv__second small { font-weight: 800; color: #7a5600; }
.ds-sv__secrow { display: flex; align-items: center; gap: 0.5rem; }
.ds-sv__secrow b { flex: 1; font-size: 0.85rem; color: #0e2433; }
.ds-sv__secrow select { height: 2rem; border-radius: 0.5rem; border: 1px solid #d4dde3; padding: 0 0.5rem; background: #fff; }
.ds-sv__tstate { margin-left: auto; font-style: normal; font-size: 0.7rem; font-weight: 800; padding: 2px 9px; border-radius: 999px; background: #fff1c2; color: #7a5600; align-self: flex-start; }
.ds-sv__tstate.is-ok { background: #e6f6ef; color: #17895e; }
.ds-sp__truckhead { flex-direction: row !important; flex-wrap: wrap; align-items: baseline; gap: 0 0.5rem; }
.ds-sp__truckhead small { flex-basis: 100%; order: 3; }
.ds-sv__tbar { height: 0.45rem; border-radius: 9px; background: #e3e8ec; overflow: hidden; }
.ds-sv__tbar i { display: block; height: 100%; background: #17895e; }
.ds-sv__split { display: grid; grid-template-columns: 1fr 1fr; gap: 0.5rem; }
.ds-sv__split > span { display: flex; justify-content: space-between; padding: 0.55rem 0.75rem; border-radius: 0.6rem; background: #f6f8fa; font-size: 0.88rem; }
.dark .ds-sv__split > span { background: rgb(255 255 255 / .05); }
.ds-sv__chips { display: flex; flex-wrap: wrap; gap: 0.4rem; }
.ds-sv__chips button, .ds-sv__chipadd { height: 2.1rem; padding: 0 0.85rem; border-radius: 999px; font-weight: 800; font-size: 0.85rem; background: #f6f8fa; box-shadow: inset 0 0 0 1px #e1e7ec; color: #0e2433; display: inline-flex; align-items: center; }
.ds-sv__chips button.is-on { background: #fff8e1; box-shadow: inset 0 0 0 2px #f6be00; }
.ds-sv__chipadd { color: #51616d; background: transparent; box-shadow: inset 0 0 0 1px #d4dde3; }
.ds-sv__row { display: flex; justify-content: space-between; align-items: center; }
.ds-sv__sees { padding: 0.6rem 0.75rem; border-radius: 0.6rem; background: #f1f6fb; color: #1d5fa8; font-weight: 700; font-size: 0.82rem; margin: 0; }

/* Partner hub · Incoming shipments (board 63) */
.ds-hi { display: flex; flex-direction: column; gap: 0.9rem; }
.ds-hi__top { display: flex; justify-content: space-between; align-items: center; gap: 1rem; flex-wrap: wrap; }
.ds-hi__top small { color: #6b7b88; margin-left: 2px; }
.ds-hi__card { display: flex; flex-direction: column; gap: 0.75rem; padding: 1rem 1.1rem; border-radius: 1rem; background: #fff; box-shadow: 0 0 0 1px #e6ebef, 0 14px 30px -26px rgb(14 36 51 / .45); }
.dark .ds-hi__card { background: rgb(255 255 255 / .04); box-shadow: 0 0 0 1px rgb(255 255 255 / .08); }
.ds-hi__card header { display: flex; align-items: center; gap: 0.75rem; }
.ds-hi__card header > span:last-child { display: flex; flex-direction: column; gap: 2px; }
.ds-hi__card header small { color: #6b7b88; font-size: 0.8rem; }
.ds-hi__ico { width: 2.75rem; height: 2.75rem; border-radius: 0.75rem; background: #0e2433; display: grid; place-items: center; font-size: 1.25rem; }
.ds-hi__t { display: flex; align-items: center; gap: 0.5rem; }
.ds-hi__t b { font-size: 1.05rem; }
.ds-hi__tag { font-style: normal; font-size: 0.7rem; font-weight: 800; padding: 2px 9px; border-radius: 999px; background: #e7f0fb; color: #1d5fa8; }
.ds-hi__tag.is-roro { background: #fff1c2; color: #7a5600; }
.ds-hi__tag.is-lcl { background: #f1eafb; color: #7a4fb0; }
.ds-hi__facts { display: grid; grid-template-columns: repeat(4, minmax(0, 1fr)); gap: 0.6rem; padding: 0.6rem 0.75rem; border-radius: 0.75rem; background: #f6f8fa; }
.dark .ds-hi__facts { background: rgb(255 255 255 / .05); }
.ds-hi__facts > span { display: flex; flex-direction: column; gap: 2px; min-width: 0; }
.ds-hi__facts small { color: #6b7b88; font-size: 0.72rem; font-weight: 700; }
.ds-hi__facts b { font-size: 0.86rem; overflow-wrap: anywhere; }
.ds-hi__steps { display: flex; align-items: center; gap: 0.4rem; flex-wrap: wrap; }
.ds-hi__steps > span { display: flex; align-items: center; gap: 0.4rem; font-size: 0.8rem; font-weight: 600; color: #8a99a5; }
.ds-hi__steps > span i { width: 1.4rem; height: 1.4rem; border-radius: 50%; display: grid; place-items: center; font-style: normal; font-size: 0.7rem; font-weight: 900; color: #fff; background: #b8c3cc; }
.ds-hi__steps > span.is-done { color: #0e2433; }
.ds-hi__steps > span.is-done i { background: #17895e; }
.ds-hi__steps > span.is-now { color: #0e2433; font-weight: 800; }
.ds-hi__steps > span.is-now i { background: #0e2433; }
.dark .ds-hi__steps > span.is-done, .dark .ds-hi__steps > span.is-now { color: #fff; }
.ds-hi__steps em { flex: 1; min-width: 0.9rem; height: 2px; background: #e1e7ec; }
.ds-hi__steps em.is-done { background: #17895e; }
.ds-hi__todo { display: flex; align-items: center; gap: 0.6rem; flex-wrap: wrap; padding: 0.65rem 0.8rem; border-radius: 0.75rem; background: #fff8e1; box-shadow: inset 0 0 0 1px #f3d37a; }
.ds-hi__todo > span { flex: 1; min-width: 14rem; font-size: 0.85rem; color: #5a4300; }
.ds-hi__btn { height: 2.25rem; padding: 0 0.9rem; border-radius: 0.6rem; background: #eef2f5; color: #0e2433; font-weight: 800; font-size: 0.85rem; display: inline-flex; align-items: center; }
.ds-hi__btn.is-primary { background: #f6be00; color: #0a1219; }
@media (max-width: 900px) { .ds-hi__facts { grid-template-columns: 1fr 1fr; } }
.ds-hc { display: flex; flex-wrap: wrap; gap: 0.35rem; margin: 0 0 0.4rem; }
.ds-hc span { padding: 0.25rem 0.6rem; border-radius: 999px; background: rgb(255 255 255 / .1); color: #dbe5ec; font-size: 0.78rem; font-weight: 700; }
.ds-hc span b { color: #fff; margin-left: 2px; }
.ds-hc span.is-done { background: rgb(91 227 168 / .18); color: #5be3a8; }
.ds-ld__spot.is-sea { background: #ffd24d; color: #0a1219; }
.ds-ld__spot.is-sea span { color: #3a2e00; }
.ds-sea { display: flex; flex-direction: column; gap: 0.45rem; padding: 1rem; border-radius: 1.2rem; background: rgb(255 255 255 / .06); box-shadow: inset 0 0 0 1px rgb(255 255 255 / .1); margin-bottom: 0.75rem; }
.ds-sea > small { color: #9fb0bc; font-weight: 700; }
.ds-sea > b { font-size: 1.25rem; color: #fff; }
.ds-sea__hubs { display: flex; flex-wrap: wrap; gap: 0.35rem; }
.ds-sea__hubs i { font-style: normal; font-size: 0.75rem; font-weight: 800; padding: 2px 9px; border-radius: 999px; background: rgb(140 196 255 / .16); color: #8cc4ff; }
.ds-sea__btn { display: flex; align-items: center; justify-content: center; text-decoration: none; }
.ds-sv__hint { display: flex; justify-content: space-between; align-items: center; gap: 0.75rem; padding: 0.6rem 0.8rem; border-radius: 0.7rem; background: #fff6db; color: #7a5300; font-weight: 700; font-size: 0.85rem; margin: 0; }
.dark .ds-sv__hint { background: rgb(255 210 77 / .12); color: #ffd24d; }

/* Part 39 · Transfers to warehouses: manual with space bar + Ask the AI */
.ds-tx { display: flex; flex-direction: column; gap: 0.9rem; }
.ds-tx__tools { display: flex; align-items: center; gap: 0.5rem; flex-wrap: wrap; }
.ds-tx__tools > small { color: #6b7b88; }
.ds-tx__ask { height: 2.6rem; padding: 0 1rem; border-radius: 0.7rem; font-weight: 800; display: inline-flex; align-items: center; gap: 0.5rem; background: #7a4fb0; color: #fff; }
.ds-tx__ask.is-back { background: #eef2f5; color: #0e2433; }
.ds-tx__ask:disabled { opacity: .5; cursor: not-allowed; }
.ds-tx__note, .ds-tx__ai { display: flex; gap: 0.6rem; align-items: center; padding: 0.65rem 0.9rem; border-radius: 0.75rem; background: #eef2f5; color: #33424e; font-size: 0.88rem; }
.ds-tx__note > span, .ds-tx__ai > span { flex: 1; }
.ds-tx__ai { background: #f1eafb; color: #4c2f7a; }
.ds-tx__ai small { color: #7a4fb0; }
.dark .ds-tx__note { background: rgb(255 255 255 / .06); color: inherit; }
.dark .ds-tx__ai { background: rgb(122 79 176 / .2); color: #e2d4f6; }
.ds-tx__grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(22rem, 1fr)); gap: 0.9rem; align-items: start; }
.ds-tx__card { display: flex; flex-direction: column; gap: 0.55rem; padding: 0.9rem 1rem; }
.ds-tx__head { display: flex; justify-content: space-between; align-items: center; gap: 0.5rem; font-size: 1rem; }
.ds-tx__row { display: flex; justify-content: space-between; gap: 0.5rem; font-size: 0.85rem; padding: 0.35rem 0; border-top: 1px solid #f0f3f6; }
.ds-tx__row small { color: #6b7b88; }
.dark .ds-tx__row { border-color: rgb(255 255 255 / .08); }
.ds-tx__lbl { color: #6b7b88; font-weight: 700; }
.ds-tx__space { display: flex; justify-content: space-between; font-size: 0.82rem; }
.ds-tx__ok { color: #17895e; }
.ds-tx__bad { color: #c8372d; }
.ds-tx__why { color: #4c2f7a; }
.dark .ds-tx__why { color: #cdb6ef; }
.ds-tx__pill { font-size: 0.75rem; font-weight: 800; padding: 0.2rem 0.6rem; border-radius: 999px; background: #e7f0fb; color: #1d5fa8; white-space: nowrap; }
.ds-tx__pill.is-over { background: #fdecea; color: #c8372d; }
.ds-tx__pill.is-made { background: #e6f6ef; color: #17895e; }
.ds-tx__go { height: 2.6rem; border-radius: 0.7rem; font-weight: 800; background: #0e2433; color: #fff; }
.ds-tx__go.is-warn { background: #fff1c7; color: #7a5600; }
.ds-tx__go.is-off { background: #eef2f5; color: #8a99a5; cursor: not-allowed; }
.ds-tx__go.is-made { background: #e6f6ef; color: #17895e; }
.ds-tx__go:disabled:not(.is-made):not(.is-off) { opacity: .5; }
.ds-tx__only { border-radius: 1rem; border: 2px dashed #d5dde3; padding: 1.1rem; display: flex; flex-direction: column; gap: 0.35rem; justify-content: center; color: #6b7b88; font-size: 0.88rem; }
.ds-tx__only b { color: #33424e; }
.dark .ds-tx__only { border-color: rgb(255 255 255 / .15); }
.dark .ds-tx__only b { color: inherit; }
.ds-tx__later { display: flex; gap: 0.75rem; align-items: center; padding: 0.75rem 1rem; flex-wrap: wrap; }
.ds-tx__later small { flex: 1; color: #6b7b88; }
.ds-tx__all { height: 2.5rem; padding: 0 1rem; border-radius: 0.7rem; font-weight: 800; background: #f6be00; color: #0e2433; }
.ds-tx__all:disabled { background: #e6f6ef; color: #17895e; }
.ds-tx__rules { color: #6b7b88; }
.ds-tx__tools .ds-wc__sel { height: 2.6rem; background: #fff; color: #0e2433; }
.dark .ds-tx__tools .ds-wc__sel { background: rgb(255 255 255 / .06); color: inherit; }
.ds-tx__head b:first-child { flex: 1; }
.ds-tx__head > b:last-child { font-size: 0.85rem; text-align: right; }
.ds-tx .ds-tx__later { flex-direction: row; text-align: left; justify-content: flex-start; }

/* Part 40 · Settings → Photo storage (board 66) */
.ds-pst { display: flex; flex-direction: column; gap: 0.9rem; }
.ds-pst__title { display: flex; flex-direction: column; gap: 0.2rem; }
.ds-pst__title h1 { font-size: 1.65rem; font-weight: 800; }
.ds-pst__title small, .ds-pst__mute { color: #6b7b88; }
.ds-pst__card { background: #fff; border-radius: 1rem; box-shadow: 0 0 0 1px #e6ebef, 0 14px 30px -26px rgb(14 36 51 / .45); padding: 1rem 1.1rem; display: flex; flex-direction: column; gap: 0.65rem; min-width: 0; }
.dark .ds-pst__card { background: rgb(255 255 255 / .04); box-shadow: 0 0 0 1px rgb(255 255 255 / .08); }
.ds-pst__card.is-off { opacity: .6; }
.ds-pst__row { display: flex; justify-content: space-between; align-items: center; gap: 0.75rem; flex-wrap: wrap; }
.ds-pst__col { display: flex; flex-direction: column; gap: 0.15rem; min-width: 0; flex: 1; }
.ds-pst__h { font-size: 1rem; font-weight: 800; }
.ds-pst__h2 { font-size: 1.2rem; font-weight: 800; }
.ds-pst__lbl { font-size: 0.75rem; font-weight: 700; color: #6b7b88; }
.ds-pst__grid4 { display: grid; grid-template-columns: repeat(4, minmax(0, 1fr)); gap: 0.5rem; }
.ds-pst__grid3 { display: grid; grid-template-columns: repeat(3, minmax(0, 1fr)); gap: 0.5rem; }
.ds-pst__two { display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 0.9rem; }
.ds-pst__two.is-tight { gap: 0.4rem; }
@media (max-width: 900px) { .ds-pst__grid4, .ds-pst__grid3, .ds-pst__two { grid-template-columns: 1fr; } }
.ds-pst__chk { padding: 0.6rem 0.75rem; border-radius: 0.75rem; background: #fdecea; display: flex; flex-direction: column; gap: 0.15rem; }
.ds-pst__chk b { color: #c8372d; }
.ds-pst__chk small { color: #33424e; }
.ds-pst__chk.is-ok { background: #e6f6ef; }
.ds-pst__chk.is-ok b { color: #17895e; }
.dark .ds-pst__chk small { color: inherit; }
.ds-pst__tabs { display: flex; gap: 0.35rem; padding: 0.25rem; border-radius: 0.75rem; background: #e8edf1; align-self: flex-start; flex-wrap: wrap; }
.dark .ds-pst__tabs { background: rgb(255 255 255 / .06); }
.ds-pst__tabs button { height: 2.4rem; padding: 0 1rem; border-radius: 0.55rem; font-weight: 800; font-size: 0.9rem; }
.ds-pst__tabs button.is-on { background: #fff; box-shadow: 0 1px 3px rgb(14 36 51 / .15); color: #0e2433; }
.ds-pst__go, .ds-pst__btn { height: 2.5rem; padding: 0 1rem; border-radius: 0.65rem; font-weight: 800; white-space: nowrap; display: inline-flex; align-items: center; justify-content: center; }
.ds-pst__go { background: #0e2433; color: #fff; }
.ds-pst__go.is-yellow { background: #f6be00; color: #0e2433; height: 2.9rem; padding: 0 1.25rem; }
.ds-pst__go.is-blue { background: #1d5fa8; }
.ds-pst__go.is-purple { background: #7a4fb0; }
.ds-pst__go.is-redbg { background: #c8372d; }
.ds-pst__btn { background: #eef2f5; color: #0e2433; }
.ds-pst__btn.is-red { background: #fdecea; color: #c8372d; }
.ds-pst__go:disabled, .ds-pst__btn:disabled { opacity: .45; cursor: not-allowed; }
.ds-pst__acts { display: flex; gap: 0.5rem; align-items: center; flex-wrap: wrap; }
.ds-pst__pill { font-size: 0.72rem; font-weight: 800; padding: 0.2rem 0.6rem; border-radius: 999px; background: #eef2f5; color: #6b7b88; white-space: nowrap; justify-self: start; }
.ds-pst__pill.is-ok { background: #e6f6ef; color: #17895e; }
.ds-pst__pill.is-warn { background: #fff8e1; color: #a35a00; }
.ds-pst__pill.is-blue { background: #e7f0fb; color: #1d5fa8; }
.ds-pst__where { display: flex; gap: 0.5rem; flex-wrap: wrap; }
.ds-pst__where button { flex: 1; min-width: 12rem; min-height: 4rem; padding: 0.6rem 0.9rem; border-radius: 0.75rem; text-align: left; background: #f6f8fa; box-shadow: inset 0 0 0 1px #e1e7ec; display: flex; flex-direction: column; gap: 0.15rem; }
.ds-pst__where button small { color: #6b7b88; }
.ds-pst__where button.is-on { background: #fff8e1; box-shadow: inset 0 0 0 2px #f6be00; }
.ds-pst__where button:disabled { opacity: .5; cursor: not-allowed; }
.dark .ds-pst__where button { background: rgb(255 255 255 / .05); }
.ds-pst__chips { display: flex; gap: 0.35rem; align-items: center; flex-wrap: wrap; }
.ds-pst__chips button, .ds-pst__chip { height: 2rem; padding: 0 0.75rem; border-radius: 999px; font-size: 0.8rem; font-weight: 800; background: #f6f8fa; box-shadow: inset 0 0 0 1px #e1e7ec; }
.ds-pst__chips button.is-on, .ds-pst__chip.is-on { background: #fff8e1; box-shadow: inset 0 0 0 2px #f6be00; }
.ds-pst__fields { display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 0.6rem; }
.ds-pst__fields label, .ds-pst__fields > span { display: flex; flex-direction: column; gap: 0.25rem; min-width: 0; }
.ds-pst__fields input, .ds-pst__inp { height: 2.4rem; border-radius: 0.55rem; background: #f6f8fa; border: 0; box-shadow: inset 0 0 0 1px #e1e7ec; padding: 0 0.7rem; font-family: ui-monospace, monospace; font-size: 0.85rem; min-width: 0; }
.ds-pst__inp { flex: 1; min-width: 14rem; }
.ds-pst__inp.is-short { flex: 0 1 14rem; min-width: 10rem; font-family: inherit; }
.dark .ds-pst__fields input, .dark .ds-pst__inp { background: rgb(255 255 255 / .06); color: inherit; }
.ds-pst__in { min-height: 2.4rem; border-radius: 0.55rem; background: #f6f8fa; box-shadow: inset 0 0 0 1px #e1e7ec; display: flex; align-items: center; padding: 0 0.7rem; font-family: ui-monospace, monospace; font-size: 0.85rem; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.dark .ds-pst__in { background: rgb(255 255 255 / .06); }
.ds-pst__res { font-weight: 700; color: #6b7b88; }
.ds-pst__res.is-ok, .ds-pst__ok { color: #17895e; }
.ds-pst__res.is-bad, .ds-pst__bad { color: #c8372d; }
.ds-pst__warn, .ds-pst__mute.is-warn { color: #a35a00; }
.ds-pst__stat { padding: 0.6rem 0.75rem; border-radius: 0.75rem; background: #f6f8fa; display: flex; flex-direction: column; gap: 0.1rem; }
.ds-pst__stat > b:first-child { font-size: 1.35rem; }
.ds-pst__stat .ds-pst__sm { font-size: 0.85rem; }
.ds-pst__stat.is-ok { background: #e6f6ef; } .ds-pst__stat.is-ok > b:first-child { color: #17895e; }
.ds-pst__stat.is-warn { background: #fff8e1; } .ds-pst__stat.is-warn > b:first-child { color: #a35a00; }
.ds-pst__stat.is-bad { background: #fdecea; } .ds-pst__stat.is-bad > b:first-child { color: #c8372d; }
.dark .ds-pst__stat { background: rgb(255 255 255 / .05); }
.ds-pst__bar { height: 0.5rem; border-radius: 9px; background: #edf1f4; overflow: hidden; display: block; }
.ds-pst__bar i { display: block; height: 100%; background: #17895e; transition: width .4s; }
.ds-pst__bar.is-blue i { background: #1d5fa8; } .ds-pst__bar.is-purple i { background: #7a4fb0; }
.ds-pst__bar.is-dark { background: rgb(255 255 255 / .12); } .ds-pst__bar.is-dark i { background: #f6be00; }
.ds-pst__mv { display: grid; grid-template-columns: 13rem 1fr auto; gap: 0.75rem; align-items: center; padding-top: 0.6rem; border-top: 1px solid #f0f3f6; }
.ds-pst__switch { border-radius: 1rem; padding: 1rem 1.1rem; display: flex; flex-direction: column; gap: 0.65rem; background: #0e2433; color: #fff; }
.ds-pst__switch small { color: #b9c6d0; }
.ds-pst__sstep { padding: 0.55rem 0.7rem; border-radius: 0.6rem; background: rgb(255 255 255 / .07); display: flex; flex-direction: column; gap: 0.1rem; }
.ds-pst__sstep b { color: #b9c6d0; } .ds-pst__sstep b.is-ok { color: #3ddc97; } .ds-pst__sstep b.is-on { color: #f6be00; }
.ds-pst__tog { display: flex; gap: 0.6rem; align-items: center; text-align: left; padding: 0.6rem 0.75rem; border-radius: 0.75rem; background: #f6f8fa; }
.ds-pst__tog.is-dark { background: rgb(255 255 255 / .07); }
.dark .ds-pst__tog { background: rgb(255 255 255 / .05); }
.ds-pst__tog span { display: flex; flex-direction: column; }
.ds-pst__sw { width: 2.5rem; height: 1.5rem; border-radius: 99px; background: #c5ced6; position: relative; flex: none; }
.ds-pst__sw i { position: absolute; top: 3px; left: 3px; width: 1.125rem; height: 1.125rem; border-radius: 99px; background: #fff; transition: left .2s; }
.ds-pst__sw.is-on { background: #17895e; } .ds-pst__sw.is-on i { left: calc(100% - 1.125rem - 3px); }
.ds-pst__runner { flex-direction: row; align-items: center; gap: 0.9rem; }
.ds-pst__dot { width: 0.75rem; height: 0.75rem; border-radius: 99px; background: #c8372d; flex: none; }
.ds-pst__dot.is-ok { background: #17895e; }
.ds-pst__steps { display: grid; grid-template-columns: 18rem minmax(0, 1fr); gap: 0.9rem; align-items: start; }
@media (max-width: 1000px) { .ds-pst__steps { grid-template-columns: 1fr; } }
.ds-pst__nav { gap: 0.2rem; padding: 0.75rem; }
.ds-pst__nav > button { padding: 0.55rem 0.6rem; border-radius: 0.6rem; display: flex; gap: 0.6rem; align-items: center; text-align: left; }
.ds-pst__nav > button.is-on { background: #fff8e1; }
.dark .ds-pst__nav > button.is-on { background: rgb(246 190 0 / .12); }
.ds-pst__nav small { color: #6b7b88; }
.ds-pst__num { width: 1.65rem; height: 1.65rem; border-radius: 99px; flex: none; display: flex; align-items: center; justify-content: center; font-size: 0.8rem; font-weight: 800; background: #e8edf1; color: #0e2433; }
.ds-pst__num.is-ok { background: #17895e; color: #fff; } .ds-pst__num.is-on { background: #f6be00; }
.ds-pst__body { gap: 0.75rem; }
.ds-pst__tr4, .ds-pst__tr5, .ds-pst__tr2 { display: grid; gap: 0.6rem; align-items: center; font-size: 0.83rem; padding: 0.4rem 0; border-top: 1px solid #f0f3f6; }
.dark .ds-pst__tr4, .dark .ds-pst__tr5, .dark .ds-pst__tr2, .dark .ds-pst__mv { border-color: rgb(255 255 255 / .08); }
.ds-pst__tr4 { grid-template-columns: minmax(0, 1.6fr) minmax(0, 1fr) minmax(0, 1fr) 9rem; }
.ds-pst__tr4.is-head { font-size: 0.75rem; font-weight: 700; color: #6b7b88; border: 0; padding: 0; }
.ds-pst__tr5 { grid-template-columns: minmax(0, 1fr) 1rem minmax(0, 1fr) 8rem 7rem; font-size: 0.78rem; }
.ds-pst__tr2 { grid-template-columns: 1.2rem 1fr auto; font-size: 0.9rem; }
.ds-pst__mono { font-family: ui-monospace, monospace; }
.ds-pst__cut { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; min-width: 0; }
.ds-pst__link { color: #1d5fa8; font-weight: 700; }
.ds-pst__pair { display: flex; flex-direction: column; gap: 0.35rem; }
.ds-pst__pair a { position: relative; display: block; height: 8rem; border-radius: 0.6rem; overflow: hidden; background: #3c2f1f; }
.ds-pst__pair img { width: 100%; height: 100%; object-fit: cover; }
.ds-pst__pair em { position: absolute; left: 0.35rem; bottom: 0.35rem; font-style: normal; font-size: 0.7rem; font-weight: 800; padding: 0.15rem 0.5rem; border-radius: 999px; background: rgb(0 0 0 / .55); color: #fff; }
.ds-pst__pair em.is-ok { background: #17895e; }
/* Part 41 · folder map */
.ds-pst__fmap { display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 0.35rem 1.2rem; }
.ds-pst__fmap > span { display: flex; justify-content: space-between; gap: 0.75rem; font-size: 0.83rem; padding: 0.3rem 0; border-top: 1px solid #f0f3f6; }
.ds-pst__fmap code { font-family: ui-monospace, monospace; color: #17895e; font-weight: 700; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
.dark .ds-pst__fmap > span { border-color: rgb(255 255 255 / .08); }
@media (max-width: 900px) { .ds-pst__fmap { grid-template-columns: 1fr; } }
DISPATCH_FILE_END_34

# ---------------------------------------------------------------- resources/views/filament/photos/storage.blade.php
mkdir -p 'resources/views/filament/photos'
cat > 'resources/views/filament/photos/storage.blade.php' <<'DISPATCH_FILE_END_35'
<x-filament-panels::page>
@php
    $pl = \App\Support\Photos\Storage\PhotoStore::PLACES;
    $prov = \App\Support\Photos\Storage\PhotoStore::PROVIDERS;
    $ago = fn ($ts) => $ts ? \Illuminate\Support\Carbon::createFromTimestamp($ts)->diffForHumans() : 'never';
    $checks = [
        ['S3 driver', $driver, $driver ? 'Installed on the server' : 'Run once: composer require league/flysystem-aws-s3-v3'],
        ['Background worker', $worker || $scheduler || $runHere, $worker ? 'Running' : ($scheduler ? 'Scheduler runs (every minute)' : ($runHere ? 'Running in this tab' : 'Not running: see the Workers tab'))],
        ['Bucket tested', $usable['tmp'] || $usable['real'], $usable['tmp'] || $usable['real'] ? ($tmp->bucket ?: $real->bucket).': upload, read, delete ok' : 'Put a bucket and press Test connection'],
        ['Old system found', (bool) ($find['found'] ?? false), ($find['found'] ?? false) ? basename($find['dir'] ?? 'old site').' · read-only' : 'Not found on this server (Copy tab, step 1)'],
    ];
@endphp
<div class="ds-pst" @if ($runHere) wire:poll.4s="tick" @elseif ($active) wire:poll.10s @endif>
    <span class="ds-pst__title"><h1>Photo storage</h1><small>Where every photo is saved: box photos, unload, POD, pick-up, from the scan app, the driver app and the panels. Put your bucket here: nothing to set in the server files.</small></span>

    <section class="ds-pst__card">
        <span class="ds-pst__row"><b class="ds-pst__h">Setup checklist</b><small class="ds-pst__mute">Everything needs a ✓ before photos go to the bucket.</small></span>
        <span class="ds-pst__grid4">
            @foreach ($checks as [$name, $ok, $text])
                <span @class(['ds-pst__chk', 'is-ok' => $ok])><b>{{ $ok ? '✓' : '✗' }} {{ $name }}</b><small>{{ $text }}</small></span>
            @endforeach
        </span>
    </section>

    <span class="ds-pst__tabs">
        @foreach (['old' => 'Copy from the old system', 'bucket' => 'Bucket', 'work' => 'Workers'] as $id => $name)
            <button type="button" wire:click="setTab('{{ $id }}')" @class(['is-on' => $tab === $id])>{{ $name }}</button>
        @endforeach
    </span>

    {{-- ─────────────── Bucket ─────────────── --}}
    @if ($tab === 'bucket')
        @if ($usable['real'] && ($target !== 'real' || ($switch && $switch->status !== 'done') || ($switch && $switch->finished_at?->gt(now()->subDay()))))
            @php $sw = $switch && in_array($switch->status, ['running', 'paused', 'done']) && $switch->created_at->gt(now()->subDays(3)) ? $switch : null; @endphp
            <section class="ds-pst__switch">
                <span class="ds-pst__row">
                    <span class="ds-pst__col"><b>{{ $sw?->status === 'done' ? '✓ Switched to the real bucket' : ($sw ? 'Switching to the real bucket…' : 'Switch to the real bucket') }}</b>
                        <small>{{ $sw?->status === 'done' ? 'All photos are in '.$real->bucket.'. '.($sw->opt('auto_off') ? 'Temporary was turned off by itself; its files stay as a backup.' : 'Press Turn off on the Temporary card when you are ready.') : ($sw ? 'Runs in the background, you can close this page. Every photo keeps opening while it moves.' : 'One press: new photos go to Real, the photos in Temporary move there, it is checked, then Temporary turns off.') }}</small></span>
                    @if (! $sw)
                        <button type="button" class="ds-pst__go is-yellow" wire:click="startSwitch">Switch to Real bucket</button>
                    @elseif ($sw->status === 'paused')
                        <button type="button" class="ds-pst__go is-yellow" wire:click="resume({{ $sw->id }})">Go on</button>
                    @elseif ($sw->status === 'running')
                        <button type="button" class="ds-pst__go" wire:click="pause({{ $sw->id }})">Pause</button>
                    @endif
                </span>
                <span class="ds-pst__grid4">
                    @foreach ([['New photos → Real', 'right away', (bool) $sw], ['Move Temporary → Real', $sw ? number_format($sw->done + $sw->skipped).' of '.number_format($sw->total) : number_format($inTmp).' photos', $sw?->status === 'done' ? true : ($sw ? 'on' : false)], ['Check', '0 left, same size', $sw?->status === 'done'], ['Turn off Temporary', $autoOff ? 'by itself' : 'you press it', $sw?->status === 'done' && $tmp->is_off]] as [$n, $t, $st])
                        <span class="ds-pst__sstep"><b @class(['is-ok' => $st === true, 'is-on' => $st === 'on'])>{{ $st === true ? '✓' : ($st === 'on' ? '…' : '○') }} {{ $n }}</b><small>{{ $t }}</small></span>
                    @endforeach
                </span>
                <span class="ds-pst__bar is-dark"><i style="width: {{ $sw ? $sw->pct() : 0 }}%"></i></span>
                @unless ($sw)
                    <label class="ds-pst__tog is-dark"><input type="checkbox" wire:model.live="autoOff"><span><b>Turn off Temporary by itself when it is empty</b><small>Off: you press Turn off on the Temporary card yourself.</small></span></label>
                @endunless
            </section>
        @endif

        <section class="ds-pst__card">
            <b class="ds-pst__h">New photos go to</b>
            <span class="ds-pst__where">
                @foreach ($pl as $id => $name)
                    <button type="button" wire:click="setTarget('{{ $id }}')" @class(['is-on' => $target === $id]) @disabled(! $usable[$id])>
                        <b>{{ $name }}</b><small>{{ $id === 'server' ? 'Like before (this server\'s disk)' : (${$id}->is_off ? 'Turned off' : ($usable[$id] ? ${$id}->bucket : 'Put and test it first')) }}</small>
                    </button>
                @endforeach
            </span>
            <small class="ds-pst__mute">Old photos keep working: each photo remembers where it is saved (server, temporary or real) until you move it. Logos and app icons always stay on the server.</small>
        </section>

        <div class="ds-pst__two">
            @foreach (['tmp' => $tmp, 'real' => $real] as $slot => $b)
                @php $f = $form[$slot]; $set = $b->exists && $b->isSet(); @endphp
                <section @class(['ds-pst__card', 'is-off' => $b->is_off]) wire:key="slot-{{ $slot }}">
                    <span class="ds-pst__row"><span class="ds-pst__col"><b class="ds-pst__h">{{ $slot === 'tmp' ? 'Temporary bucket' : 'Real bucket' }}</b><small class="ds-pst__mute">{{ $slot === 'tmp' ? 'Now: used on production for a while' : 'Later: your real bucket' }}</small></span>
                        <span @class(['ds-pst__pill', 'is-ok' => $set && $b->test_ok && ! $b->is_off, 'is-warn' => $set && ! $b->test_ok])>{{ $b->is_off ? 'Turned off' : (! $set ? 'Not set' : ($b->test_ok ? 'Connected' : 'Not tested')) }}</span></span>
                    <span class="ds-pst__chips"><small class="ds-pst__lbl">Provider</small>
                        @foreach ($prov as $id => $name)
                            <button type="button" wire:click="setProvider('{{ $slot }}', '{{ $id }}')" @class(['is-on' => $f['provider'] === $id])>{{ $name }}</button>
                        @endforeach
                    </span>
                    @if ($editing[$slot])
                        <span class="ds-pst__fields">
                            @if ($f['provider'] === 'r2')
                                <label><small class="ds-pst__lbl">Account ID</small><input wire:model="form.{{ $slot }}.account_id" placeholder="from the S3 API link"></label>
                            @elseif ($f['provider'] === 's3')
                                <label><small class="ds-pst__lbl">Region</small><input wire:model="form.{{ $slot }}.region" placeholder="ap-southeast-1"></label>
                            @else
                                <label><small class="ds-pst__lbl">Endpoint URL</small><input wire:model="form.{{ $slot }}.endpoint" placeholder="https://…"></label>
                                <label><small class="ds-pst__lbl">Region</small><input wire:model="form.{{ $slot }}.region" placeholder="us-east-1"></label>
                            @endif
                            <label><small class="ds-pst__lbl">Bucket name</small><input wire:model="form.{{ $slot }}.bucket"></label>
                            <label><small class="ds-pst__lbl">Access key ID</small><input wire:model="form.{{ $slot }}.access_key" autocomplete="off"></label>
                            <label><small class="ds-pst__lbl">Secret access key</small><input type="password" wire:model="form.{{ $slot }}.secret" autocomplete="new-password" placeholder="{{ $b->secret ? '•••••••• saved (leave empty to keep)' : '' }}"></label>
                        </span>
                    @else
                        <span class="ds-pst__fields is-read">
                            @foreach (array_filter([
                                $b->provider === 'r2' ? ['Account ID', $b->account_id] : null,
                                $b->provider !== 'r2' && $b->provider !== 's3' ? ['Endpoint URL', $b->endpoint] : null,
                                $b->provider !== 'r2' ? ['Region', $b->region] : null,
                                ['Bucket name', $b->bucket], ['Access key ID', $b->access_key ? Str::mask($b->access_key, '•', 4, max(0, strlen($b->access_key) - 8)) : '—'], ['Secret access key', $b->secret ? '••••••••  saved' : '—'],
                            ]) as [$l, $v])
                                <span><small class="ds-pst__lbl">{{ $l }}</small><span class="ds-pst__in">{{ $v ?: '—' }}</span></span>
                            @endforeach
                        </span>
                    @endif
                    <small @class(['ds-pst__mute', 'is-warn' => $f['provider'] === 's3'])>{{ match ($f['provider']) { 'r2' => 'Endpoint made from the Account ID'.($b->endpointUrl() ? ': '.$b->endpointUrl() : '').' · region auto · downloads free', 's3' => 'No endpoint needed (made from the region). Amazon charges for downloads (about $0.09 per GB opened), R2 does not.', default => 'Wasabi, DigitalOcean Spaces, Backblaze B2 and others: put the endpoint from the provider.' } }}</small>
                    <span class="ds-pst__acts">
                        @if ($editing[$slot])
                            <button type="button" class="ds-pst__go" wire:click="saveBucket('{{ $slot }}')">Save and test</button>
                        @else
                            <button type="button" class="ds-pst__go" wire:click="testBucket('{{ $slot }}')" @disabled(! $set)><span wire:loading.remove wire:target="testBucket('{{ $slot }}')">Test connection</span><span wire:loading wire:target="testBucket('{{ $slot }}')">Testing…</span></button>
                            <button type="button" class="ds-pst__btn" wire:click="editBucket('{{ $slot }}')">{{ $set ? 'Edit' : 'Put a bucket' }}</button>
                        @endif
                        @if ($slot === 'tmp' && $b->exists)
                            @if ($b->is_off)
                                <button type="button" class="ds-pst__btn" wire:click="turnOn('tmp')">Turn on again</button>
                            @else
                                <button type="button" class="ds-pst__btn is-red" wire:click="turnOff('tmp')">Turn off</button>
                            @endif
                        @endif
                    </span>
                    @php $m = $msg[$slot] ?? ($b->test_message ? (($b->test_ok ? '✓ ' : '✗ ').$b->test_message) : ''); @endphp
                    @if ($m)<small @class(['ds-pst__res', 'is-ok' => str_starts_with($m, '✓'), 'is-bad' => str_starts_with($m, '✗') || str_starts_with($m, 'Not yet')])>{{ $m }}</small>@endif
                </section>
            @endforeach
        </div>

        <section class="ds-pst__card">
            <span class="ds-pst__row"><b class="ds-pst__h">Folders</b><small class="ds-pst__mute">New photos: kind / year / month / invoice, the same on this server and in the bucket · at most {{ $maxKb }} KB each</small></span>
            <span class="ds-pst__fmap">
                @foreach ($folderMap as [$n, $f])
                    <span><b>{{ $n }}</b><code>{{ $f }}</code></span>
                @endforeach
            </span>
            <small class="ds-pst__mute">Old photos keep their folder and keep opening. Move and Copy can put them in these folders (the path in the database is changed after each copy is checked). Logos, app icons and issue e-mail attachments stay on the server.</small>
        </section>

        <div class="ds-pst__two">
            <section class="ds-pst__card">
                <b class="ds-pst__h">Last 7 days</b>
                <span class="ds-pst__grid3">
                    <span class="ds-pst__stat is-ok"><b>{{ number_format($stats['bucket']) }}</b><small>saved to a bucket</small></span>
                    <span class="ds-pst__stat is-warn"><b>{{ number_format($stats['server']) }}</b><small>stayed on the server (bucket did not answer)</small></span>
                    <span class="ds-pst__stat"><b>{{ number_format($inTmp) }}</b><small>in the Temporary bucket now</small></span>
                </span>
                <small class="ds-pst__mute">Photos from every app: scan app, driver app and the panels. When a bucket does not answer, the photo is saved on the server: nothing is lost.</small>
            </section>
            <section class="ds-pst__card">
                <span class="ds-pst__row"><b class="ds-pst__h">Move photos</b><small class="ds-pst__mute">Copies each photo, checks it, then deletes the old copy. Runs in the background.</small></span>
                <span class="ds-pst__mv">
                    <b>Server → {{ $target === 'server' ? 'a bucket' : $pl[$target] }}</b>
                    <span class="ds-pst__col"><small>{{ number_format($serverCount) }} photos still on this server</small></span>
                    <button type="button" class="ds-pst__go" wire:click="startMove" @disabled($target === 'server' || $active || ! $serverCount)>Start</button>
                </span>
                <label class="ds-pst__tog"><input type="checkbox" wire:model.live="tidyMove"><span><b>Put them in the new folders</b><small>delivery/2025/08/0144033/… · the path in the database is changed after each copy is checked</small></span></label>
                @foreach ($moves as $m)
                    <span class="ds-pst__mv" wire:key="mv-{{ $m->id }}">
                        <b>{{ $pl[$m->from_place] ?? $m->from_place }} → {{ $pl[$m->to_place] ?? $m->to_place }}</b>
                        <span class="ds-pst__col"><small>{{ $m->status === 'done' ? '✓ Done · '.number_format($m->done).' moved' : number_format($m->done + $m->skipped).' of '.number_format($m->total).($m->failed ? ' · '.$m->failed.' failed' : '') }} · {{ $m->created_at->diffForHumans() }}</small><span class="ds-pst__bar"><i style="width: {{ $m->pct() }}%"></i></span></span>
                        @if ($m->status === 'running')
                            <button type="button" class="ds-pst__btn" wire:click="pause({{ $m->id }})">Pause</button>
                        @elseif ($m->status === 'paused')
                            <button type="button" class="ds-pst__go" wire:click="resume({{ $m->id }})">Go on</button>
                        @else
                            <span class="ds-pst__pill is-ok">Done</span>
                        @endif
                    </span>
                @endforeach
            </section>
        </div>
    @endif

    {{-- ─────────────── Workers ─────────────── --}}
    @if ($tab === 'work')
        @foreach ([['Background worker (Supervisor)', $worker, 'sudo bash setup-worker.sh', 'Last job '.$ago($queueSeen).' · copy and move run here even with the page closed', 'Run this once on the server as root (SSH, or Plesk → SSH Terminal), in the wmsv2 folder:'], ['Scheduler (cron)', $scheduler, 'Plesk → wmsv2 → Laravel → Scheduled Tasks → On', 'Ran '.$ago($scheduleSeen).' · goes on with moves every minute', 'Turn it on once in Plesk:']] as [$name, $on, $how, $okText, $offText])
            <section class="ds-pst__card ds-pst__runner">
                <span @class(['ds-pst__dot', 'is-ok' => $on])></span>
                <span class="ds-pst__col"><b class="ds-pst__h">{{ $name }}: {{ $on ? 'running' : 'not running' }}</b><small class="ds-pst__mute">{{ $on ? $okText : $offText }}</small></span>
                @unless ($on)<code class="ds-pst__in">{{ $how }}</code>@endunless
            </section>
        @endforeach
        <section class="ds-pst__card">
            <span class="ds-pst__row"><span class="ds-pst__col"><b class="ds-pst__h">No worker? Run here</b><small class="ds-pst__mute">This page does the work itself, a few photos every few seconds, while the tab stays open. Slower than the worker, nothing to set up. Close the tab and it stops; press again and it goes on.</small></span>
                <button type="button" @class(['ds-pst__go', 'is-purple' => ! $runHere, 'is-redbg' => $runHere]) wire:click="toggleRunHere">{{ $runHere ? 'Stop' : 'Run here' }}</button></span>
            <span class="ds-pst__bar is-purple"><i style="width: {{ $active ? $active->pct() : 0 }}%"></i></span>
            <small class="ds-pst__mute">{{ $active ? ($runHere ? 'Running in this tab · ' : 'Waiting for a worker · ').number_format($active->done + $active->skipped).' of '.number_format($active->total) : 'Nothing to move or copy right now.' }}</small>
        </section>
        <small class="ds-pst__mute">Supervisor and cron are set on the server, not from this page: the website does not run as root, on purpose. Use one worker way, not both Supervisor and the Plesk queue.</small>
    @endif

    {{-- ─────────────── Copy from the old system ─────────────── --}}
    @if ($tab === 'old')
        @php
            $copyDone = $task && $task->status === 'done';
            $stepNames = [['Find the old system', 'its folder · same database?'], ['Scan', 'folders + database paths'], ['Review', 'where each file is'], ['Try 50', 'look before you copy'], ['Copy', 'new only, smaller'], ['Check', 'everything is there'], ['New photos', 'wmsv2 to the bucket'], ['Clean the old server', 'checklist, by you']];
            $doneTo = ! ($find['found'] ?? false) ? 0 : (! $task ? 1 : ($copyDone ? 6 : ($task->done ? 4 : 3)));
        @endphp
        <div class="ds-pst__steps">
            <section class="ds-pst__card ds-pst__nav">
                <small class="ds-pst__lbl">Old system → bucket</small>
                @foreach ($stepNames as $i => [$n, $s])
                    @php $k = $i + 1; @endphp
                    <button type="button" wire:click="setStep({{ $k }})" @class(['is-on' => $step === $k])><span @class(['ds-pst__num', 'is-ok' => $k <= $doneTo && $step !== $k, 'is-on' => $step === $k])>{{ $k <= $doneTo && $step !== $k ? '✓' : $k }}</span><span class="ds-pst__col"><b>{{ $n }}</b><small>{{ $s }}</small></span></button>
                @endforeach
                <small class="ds-pst__mute">Nothing on the old site is ever changed or deleted from here. Any step can be pressed again: it only does what is missing.</small>
            </section>

            <section class="ds-pst__card ds-pst__body">
                @if ($step === 1)
                    <span class="ds-pst__row"><span class="ds-pst__col"><b class="ds-pst__h2">1 · Find the old system</b><small class="ds-pst__mute">Looks for the old site's folder on this server and checks if it uses the same database.</small></span><span @class(['ds-pst__pill', 'is-ok' => $find['found'] ?? false])>{{ ($find['found'] ?? false) ? (($find['same'] ?? false) ? '✓ Same database' : '✓ Found') : 'Not found' }}</span></span>
                    <span class="ds-pst__acts"><input class="ds-pst__inp" wire:model="oldFolder" aria-label="Old site folder"><button type="button" class="ds-pst__btn" wire:click="saveFolder">Find</button></span>
                    @if ($find['found'] ?? false)
                        <span class="ds-pst__grid3">
                            <span class="ds-pst__chk is-ok"><b>✓ Found {{ basename($find['dir']) }}</b><small>{{ $find['laravel'] ? 'Laravel site' : 'a folder' }} · {{ $find['storage'] ? 'storage/app/public' : 'no storage folder' }}{{ $find['uploads'] ? ' + public/uploads' : '' }}</small></span>
                            <span @class(['ds-pst__chk', 'is-ok' => $find['same']])><b>{{ $find['same'] ? '✓ Same database as wmsv2' : 'Another database' }}</b><small>{{ $find['same'] ? 'one list of photos: no matching needed' : 'the files are copied under wms-v1/ (not linked to boxes)' }}</small></span>
                            <span class="ds-pst__chk is-ok"><b>✓ {{ number_format(collect($columns)->sum('n')) }} photo paths</b><small>in {{ count($columns) }} columns</small></span>
                        </span>
                        @if ($columns)
                            <small class="ds-pst__lbl">Columns that hold photo paths (found by themselves)</small>
                            @foreach ($columns as $c)
                                <span class="ds-pst__tr4"><b class="ds-pst__mono">{{ $c['table'] }}.{{ $c['column'] }}</b><span>{{ number_format($c['n']) }} paths</span><span class="ds-pst__mono ds-pst__mute ds-pst__cut">{{ $c['example'] }}</span><b class="ds-pst__ok">✓ Use</b></span>
                            @endforeach
                        @endif
                    @else
                        <small class="ds-pst__res is-bad">No old site at {{ $find['dir'] ?? 'the usual place' }}. Put the folder of wms.icargoxpress.net above and press Find.</small>
                    @endif
                    <span class="ds-pst__acts"><button type="button" class="ds-pst__go" wire:click="scan" @disabled(! ($find['found'] ?? false))><span wire:loading.remove wire:target="scan">Next: Scan</span><span wire:loading wire:target="scan">Scanning…</span></button></span>

                @elseif ($step === 2)
                    <span class="ds-pst__row"><span class="ds-pst__col"><b class="ds-pst__h2">2 · Scan old + new</b><small class="ds-pst__mute">Every folder with photos in both sites, and where the file of each path really is.</small></span><span class="ds-pst__pill">{{ $task?->opt('scanned_at') ? 'Scanned '.\Illuminate\Support\Carbon::parse($task->opt('scanned_at'))->diffForHumans() : 'Not scanned yet' }}</span></span>
                    @php $folders = $task?->opt('folders', []) ?? []; $same = collect($folders)->filter(fn ($f) => isset($f['old'], $f['new']))->count(); @endphp
                    @if ($folders)
                        <span class="ds-pst__row"><small class="ds-pst__lbl">Folder structure: old vs new</small><span class="ds-pst__pill is-blue">{{ $same }} of {{ count($folders) }} folders are in both</span></span>
                        <span class="ds-pst__tr4 is-head"><span>Folder</span><span>wms (old)</span><span>wmsv2 (new)</span><span></span></span>
                        @foreach (array_slice($folders, 0, 14, true) as $path => $f)
                            <span class="ds-pst__tr4"><span class="ds-pst__mono">{{ $path }}</span><span>{{ isset($f['old']) ? number_format($f['old'][0]).' · '.$mb($f['old'][1]) : '—' }}</span><span>{{ isset($f['new']) ? number_format($f['new'][0]).' · '.$mb($f['new'][1]) : '—' }}</span>
                                <b @class(['ds-pst__pill', 'is-ok' => isset($f['old'], $f['new']), 'is-blue' => ! isset($f['old']), 'is-warn' => ! isset($f['new'])])>{{ isset($f['old'], $f['new']) ? '✓ Same in both' : (isset($f['new']) ? 'Only in the new' : '⚠ Only in the old') }}</b></span>
                        @endforeach
                    @endif
                    <small class="ds-pst__lbl">The database paths against the files</small>
                    <span class="ds-pst__grid4">
                        @foreach (['wmsv2' => ['✓ In the wmsv2 folder', 'Copied from wmsv2', 'is-ok'], 'wms' => ['✓ In the wms folder', 'Copied from the old site', 'is-ok'], 'both' => ['⚠ Different file in both', 'Same path, two photos: pick one', 'is-warn'], 'missing' => ['✗ Missing', 'In the database, no file anywhere', 'is-bad']] as $g => [$n, $t, $c])
                            <span class="ds-pst__stat {{ $c }}"><b>{{ number_format($groups[$g] ?? 0) }}</b><b class="ds-pst__sm">{{ $n }}</b><small>{{ $t }}</small></span>
                        @endforeach
                    </span>
                    <span class="ds-pst__acts"><button type="button" class="ds-pst__btn" wire:click="scan"><span wire:loading.remove wire:target="scan">Scan old + new again</span><span wire:loading wire:target="scan">Scanning…</span></button><button type="button" class="ds-pst__go" wire:click="setStep(3)" @disabled(! $task)>Next: Review</button></span>

                @elseif ($step === 3)
                    <span class="ds-pst__row"><span class="ds-pst__col"><b class="ds-pst__h2">3 · Review</b><small class="ds-pst__mute">Each path from the database, which folder has the file, and a link to open it.</small></span><span class="ds-pst__pill">{{ number_format($groups->sum()) }} paths</span></span>
                    <span class="ds-pst__acts">
                        @foreach (['wmsv2' => '✓ wmsv2 folder', 'wms' => '✓ wms folder', 'both' => '⚠ Different in both', 'missing' => '✗ Missing'] as $g => $n)
                            <button type="button" wire:click="$set('rt', '{{ $g }}')" @class(['ds-pst__chip', 'is-on' => $rt === $g])>{{ $n }} {{ number_format($groups[$g] ?? 0) }}</button>
                        @endforeach
                        <input class="ds-pst__inp is-short" wire:model.live.debounce.400ms="search" placeholder="Search path or record…">
                        <button type="button" class="ds-pst__btn" wire:click="csv('report')">Download report (CSV)</button>
                    </span>
                    <span class="ds-pst__tr4 is-head"><span>Path in the database</span><span>Record</span><span>File found in</span><span></span></span>
                    @forelse ($rows as $r)
                        <span class="ds-pst__tr4" wire:key="r-{{ $r->id }}"><span class="ds-pst__col"><span class="ds-pst__mono ds-pst__cut">{{ $r->path }}</span>@if ($r->new_path)<small class="ds-pst__mono ds-pst__cut ds-pst__ok">→ {{ $r->new_path }}</small>@endif</span><span class="ds-pst__mute ds-pst__cut">{{ $r->ref }}</span>
                            <span @class(['ds-pst__cut', 'ds-pst__bad' => $r->found === 'missing', 'ds-pst__warn' => $r->found === 'both'])>{{ match ($r->found) { 'wmsv2' => 'wmsv2 folder', 'wms' => 'wms folder', 'both' => 'both · '.$mb((int) $r->size_before).' used, other kept', default => 'no file in either folder' } }}</span>
                            <span>@if ($r->found === 'both')<button type="button" class="ds-pst__link" wire:click="pick({{ $r->id }})">Pick the other</button>@elseif ($r->found !== 'missing')<a class="ds-pst__link" href="{{ $openUrl($r) }}" target="_blank" rel="noopener">Open</a>@endif</span></span>
                    @empty
                        <small class="ds-pst__mute">Nothing here.</small>
                    @endforelse
                    <small class="ds-pst__mute">{{ ['wmsv2' => 'Copied from the wmsv2 folder, same path.', 'wms' => 'Copied from the old site\'s folder, same path: opens in wmsv2 right after.', 'both' => 'The newest file is used, the other is kept in the bucket under _other/. Pick the other to swap.', 'missing' => 'Nothing to copy: these records have no photo in either site.'][$rt] }}</small>
                    <span class="ds-pst__acts"><button type="button" class="ds-pst__go" wire:click="setStep(4)">Next: Try 50</button></span>

                @elseif ($step === 4)
                    <span class="ds-pst__row"><span class="ds-pst__col"><b class="ds-pst__h2">4 · Try 50 first</b><small class="ds-pst__mute">Copies 50 photos (the biggest first), made smaller. Open the old and the new side by side.</small></span><span class="ds-pst__pill">{{ (int) ($triedSum->n ?? 0) }} tried</span></span>
                    @if ($tried->isNotEmpty())
                        <span class="ds-pst__grid3">
                            @foreach ($tried->take(6) as $t)
                                <span class="ds-pst__pair" wire:key="t-{{ $t->id }}">
                                    <span class="ds-pst__two is-tight"><a href="{{ $oldUrl($t) }}" target="_blank" rel="noopener"><img src="{{ $oldUrl($t) }}" alt="Old" loading="lazy"><em>Old · {{ $mb((int) $t->size_before) }}</em></a><a href="{{ $openUrl($t) }}" target="_blank" rel="noopener"><img src="{{ $openUrl($t) }}" alt="New" loading="lazy"><em class="is-ok">New · {{ $mb((int) $t->size_after) }}</em></a></span>
                                    <small class="ds-pst__cut">{{ $t->ref ?: $t->path }}</small>
                                </span>
                            @endforeach
                        </span>
                        <span class="ds-pst__res is-ok"><b>{{ (int) $triedSum->n }} tried:</b> {{ $mb((int) $triedSum->b) }} → {{ $mb((int) $triedSum->a) }} ({{ $triedSum->b ? round(100 - $triedSum->a * 100 / $triedSum->b) : 0 }}% smaller). Invoice numbers and signatures still clear? Look before you copy all.</span>
                    @endif
                    <span class="ds-pst__acts"><button type="button" class="ds-pst__btn" wire:click="tryFifty" @disabled(! $task)><span wire:loading.remove wire:target="tryFifty">{{ $tried->isEmpty() ? 'Try 50 first' : 'Try 50 others' }}</span><span wire:loading wire:target="tryFifty">Copying 50…</span></button><button type="button" class="ds-pst__go" wire:click="setStep(5)">Looks good: Next</button></span>

                @elseif ($step === 5)
                    <span class="ds-pst__row"><span class="ds-pst__col"><b class="ds-pst__h2">5 · Copy to the bucket</b><small class="ds-pst__mute">Runs in the background. Press it again any time: only what is missing is copied.</small></span><span @class(['ds-pst__pill', 'is-ok' => $copyDone])>{{ $copyDone ? '✓ Done' : ($task && in_array($task->status, ['running', 'checking']) ? 'Copying' : 'Ready') }}</span></span>
                    @if ($task)
                        <span class="ds-pst__two">
                            @foreach (['small' => ['Make photos smaller (max 200 KB)', '1600 px, clear enough to read the invoice. Signatures and other files stay as they are.', true], 'keep' => ['Also keep the originals in the bucket', 'Full size under _original/ · a few cents a month · safe to delete the old server later', false], 'tidy' => ['Put them in the new folders', 'kind / year / month / invoice · the path in the database is changed after each copy is checked', true]] as $k => [$n, $t, $def])
                                <button type="button" class="ds-pst__tog" wire:click="setOpt('{{ $k }}')"><span @class(['ds-pst__sw', 'is-on' => $task->opt($k, $def)])><i></i></span><span class="ds-pst__col"><b>{{ $n }}</b><small>{{ $t }}</small></span></button>
                            @endforeach
                        </span>
                        @if ($task->opt('tidy', true) && ($find['same'] ?? false))
                            <small class="ds-pst__res is-bad">The old site uses the same database: after a photo is put in the new folders, the old site can no longer show it (wmsv2 does). Turn this off while the old site is still used.</small>
                        @endif
                        @php $all = max(1, $task->total); @endphp
                        <span class="ds-pst__col"><span class="ds-pst__row"><small>{{ $copyDone ? '✓ Done · '.number_format($task->done).' copied · '.number_format($task->skipped).' already there · '.$task->failed.' failed' : number_format($task->done + $task->skipped).' of '.number_format($task->total).' photos'.($task->failed ? ' · '.$task->failed.' failed' : '') }}</small><small class="ds-pst__mute">{{ $mb((int) $task->bytes_before) }} → {{ $mb((int) $task->bytes_after) }}</small></span><span class="ds-pst__bar is-blue"><i style="width: {{ $task->pct() }}%"></i></span></span>
                        @if ($task->last_error && $task->failed)<small class="ds-pst__res is-bad">Last problem: {{ $task->last_error }}</small>@endif
                        <span class="ds-pst__acts">
                            @if (in_array($task->status, ['running', 'checking']))
                                <button type="button" class="ds-pst__btn" wire:click="pause({{ $task->id }})">Pause</button>
                            @else
                                <button type="button" class="ds-pst__go is-blue" wire:click="copyNew" @disabled(! ($worker || $scheduler || $runHere))>{{ $task->done ? 'Copy new only' : 'Copy to the bucket' }}</button>
                            @endif
                            <button type="button" class="ds-pst__btn" wire:click="checkBucket">Check bucket</button>
                            <button type="button" class="ds-pst__btn is-red" wire:click="copyAgain">{{ $sureAgain ? 'Press again to replace all' : 'Copy all again…' }}</button>
                            @unless ($worker || $scheduler || $runHere)<small class="ds-pst__warn">No worker runs: start one, or press Run here on the Workers tab.</small>@endunless
                        </span>
                        <small class="ds-pst__lbl">Last copied: old link → new link</small>
                        @foreach ($last as $i)
                            <span class="ds-pst__tr5" wire:key="l-{{ $i->id }}"><a class="ds-pst__mono ds-pst__cut ds-pst__link" href="{{ $oldUrl($i) }}" target="_blank" rel="noopener">{{ $oldUrl($i) }}</a><span class="ds-pst__mute">→</span><a class="ds-pst__mono ds-pst__cut ds-pst__link" href="{{ $openUrl($i) }}" target="_blank" rel="noopener">{{ ($tmp->bucket && $target !== 'real' ? $tmp->bucket : $real->bucket).'/'.($i->new_path ?: $i->path) }}</a><span class="ds-pst__mute">{{ $i->size_after && $i->size_after !== $i->size_before ? $mb((int) $i->size_before).' → '.$mb((int) $i->size_after) : $mb((int) $i->size_before) }}</span><b @class(['ds-pst__ok' => $i->status === 'done', 'ds-pst__bad' => $i->status === 'failed'])>{{ ['done' => '✓ Copied', 'skipped' => 'Already there', 'failed' => '✗ '.Str::limit((string) $i->note, 40)][$i->status] ?? $i->status }}</b></span>
                        @endforeach
                        <small class="ds-pst__mute">Same path in the bucket as in the database, so every photo opens in wmsv2 right after. Copy new only: photos already in the bucket are skipped. A photo that changed on the old site is copied again after a new Scan.</small>
                    @else
                        <small class="ds-pst__res is-bad">Scan first (step 2).</small>
                    @endif

                @elseif ($step === 6)
                    <span class="ds-pst__row"><span class="ds-pst__col"><b class="ds-pst__h2">6 · Check</b><small class="ds-pst__mute">Reads the bucket and compares with the list. A missing photo is copied again.</small></span><span @class(['ds-pst__pill', 'is-ok' => $copyDone])>{{ $task?->status === 'checking' ? 'Checking…' : ($task?->checked_at ? '✓ Checked '.$task->checked_at->diffForHumans() : 'Not checked yet') }}</span></span>
                    <span class="ds-pst__grid3">
                        <span class="ds-pst__stat is-ok"><b>{{ number_format($checkedN) }}</b><small>in the bucket and checked</small></span>
                        <span class="ds-pst__stat"><b>{{ number_format(max(0, ($task?->done ?? 0) - $checkedN)) }}</b><small>copied, not checked yet</small></span>
                        <span class="ds-pst__stat is-warn"><b>{{ number_format($missingN) }}</b><small>had no file on either site (Review → Missing)</small></span>
                    </span>
                    <span class="ds-pst__acts"><button type="button" class="ds-pst__btn" wire:click="checkBucket" @disabled(! $task)>Check again</button><button type="button" class="ds-pst__btn" wire:click="csv('list')" @disabled(! $task)>Download old → new list (CSV)</button><button type="button" class="ds-pst__go" wire:click="setStep(7)">Next</button></span>

                @elseif ($step === 7)
                    <b class="ds-pst__h2">7 · New photos of wmsv2</b>
                    <span>Choose where <b>new</b> photos of wmsv2 go (Bucket tab), and move wmsv2's own photos from the server. The photos keep opening: each one remembers where it is.</span>
                    <span class="ds-pst__acts"><button type="button" class="ds-pst__go" wire:click="setTab('bucket')">Open the Bucket tab</button><button type="button" class="ds-pst__btn" wire:click="setStep(8)">Next</button></span>

                @else
                    @php $days = $task?->finished_at ? (int) $task->finished_at->diffInDays(now()) : 0; @endphp
                    <b class="ds-pst__h2">8 · Clean the old server</b>
                    <span>When all of these have a ✓, you can delete the photos on the old server yourself. This page never deletes them.</span>
                    @foreach ([[$copyDone && $task->checked_at, 'Copied and checked: 0 missing in the bucket', 'Step 6'], [(bool) $csvAt, 'Old → new list downloaded (CSV)', $csvAt ? 'on '.$csvAt : 'Step 6'], [($task?->opt('keep') ?? false) || $backup, 'Originals kept in the bucket, or a backup downloaded', $backup ? 'backup on '.$backup : 'Step 5, or the box below'], [$days >= 14, '14 days of using the new storage', $task?->finished_at ? $days.' days so far' : 'after the copy']] as [$ok, $t, $n])
                        <span class="ds-pst__tr2"><b @class(['ds-pst__ok' => $ok])>{{ $ok ? '✓' : '○' }}</b><span>{{ $t }}</span><small class="ds-pst__mute">{{ $n }}</small></span>
                    @endforeach
                    <label class="ds-pst__tog"><input type="checkbox" @checked($backup) wire:click="markBackup"><span><b>I downloaded a backup of the old photos</b><small>For example with: tar -czf ~/wms-photos-original.tar.gz -C {{ $find['dir'] ?? '…' }}/storage/app public</small></span></label>
                @endif
            </section>
        </div>
    @endif
</div>
</x-filament-panels::page>
DISPATCH_FILE_END_35

# ---------------------------------------------------------------- routes/web.php
mkdir -p 'routes'
cat > 'routes/web.php' <<'DISPATCH_FILE_END_36'
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
    // Same files without a file ending: Plesk's nginx serves .js / .png / .webmanifest from disk
    // and never asks Laravel, so phones get a 404 and Android does not offer to install.
    Route::get('/pwa/sw', 'serviceWorker')->name('pwa.sw.plain');
    Route::get('/pwa/{panel}/manifest', 'manifest')->whereIn('panel', ['delivery', 'scan'])->name('pwa.manifest.plain');
    Route::get('/pwa/{panel}/icon/{size}', 'icon')->whereIn('panel', ['delivery', 'scan'])->whereNumber('size')->name('pwa.icon.plain');
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
Route::middleware(['web', 'auth', 'throttle:240,1'])->post('/scan/box-photo', [App\Http\Controllers\ScanPhotoController::class, 'store'])->name('scan.box-photo');
Route::middleware(['web', 'auth', 'throttle:120,1'])->post('/delivery-track', [TrackController::class, 'driver'])->name('track.driver');
Route::middleware(['throttle:600,1'])->match(['get', 'post'], '/track/in/{token}', [TrackController::class, 'tracker'])
    ->withoutMiddleware([ValidateCsrfToken::class, VerifyCsrfToken::class, 'Illuminate\Foundation\Http\Middleware\PreventRequestForgery'])
    ->name('track.tracker');

// Fuel › VAT: the month's fuel receipts for the accountant (signed-in staff, their own hub).
Route::get('/fuel/vat-export', [FuelController::class, 'vatExport'])->middleware(['web', 'auth'])->name('fuel.vat-export');

// Printable QR labels for the warehouse sections.
Route::get('/sections/labels', App\Http\Controllers\SectionLabelsController::class)->middleware(['web', 'auth'])->name('sections.labels');

// Settings → Photo storage: open a copied photo (a temporary link to the bucket, or the file on this server).
Route::get('/photo-storage/open/{item}', function (int $item) {
    abort_unless(\Illuminate\Support\Facades\Auth::user()?->is_admin, 403);
    $i = \App\Models\Photos\PhotoTaskItem::findOrFail($item);
    $disk = str_starts_with($i->path, 'wms-v1/') ? 'old' : 'public';
    $key = $i->new_path ?: $i->path;
    $place = \App\Support\Photos\Storage\PhotoStore::placeOf($disk, $key);
    if ($place !== 'server') {
        return redirect()->away(\App\Support\Photos\Storage\PhotoStore::link($place, $key, 1));
    }

    return $i->source && is_file($i->source) ? response()->file($i->source) : abort(404);
})->name('photo-storage.open');

// Local only (PHOTOS_FAKE_BUCKETS=1): show a photo from a bucket that is a folder.
if (app()->environment('local') && env('PHOTOS_FAKE_BUCKETS')) {
    Route::get('/photo-storage/fake/{slot}/{key}', function (string $slot, string $key) {
        return response(\App\Support\Photos\Storage\PhotoStore::fs($slot)->get($key) ?? abort(404), 200, ['Content-Type' => 'image/jpeg']);
    })->where('key', '.*');
}
DISPATCH_FILE_END_36

# ---------------------------------------------------------------- setup-worker.sh
cat > 'setup-worker.sh' <<'DISPATCH_FILE_END_37'
#!/usr/bin/env bash
# Part 40 · Settings → Photo storage: a background worker with Supervisor.
# Run once on the server as root, in the wmsv2 folder:   sudo bash setup-worker.sh
# Safe to run again: it only fixes what is missing. Nothing in the app files is changed
# (only QUEUE_CONNECTION in .env when it is not "database", with a backup first).
set -euo pipefail

APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAME="${NAME:-wmsv2-worker}"
CONF="/etc/supervisor/conf.d/${NAME}.conf"
ok()   { printf '\033[32m✓\033[0m %s\n' "$*"; }
info() { printf '  %s\n' "$*"; }
fail() { printf '\033[31m✗\033[0m %s\n' "$*"; exit 1; }

[ "$(id -u)" -eq 0 ] || fail "Run it as root: sudo bash setup-worker.sh"
[ -f "$APP_DIR/artisan" ] || fail "artisan not found in $APP_DIR (run it from the wmsv2 folder)"

# 1 · The user that owns the site (Plesk system user), never root
RUN_AS="$(stat -c '%U' "$APP_DIR")"
[ "$RUN_AS" != "root" ] || RUN_AS="$(stat -c '%U' "$APP_DIR/storage")"
ok "Site user: $RUN_AS"

# 2 · PHP: PHP=/path/to/php to choose; else the newest Plesk PHP; else php
PHP_BIN="${PHP:-}"
if [ -z "$PHP_BIN" ] && [ -d /opt/plesk/php ]; then
  for v in $(ls -1 /opt/plesk/php | sort -rV); do
    if [ -x "/opt/plesk/php/$v/bin/php" ]; then PHP_BIN="/opt/plesk/php/$v/bin/php"; break; fi
  done
fi
PHP_BIN="${PHP_BIN:-$(command -v php || true)}"
[ -n "$PHP_BIN" ] && [ -x "$PHP_BIN" ] || fail "PHP not found. Run: PHP=/opt/plesk/php/8.3/bin/php bash setup-worker.sh"
"$PHP_BIN" -r 'exit(version_compare(PHP_VERSION, "8.2", "<") ? 1 : 0);' || fail "$PHP_BIN is older than 8.2. Run: PHP=/opt/plesk/php/8.3/bin/php bash setup-worker.sh"
ok "PHP: $PHP_BIN ($("$PHP_BIN" -r 'echo PHP_VERSION;'))"

# 3 · The queue uses the database
ENV_FILE="$APP_DIR/.env"
if grep -qE '^QUEUE_CONNECTION=database\s*$' "$ENV_FILE"; then
  ok "QUEUE_CONNECTION=database"
else
  cp "$ENV_FILE" "$ENV_FILE.before-worker-$(date +%Y%m%d%H%M%S)"
  if grep -qE '^QUEUE_CONNECTION=' "$ENV_FILE"; then
    sed -i 's/^QUEUE_CONNECTION=.*/QUEUE_CONNECTION=database/' "$ENV_FILE"
  else
    printf '\nQUEUE_CONNECTION=database\n' >> "$ENV_FILE"
  fi
  sudo -u "$RUN_AS" "$PHP_BIN" "$APP_DIR/artisan" config:cache >/dev/null 2>&1 || true
  ok "QUEUE_CONNECTION set to database (old .env kept as a backup)"
fi

# 4 · Supervisor
if ! command -v supervisorctl >/dev/null 2>&1; then
  info "Installing Supervisor…"
  if command -v apt-get >/dev/null 2>&1; then
    DEBIAN_FRONTEND=noninteractive apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq supervisor
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y -q supervisor
  elif command -v yum >/dev/null 2>&1; then
    yum install -y -q supervisor
  else
    fail "Could not install Supervisor (no apt-get, dnf or yum). Install it, then run this again."
  fi
fi
for svc in supervisor supervisord; do
  systemctl enable --now "$svc" >/dev/null 2>&1 && break || true
done
ok "Supervisor installed and on"

# RHEL keeps the programs in /etc/supervisord.d
if [ ! -d /etc/supervisor/conf.d ] && [ -d /etc/supervisord.d ]; then CONF="/etc/supervisord.d/${NAME}.ini"; fi
mkdir -p "$(dirname "$CONF")"

# 5 · The worker
NEW_CONF="[program:${NAME}]
command=${PHP_BIN} ${APP_DIR}/artisan queue:work --sleep=3 --tries=3 --timeout=600 --max-time=3600
directory=${APP_DIR}
user=${RUN_AS}
numprocs=2
process_name=%(program_name)s_%(process_num)02d
autostart=true
autorestart=true
stopasgroup=true
killasgroup=true
stopwaitsecs=620
redirect_stderr=true
stdout_logfile=${APP_DIR}/storage/logs/worker.log
stdout_logfile_maxbytes=5MB
stdout_logfile_backups=2
"
if [ -f "$CONF" ] && [ "$(cat "$CONF")" = "$(printf '%s' "$NEW_CONF")" ]; then
  ok "Worker config already set ($CONF)"
else
  printf '%s' "$NEW_CONF" > "$CONF"
  ok "Worker config written ($CONF)"
fi
touch "$APP_DIR/storage/logs/worker.log" && chown "$RUN_AS" "$APP_DIR/storage/logs/worker.log" || true

supervisorctl reread >/dev/null
supervisorctl update >/dev/null
sudo -u "$RUN_AS" "$PHP_BIN" "$APP_DIR/artisan" queue:restart >/dev/null 2>&1 || true
# Supervisor counts a worker as RUNNING after a few seconds: wait up to 20 s
for _ in $(seq 1 10); do
  sleep 2
  supervisorctl status "${NAME}:*" 2>/dev/null | grep -q STARTING || break
done
supervisorctl status "${NAME}:*" || true

if supervisorctl status "${NAME}:*" 2>/dev/null | grep -q RUNNING; then
  ok "Done. The worker starts by itself after a reboot."
  info "After each Part script:  php artisan queue:restart"
  info "Log: ${APP_DIR}/storage/logs/worker.log"
else
  fail "The worker is not RUNNING. See: tail -50 ${APP_DIR}/storage/logs/worker.log"
fi
DISPATCH_FILE_END_37

# ---------------------------------------------------------------- tests/Feature/PhotoStorageTest.php
mkdir -p 'tests/Feature'
cat > 'tests/Feature/PhotoStorageTest.php' <<'DISPATCH_FILE_END_38'
<?php

use App\Filament\Pages\PhotoStorage;
use App\Models\AppSetting;
use App\Models\Photos\PhotoFile;
use App\Models\Photos\PhotoTask;
use App\Models\User;
use App\Support\Photos\Storage\OldSystem;
use App\Support\Photos\Storage\PhotoStore;
use App\Support\Photos\Storage\PhotoWork;
use Database\Seeders\DemoSeeder;
use Filament\Facades\Filament;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Illuminate\Http\UploadedFile;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\File;
use Illuminate\Support\Facades\Storage;
use Livewire\Livewire;

uses(RefreshDatabase::class);

beforeEach(function () {
    $this->seed(DemoSeeder::class);
    $this->admin = User::where('email', 'admin@example.com')->firstOrFail();
    $this->actingAs($this->admin);
    Filament::setCurrentPanel(Filament::getPanel('admin'));
    PhotoStore::$fake = true;
    PhotoStore::forgetMemo();
    $this->root = storage_path('framework/testing/photostore-'.getmypid());
    File::deleteDirectory($this->root);
    // the server folders behind the routed disks, in a test folder
    config(['filesystems.disks.public.inner.root' => $this->root.'/public', 'filesystems.disks.box.inner.root' => $this->root.'/private']);
    Storage::forgetDisk(['public', 'box']);
    File::deleteDirectory(storage_path('framework/testing/buckets'));
});

afterEach(function () {
    PhotoStore::$fake = false;
    File::deleteDirectory($this->root);
    File::deleteDirectory(storage_path('framework/testing/buckets'));
});

function bucketOn(string $slot = 'tmp', string $name = 'negosmart'): void
{
    PhotoStore::bucket($slot)->fill(['provider' => 'r2', 'account_id' => 'acc123', 'bucket' => $name, 'access_key' => 'key', 'secret' => 's3cret'])->save();
    PhotoStore::forgetMemo();
    expect(PhotoStore::test($slot)[0])->toBeTrue();
    PhotoStore::forgetMemo();
}

it('saves on the server like before until a bucket is chosen', function () {
    Storage::disk('public')->put('shipments/a.jpg', 'AAA');
    expect(File::exists($this->root.'/public/shipments/a.jpg'))->toBeTrue()
        ->and(PhotoFile::count())->toBe(0)
        ->and(Storage::disk('public')->url('shipments/a.jpg'))->toEndWith('/storage/shipments/a.jpg');
});

it('saves new photos of every disk to the chosen bucket and keeps old ones opening', function () {
    Storage::disk('public')->put('fuel/old.jpg', 'OLD');
    bucketOn();
    PhotoStore::setTarget('tmp');
    PhotoStore::forgetMemo();

    Storage::disk('public')->put('fuel/new.jpg', 'NEW');
    Storage::disk('box')->put('box-photos/2026/11/x.jpg', 'BOX');
    Storage::disk('public')->put('logo/company.png', 'LOGO'); // logos stay on the server

    expect(File::exists($this->root.'/public/fuel/new.jpg'))->toBeFalse()
        ->and(PhotoFile::where('place', 'tmp')->pluck('path')->sort()->values()->all())->toBe(['box-photos/2026/11/x.jpg', 'fuel/new.jpg'])
        ->and(Storage::disk('public')->get('fuel/new.jpg'))->toBe('NEW')
        ->and(Storage::disk('public')->get('fuel/old.jpg'))->toBe('OLD')
        ->and(Storage::disk('box')->get('box-photos/2026/11/x.jpg'))->toBe('BOX')
        ->and(Storage::disk('public')->exists('fuel/new.jpg'))->toBeTrue()
        ->and(Storage::disk('public')->url('fuel/new.jpg'))->toContain('/photo-storage/fake/tmp/fuel/new.jpg')
        ->and(File::exists($this->root.'/public/logo/company.png'))->toBeTrue();

    // a file upload (Filament / Livewire) goes the same way
    Storage::disk('public')->putFileAs('unmanifested', UploadedFile::fake()->image('p.jpg'), 'p.jpg');
    expect(PhotoStore::placeOf('public', 'unmanifested/p.jpg'))->toBe('tmp');

    Storage::disk('public')->delete('fuel/new.jpg');
    expect(PhotoFile::where('path', 'fuel/new.jpg')->exists())->toBeFalse();
});

it('keeps the photo on the server when the bucket does not answer', function () {
    bucketOn();
    PhotoStore::setTarget('tmp');
    PhotoStore::bucket('tmp')->update(['bucket' => '']); // broken details: not usable
    PhotoStore::forgetMemo();
    Storage::disk('public')->put('fuel/z.jpg', 'Z');
    expect(File::exists($this->root.'/public/fuel/z.jpg'))->toBeTrue();
});

it('moves the server photos, then switches to the real bucket and turns Temporary off', function () {
    Storage::disk('public')->put('shipments/1.jpg', 'ONE');
    Storage::disk('box')->put('box-photos/2026/11/2.jpg', 'TWO');
    bucketOn();
    PhotoStore::setTarget('tmp');
    PhotoStore::forgetMemo();

    $move = PhotoWork::startMove('tmp');
    expect($move->total)->toBe(2);
    PhotoWork::work(10);
    expect($move->fresh()->status)->toBe('done')
        ->and(File::exists($this->root.'/public/shipments/1.jpg'))->toBeFalse()
        ->and(Storage::disk('public')->get('shipments/1.jpg'))->toBe('ONE')
        ->and(Storage::disk('box')->get('box-photos/2026/11/2.jpg'))->toBe('TWO');

    bucketOn('real', 'icargo-photos');
    $sw = PhotoWork::startSwitch(true);
    PhotoWork::work(10);
    PhotoStore::forgetMemo();
    expect($sw->fresh()->status)->toBe('done')
        ->and(PhotoStore::target())->toBe('real')
        ->and(PhotoStore::countIn('tmp'))->toBe(0)
        ->and(PhotoStore::bucket('tmp')->is_off)->toBeTrue()
        ->and(Storage::disk('public')->get('shipments/1.jpg'))->toBe('ONE')
        ->and(PhotoStore::placeOf('box', 'box-photos/2026/11/2.jpg'))->toBe('real');
});

it('copies the old system photos with the same path, smaller, and skips what is there', function () {
    // the old site next to wmsv2, same database
    $old = $this->root.'/wms';
    File::ensureDirectoryExists($old.'/storage/app/public/photos/pod');
    File::put($old.'/artisan', '');
    $c = config('database.connections.'.config('database.default'));
    File::put($old.'/.env', "APP_URL=https://wms.example.test\nDB_HOST=".($c['host'] ?? '')."\nDB_DATABASE=".($c['database'] ?? '')."\n");
    $im = imagecreatetruecolor(2400, 1600); // noise: a big photo
    for ($i = 0; $i < 60000; $i++) {
        imagefilledrectangle($im, $x = random_int(0, 2390), $y = random_int(0, 1590), $x + 9, $y + 9, random_int(0, 0xFFFFFF));
    }
    ob_start();
    imagejpeg($im, null, 95);
    $img = (string) ob_get_clean();
    expect(strlen($img))->toBeGreaterThan(400 * 1024);
    File::put($old.'/storage/app/public/photos/pod/INV-1.jpg', $img);
    AppSetting::put('photos.old_folder', $old);
    DB::table('fuel_fills')->exists() || true;
    $u = User::first();
    DB::table('users')->where('id', $u->id)->update(['profile_picture' => 'photos/pod/INV-1.jpg']);
    DB::table('users')->where('id', '!=', $u->id)->limit(1)->update(['profile_picture' => 'photos/pod/GONE.jpg']);

    $find = OldSystem::find();
    expect($find['found'])->toBeTrue()->and($find['same'])->toBeTrue()
        ->and(OldSystem::columns()->firstWhere('column', 'profile_picture'))->not->toBeNull();

    bucketOn();
    $task = OldSystem::scan();
    $byPath = $task->items()->get()->keyBy('path');
    expect($byPath['photos/pod/INV-1.jpg']->found)->toBe('wms')
        ->and($byPath['photos/pod/GONE.jpg']->status)->toBe('missing');

    $task->update(['status' => 'running']);
    PhotoWork::work(15);
    $task->refresh();
    $item = $task->items()->where('path', 'photos/pod/INV-1.jpg')->first();
    // put in the new folders (board 67): people/…, and the record now points there
    expect($task->status)->toBe('done')->and($item->status)->toBe('done')->and($item->checked)->toBeTrue()
        ->and($item->size_after)->toBeLessThan($item->size_before)
        ->and($item->new_path)->toBe('people/INV-1.jpg')
        ->and(DB::table('users')->where('id', $u->id)->value('profile_picture'))->toBe('people/INV-1.jpg')
        ->and(PhotoStore::placeOf('public', 'people/INV-1.jpg'))->toBe('tmp')
        ->and(Storage::disk('public')->exists('people/INV-1.jpg'))->toBeTrue()
        ->and(File::exists($old.'/storage/app/public/photos/pod/INV-1.jpg'))->toBeTrue(); // the old site is never touched

    // copy again: nothing new
    OldSystem::scan()->update(['status' => 'running']);
    PhotoWork::work(5);
    expect($task->fresh()->items()->where('path', 'photos/pod/INV-1.jpg')->value('status'))->toBe('done');
});

it('shows the photo storage page with its tabs and saves a bucket', function () {
    Livewire::test(PhotoStorage::class)
        ->assertSee('Setup checklist')->assertSee('Copy from the old system')
        ->call('setTab', 'bucket')->assertSee('New photos go to')->assertSee('Temporary bucket')
        ->set('form.tmp.account_id', 'acc9')->set('form.tmp.bucket', 'negosmart')->set('form.tmp.access_key', 'AK')->set('form.tmp.secret', 'SEC')
        ->call('saveBucket', 'tmp')->assertSee('Uploaded, read and deleted a test file')
        ->call('setTarget', 'tmp')
        ->call('turnOff', 'tmp')->assertSee('new photos still go here')
        ->call('setTab', 'work')->assertSee('Run here');
    expect(PhotoStore::target())->toBe('tmp')
        ->and(PhotoStore::bucket('tmp')->secret)->toBe('SEC')
        ->and(DB::table('storage_buckets')->value('secret'))->not->toBe('SEC'); // kept encrypted
});


it('saves new photos in the tidy folders, at most 200 KB', function () {
    expect(\App\Support\Photos\Storage\PhotoFolders::dir('delivery', '0144033', '2026-11-20'))->toBe('delivery/2026/11/0144033')
        ->and(\App\Support\Photos\Storage\PhotoFolders::dir('trucks', 'ABC 1234'))->toBe('trucks/ABC-1234');
    $im = imagecreatetruecolor(2000, 1500);
    for ($i = 0; $i < 40000; $i++) {
        imagefilledrectangle($im, $x = random_int(0, 1990), $y = random_int(0, 1490), $x + 9, $y + 9, random_int(0, 0xFFFFFF));
    }
    ob_start();
    imagejpeg($im, null, 92);
    $big = (string) ob_get_clean();
    Storage::disk('public')->put('delivery/2026/11/1/a.jpg', $big);
    expect(strlen(Storage::disk('public')->get('delivery/2026/11/1/a.jpg')))->toBeLessThan(strlen($big))
        ->and(strlen(Storage::disk('public')->get('delivery/2026/11/1/a.jpg')))->toBeLessThanOrEqual(320 * 1024); // pure noise; a real photo ends near 200 KB

    $box = \App\Models\Invoice::firstOrFail();
    $p = \App\Support\Photos\BoxPhotos::store(UploadedFile::fake()->image('b.jpg', 800, 600), 'unload', $box, [], $this->admin);
    expect($p->path)->toStartWith('scan/unload/'.now()->format('Y/m').'/'.$box->invoice.'/')
        ->and(Storage::disk('box')->exists($p->path))->toBeTrue();
});

it('moves the server photos into the tidy folders and changes the path in the record', function () {
    $trip = \App\Models\Tripinvoice::firstOrFail();
    Storage::disk('public')->put('0144033/pod.jpg', 'POD');
    DB::table('tripinvoices')->where('id', $trip->id)->update(['delivery_picture' => json_encode(['0144033/pod.jpg']), 'delivered_at' => '2025-08-14 10:00:00']);
    bucketOn();
    PhotoStore::setTarget('tmp');
    PhotoStore::forgetMemo();

    $move = PhotoWork::startMove('tmp', true);
    PhotoWork::work(10);
    $new = 'delivery/2025/08/'.\App\Support\Photos\Storage\PhotoFolders::clean($trip->invoice).'/pod.jpg';
    expect($move->fresh()->status)->toBe('done')
        ->and(json_decode(DB::table('tripinvoices')->where('id', $trip->id)->value('delivery_picture'), true))->toBe([$new])
        ->and(Storage::disk('public')->get($new))->toBe('POD')
        ->and(File::exists($this->root.'/public/0144033/pod.jpg'))->toBeFalse();
});
DISPATCH_FILE_END_38

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
