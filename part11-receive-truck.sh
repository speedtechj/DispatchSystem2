#!/usr/bin/env bash
#
# Dispatch System — Part 11 · Receive truck at partner hubs, hub receive photo
# Only the files changed in this step; the rest of your project is left as it is.
#
#   cd ~/Desktop/Project/DispatchSystem
#   bash ~/Desktop/Project/part11-receive-truck.sh

set -euo pipefail
[ -f artisan ] || { echo "Run this from inside your DispatchSystem project folder (the one with 'artisan')."; exit 1; }

STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="../DispatchSystem-backup-$STAMP.tar.gz"
echo "▶ Backing up the project to $BACKUP"
tar -czf "$BACKUP" --exclude=vendor --exclude=node_modules --exclude=storage/logs .

echo "▶ Writing 14 files"

# ---------------------------------------------------------------- app/Filament/Resources/Deliverylogs/Tables/DeliverylogsTable.php
mkdir -p 'app/Filament/Resources/Deliverylogs/Tables'
cat > 'app/Filament/Resources/Deliverylogs/Tables/DeliverylogsTable.php' <<'DISPATCH_FILE_END_0'
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

                // Partner hub by truck: "Received by Baguio · 2 missing" (Scan app · Receive truck).
                TextColumn::make('hub_received')
                    ->label('Hub received')
                    ->badge()
                    ->color(fn ($state) => str_contains((string) $state, 'missing') ? 'danger' : (str_contains((string) $state, 'Received') ? 'success' : 'warning'))
                    ->visible(fn () => \App\Support\Shipping\TruckReceive::ready())
                    ->getStateUsing(function ($record) {
                        $r = \App\Models\Shipping\TruckReceipt::with('hub:id,hub_name')->where('deliverylog_id', $record->id)->get();

                        return $r->isEmpty() ? null : $r->map(fn ($x) => $x->finished_at
                            ? 'Received by '.($x->hub?->hub_name ?? 'hub').($x->missing ? ' · '.$x->missing.' missing' : '')
                            : ($x->hub?->hub_name ?? 'Hub').' receiving…')->join(' / ');
                    }),

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
                Action::make('seaShipment')
                    ->label('Make it a sea shipment')
                    ->icon('heroicon-o-globe-asia-australia')
                    ->button()
                    ->color('info')
                    ->tooltip(fn ($record) => ($record->destination?->hub_name ?? 'This hub').' is reached by sea')
                    ->visible(fn ($record): bool => \App\Support\Shipping\Shipments::ready() && $record->is_active && $record->destination?->is_company
                        && \App\Support\Shipping\Islands::bySea($record->destination) && ! \App\Models\Shipping\SeaShipment::where('deliverylog_id', $record->id)->exists())
                    ->url(fn ($record): string => \App\Filament\Pages\SeaShipments::getUrl(['trip' => $record->id])),
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
DISPATCH_FILE_END_0

# ---------------------------------------------------------------- app/Filament/Scan/Pages/ScanApp.php
mkdir -p 'app/Filament/Scan/Pages'
cat > 'app/Filament/Scan/Pages/ScanApp.php' <<'DISPATCH_FILE_END_1'
<?php

namespace App\Filament\Scan\Pages;

use App\Models\Ai\AiPhotoCheck;
use App\Models\BoxPhoto;
use App\Models\Deliverylog;
use App\Models\Invoice;
use App\Models\PhotoSetting;
use App\Models\Unmanifested;
use App\Support\Ai\Ai;
use App\Support\Ai\PhotoCheck;
use App\Support\BoxSizes;
use App\Support\Photos\BoxPhotos;
use App\Support\ScanModes;
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

    /** Load truck: the box is for another hub. */
    #[Locked]
    public ?array $wrongHub = null;


    /** Show the finished and closed ones on the pick list too (greyed out). */
    public bool $showFinished = false;

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
    }

    public function pick(int $id): void
    {
        $station = $this->station();
        if (! $station || ! $station->appChoices()->contains('id', $id)) {
            Notification::make()->title('That one is not open for you any more.')->warning()->send();

            return;
        }
        $this->choice = $id;
        $this->returned = 0;
        $this->screen = 'scan';
        $this->clearResult();
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

        return $station->appChoices()->values()->map(function (array $c, int $i) use ($modeKey) {
            $p = $this->station($c['id'], $modeKey)->progress();
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
        $this->reset('status', 'message', 'invoiceId', 'missing', 'condition', 'note', 'boxPhoto', 'early', 'spot', 'route', 'setInfo', 'wrongHub');
    }

    /** Called by the camera or the typed box number. */
    public function scan(string $code): void
    {
        $this->runScan($code);
    }

    /** After "too early": load that box anyway. */
    public function loadAnyway(): void
    {
        if ($code = $this->early['code'] ?? $this->wrongHub['code'] ?? null) {
            $this->runScan($code, true);
        }
    }

    // ------------------------------------------------------------------ sections, truck waiting, sets

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
        if (! $trip || ! \App\Support\TruckSpace::topUp($trip)['boxes']->contains('id', $invoiceId)) {
            Notification::make()->title('That box does not fit or is not free any more.')->warning()->send();

            return;
        }
        try {
            app(\App\Services\TripAssignment::class)->addToDeliveryTrip($trip, Invoice::whereKey($invoiceId)->get());
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

    protected function runScan(string $code, bool $force = false): void
    {
        $station = $this->station();
        if (! $station || ! $this->choice || $this->screen !== 'scan') {
            return;
        }

        if ($force && property_exists($station, 'forceLoad')) {
            $station->forceLoad = true;
        }
        $station->scan($code);
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

        if ($this->status === 'success') {
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
                FileUpload::make('attachment_pic')->label('Photo')->image()->disk('public')->directory('unmanifested')->visibility('private')->required(),
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
            $target = $station->appChoices()->firstWhere('id', $this->choice);
            $loadNext = $this->screen === 'scan' && method_exists($station, 'loadNext') ? $station->loadNext() : null;
            $team = method_exists($station, 'team') ? $station->team() : [];
            $trucks = $this->mode === 'unload' && method_exists($station, 'truckStatus') ? $station->truckStatus() : [];
            $openSets = $this->screen === 'done' && method_exists($station, 'openSets') ? $station->openSets() : [];
            $countResult = $this->screen === 'done' && method_exists($station, 'countResult') ? $station->countResult() : null;
            $receiveResult = $this->screen === 'done' && method_exists($station, 'receiveResult') ? $station->receiveResult() : null;
            // Box sizes: space on the truck while loading (a big box takes more).
            if (in_array($this->mode, ['load', 'hub_load'], true) && BoxSizes::on() && ($trip = Deliverylog::with('truck')->find($this->choice))) {
                $space = BoxSizes::tripSpace($trip, $this->mode === 'hub_load');
                if ($this->screen === 'done' && $this->mode === 'load' && ($progress['total'] ?? 0) > 0 && ($progress['loaded'] ?? 0) >= $progress['total']) {
                    $topUp = \App\Support\TruckSpace::topUp($trip);
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
            'waiting' => $this->screen === 'home' ? $this->waitingCounts() : [],
            'progress' => $progress,
            'target' => $target,
            'loadNext' => $loadNext,
            'team' => $team,
            'trucks' => $trucks,
            'openSets' => $openSets,
            'countResult' => $countResult,
            'receiveResult' => $receiveResult,
            'topUp' => $topUp,
            'noReason' => collect($openSets)->filter(fn ($o) => collect($o['missing'])->contains(fn ($m) => ! $m['reason']))->count(),
            'splitReasons' => \App\Models\Boxes\SetSplit::REASONS,
            'box' => $box = ($this->invoiceId ? Invoice::find($this->invoiceId) : null),
            'space' => $space ?? null,
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
DISPATCH_FILE_END_1

# ---------------------------------------------------------------- app/Filament/Shared/Shipping/ShipmentScanStation.php
mkdir -p 'app/Filament/Shared/Shipping'
cat > 'app/Filament/Shared/Shipping/ShipmentScanStation.php' <<'DISPATCH_FILE_END_2'
<?php

namespace App\Filament\Shared\Shipping;

use App\Filament\Concerns\ScansInvoices;
use App\Models\Shipping\SeaShipment;
use App\Models\Shipping\SeaShipmentScan;
use App\Models\Tripinvoice;
use App\Models\User;
use App\Support\Shipping\Shipments;
use App\Support\Tracking\Tracker;
use Filament\Pages\Page;
use Illuminate\Support\Collection;
use Illuminate\Support\Facades\Auth;

/**
 * Scan station for a sea shipment, used by the Scan app: Port check (the boxes handed over at
 * the port) or Receive (the partner hub scans the container in).
 */
abstract class ShipmentScanStation extends Page
{
    use ScansInvoices;

    protected string $view = 'filament.pages.scaninvoice';

    /** port or received */
    protected static string $step = 'port';

    /** The box's set at the hub: "2 of 3 arrived · 1 still in Manila". */
    public ?array $setInfo = null;

    /** The box is for another hub (added to the Wrong hub list). */
    public ?array $route = null;

    protected function selectionField(): ?string
    {
        return 'sea_shipment_id';
    }

    protected function selectionLabel(): string
    {
        return 'a shipment';
    }

    /** Shipments open for this scan. */
    abstract protected function shipments(): \Illuminate\Database\Eloquent\Builder;

    protected function selected(): ?SeaShipment
    {
        return $this->shipments()->find($this->data['sea_shipment_id'] ?? null);
    }

    protected function handleScan(string $code): void
    {
        $this->setInfo = null;
        $this->route = null;
        $s = $this->selected();
        if (! $s) {
            $this->scanResult('danger', 'That shipment is not open for this scan any more.');

            return;
        }
        $row = Tripinvoice::with('invdata.whSection')->where('deliverylog_id', $s->deliverylog_id)->where('invoice', $code)->latest('id')->first();
        if (! $row) {
            $other = $this->invoicesMatching($code)->first();
            $this->scanResult('danger', "{$code} is not in shipment {$s->code}.", $other);

            return;
        }
        if (static::$step === 'port' && ! $row->is_loaded) {
            $this->scanResult('warning', "{$code} was never scanned onto trip {$s->trip?->trip_number} at the warehouse. Check where it came from.", $row->invdata);

            return;
        }
        $prev = SeaShipmentScan::where('sea_shipment_id', $s->id)->where('invoice_id', $row->invoice_id)->where('step', static::$step)->first();
        if ($prev) {
            $who = $prev->user_id && $prev->user_id !== Auth::id() ? User::find($prev->user_id)?->first_name : null;
            $this->scanResult('warning', "{$code} was already scanned".($who ? " by {$who}" : '').($prev->created_at ? ' at '.\Illuminate\Support\Carbon::parse($prev->created_at)->format('g:i A') : '').'. Not counted again.', $row->invdata);

            return;
        }
        Shipments::scan($s, $row, static::$step);

        if (static::$step === 'received') {
            $this->setInfo = $row->invdata ? Shipments::setAtHub($s, $row->invdata) : null;
            if ($wrong = Shipments::checkWrongHub($s, $row)) {
                $this->route = ['kind' => 'wrong', 'code' => '⛔', 'name' => 'Not ours: for '.($wrong->correctHub?->hub_name ?? 'another hub'), 'color' => '#c8372d', 'why' => 'Put it aside. It is on the Wrong hub & returns list.'];
                $this->scanResult('warning', "{$code} is for ".($wrong->correctHub?->hub_name ?? 'another hub').'. Received, and put on the Wrong hub & returns list.', $row->invdata);

                return;
            }
        }
        $this->scanResult('success', "{$code} ".(static::$step === 'port' ? 'handed over at the port.' : 'received.'), $row->invdata);
    }

    public function progress(): array
    {
        $s = $this->selected();
        if (! $s) {
            return ['loaded' => 0, 'total' => 0];
        }

        return [
            'loaded' => SeaShipmentScan::where('sea_shipment_id', $s->id)->where('step', static::$step)->count(),
            'total' => Tripinvoice::where('deliverylog_id', $s->deliverylog_id)->where('is_loaded', true)->count(),
        ];
    }

    public function team(): array
    {
        $id = $this->data['sea_shipment_id'] ?? null;
        if (! $id) {
            return [];
        }
        $counts = SeaShipmentScan::where('sea_shipment_id', $id)->where('step', static::$step)->whereNotNull('user_id')->selectRaw('user_id, count(*) n')->groupBy('user_id')->pluck('n', 'user_id');
        $names = User::whereIn('id', $counts->keys())->pluck('first_name', 'id');

        return $counts->sortDesc()->map(fn ($n, $uid) => ['name' => (int) $uid === Auth::id() ? 'You' : ($names[$uid] ?? '?'), 'n' => (int) $n, 'me' => (int) $uid === Auth::id()])->values()->all();
    }

    public function household(): array
    {
        return [];
    }

    /** Receive container asks for the photo of the box at the partner hub (Box photo settings: Receiving at a partner hub). */
    public function photoStep(): ?string
    {
        return static::$step === 'received' ? 'hub_receive' : null;
    }

    public function photoContext(): array
    {
        $s = $this->selected();

        return ['deliverylog_id' => $s?->deliverylog_id, 'logistichub_id' => $s?->logistichub_id];
    }

    /** Receive container, Done screen: received, missing, and Finish receiving. */
    public function receiveResult(): ?array
    {
        $s = static::$step === 'received' ? $this->selected() : null;
        if (! $s) {
            return null;
        }
        $c = Shipments::counts($s);
        $got = SeaShipmentScan::where('sea_shipment_id', $s->id)->where('step', 'received')->count();
        $missing = Tripinvoice::where('deliverylog_id', $s->deliverylog_id)->where('is_loaded', true)
            ->whereNotIn('invoice_id', SeaShipmentScan::where('sea_shipment_id', $s->id)->where('step', 'received')->select('invoice_id'))->limit(30)->pluck('invoice');

        return ['got' => $got, 'of' => $c['loaded'], 'finished' => $s->status === 'received',
            'missing' => $missing->map(fn ($code) => ['code' => $code, 'sub' => 'Not scanned off the container'])->all()];
    }

    public function finishReceiving(): ?int
    {
        $s = static::$step === 'received' ? $this->selected() : null;

        return $s ? Shipments::finishReceiving($s) : null;
    }

    public function appChoices(): Collection
    {
        return $this->shipments()->latest('id')->limit(40)->get()->map(fn (SeaShipment $s) => [
            'id' => $s->id, 'name' => $s->code.' → '.($s->hub?->hub_name ?? ''), 'active' => true,
            'sub' => collect([$s->van_no ? 'Van '.$s->van_no : null, Shipments::label($s), $s->eta ? 'ETA '.$s->eta->format('M j') : null])->filter()->join(' · '),
        ]);
    }

    protected function hub(string $panel): int|false|null
    {
        return Tracker::hubFor(Auth::user(), $panel);
    }
}
DISPATCH_FILE_END_2

# ---------------------------------------------------------------- app/Filament/Shared/Shipping/TruckReceiveStation.php
mkdir -p 'app/Filament/Shared/Shipping'
cat > 'app/Filament/Shared/Shipping/TruckReceiveStation.php' <<'DISPATCH_FILE_END_3'
<?php

namespace App\Filament\Shared\Shipping;

use App\Filament\Concerns\ScansInvoices;
use App\Models\Deliverylog;
use App\Models\Shipping\SeaShipment;
use App\Models\Shipping\TruckReceiptScan;
use App\Models\Tripinvoice;
use App\Models\User;
use App\Support\Shipping\Shipments;
use App\Support\Shipping\TruckReceive;
use Filament\Pages\Page;
use Illuminate\Support\Carbon;
use Illuminate\Support\Collection;
use Illuminate\Support\Facades\Auth;

/** Scan app · Receive truck: the partner hub (by truck) scans every box in when the truck from Manila arrives. */
class TruckReceiveStation extends Page
{
    use ScansInvoices;

    protected string $view = 'filament.pages.scaninvoice';

    protected static bool $shouldRegisterNavigation = false;

    public ?array $setInfo = null;

    public ?array $route = null;

    protected function selectionField(): ?string
    {
        return 'deliverylog_id';
    }

    protected function selectionLabel(): string
    {
        return 'a truck';
    }

    protected function hubId(): int
    {
        return (int) Auth::user()?->logistichub_id;
    }

    protected function selected(): ?Deliverylog
    {
        $id = (int) ($this->data['deliverylog_id'] ?? 0);

        return $id && TruckReceive::rows($id, $this->hubId())->exists() ? Deliverylog::find($id) : null;
    }

    protected function handleScan(string $code): void
    {
        $this->setInfo = null;
        $this->route = null;
        $trip = $this->selected();
        $hub = $this->hubId();
        if (! $trip) {
            $this->scanResult('danger', 'Pick the truck that arrived first.');

            return;
        }
        $row = Tripinvoice::with('invdata.whSection')->where('deliverylog_id', $trip->id)->where('logistichub_id', $hub)->where('invoice', $code)->latest('id')->first();
        if (! $row) {
            $other = Tripinvoice::where('invoice', $code)->latest('id')->first();
            $sea = $other && Shipments::ready() ? SeaShipment::where('deliverylog_id', $other->deliverylog_id)->first() : null;
            $box = $this->invoicesMatching($code)->first();
            if ($sea) {
                $this->scanResult('warning', "{$code} came on sea shipment {$sea->code}. Use Receive container.", $box);
            } elseif ($other && (int) $other->deliverylog_id !== $trip->id) {
                $this->route = ['kind' => 'wrong', 'code' => '!', 'name' => 'Not on this truck', 'color' => '#b07400', 'why' => 'It is on trip '.Deliverylog::whereKey($other->deliverylog_id)->value('trip_number').'. Keep it apart and tell the office.'];
                $this->scanResult('warning', "{$code} is not on this truck.", $box);
            } else {
                $this->scanResult('danger', "{$code} is not on trip {$trip->trip_number} for your hub.", $box);
            }

            return;
        }
        $prev = TruckReceiptScan::where('deliverylog_id', $trip->id)->where('invoice_id', $row->invoice_id)->first();
        if ($prev) {
            $who = $prev->user_id && $prev->user_id !== Auth::id() ? User::find($prev->user_id)?->first_name : null;
            $this->scanResult('warning', "{$code} was already received".($who ? " by {$who}" : '').($prev->created_at ? ' at '.Carbon::parse($prev->created_at)->format('g:i A') : '').'. Not counted again.', $row->invdata);

            return;
        }
        $wasLoaded = (bool) $row->is_loaded;
        TruckReceive::scan($trip->id, $hub, $row);
        $this->setInfo = $row->invdata ? TruckReceive::setAtHub($trip->id, $hub, $row->invdata) : null;
        if ($wrong = TruckReceive::checkWrongHub($hub, $row)) {
            $this->route = ['kind' => 'wrong', 'code' => '⛔', 'name' => 'Not ours: for '.($wrong->correctHub?->hub_name ?? 'another hub'), 'color' => '#c8372d', 'why' => 'Put it aside. It is on the Wrong hub & returns list.'];
            $this->scanResult('warning', "{$code} is for ".($wrong->correctHub?->hub_name ?? 'another hub').'. Received, and put on the Wrong hub & returns list.', $row->invdata);

            return;
        }
        $this->scanResult('success', "{$code} received at your hub.".($wasLoaded ? '' : ' It was not scanned onto the truck in Manila.'), $row->invdata);
    }

    public function progress(): array
    {
        $id = (int) ($this->data['deliverylog_id'] ?? 0);
        if (! $id) {
            return ['loaded' => 0, 'total' => 0];
        }
        $c = TruckReceive::counts($id, $this->hubId());

        return ['loaded' => $c['got'], 'total' => $c['of']];
    }

    /** Done screen: received, missing, and Finish receiving. */
    public function receiveResult(): ?array
    {
        $trip = $this->selected();
        if (! $trip) {
            return null;
        }
        $c = TruckReceive::counts($trip->id, $this->hubId());
        $names = User::whereIn('id', $c['missing']->pluck('loaded_by')->filter())->pluck('first_name', 'id');

        return ['got' => $c['got'], 'of' => $c['of'], 'finished' => (bool) TruckReceive::receipt($trip->id, $this->hubId())?->finished_at,
            'missing' => $c['missing']->take(30)->map(fn ($r) => ['code' => $r->invoice,
                'sub' => 'Loaded in Manila'.($r->loaded_by && isset($names[$r->loaded_by]) ? ' by '.$names[$r->loaded_by] : '').($r->loaded_at ? ' at '.Carbon::parse($r->loaded_at)->format('M j g:i A') : '')])->all()];
    }

    public function finishReceiving(): ?int
    {
        $trip = $this->selected();

        return $trip ? TruckReceive::finish($trip, $this->hubId()) : null;
    }

    public function team(): array
    {
        $id = (int) ($this->data['deliverylog_id'] ?? 0);
        if (! $id) {
            return [];
        }
        $counts = TruckReceiptScan::where('deliverylog_id', $id)->whereNotNull('user_id')->selectRaw('user_id, count(*) n')->groupBy('user_id')->pluck('n', 'user_id');
        $names = User::whereIn('id', $counts->keys())->pluck('first_name', 'id');

        return $counts->sortDesc()->map(fn ($n, $uid) => ['name' => (int) $uid === Auth::id() ? 'You' : ($names[$uid] ?? '?'), 'n' => (int) $n, 'me' => (int) $uid === Auth::id()])->values()->all();
    }

    public function household(): array
    {
        return [];
    }

    public function photoStep(): ?string
    {
        return 'hub_receive';
    }

    public function photoContext(): array
    {
        return ['deliverylog_id' => $this->data['deliverylog_id'] ?? null, 'logistichub_id' => $this->hubId()];
    }

    public function appChoices(): Collection
    {
        return TruckReceive::trips($this->hubId())->map(fn (Deliverylog $t) => [
            'id' => $t->id, 'name' => $t->trip_number.' from Manila', 'active' => true,
            'sub' => collect([$t->truck?->plate_no ? 'Truck '.$t->truck->plate_no : null, $t->delivery_date ? 'Date '.Carbon::parse($t->delivery_date)->format('M j') : null])->filter()->join(' · '),
        ])->values();
    }
}
DISPATCH_FILE_END_3

# ---------------------------------------------------------------- app/Models/BoxPhoto.php
mkdir -p 'app/Models'
cat > 'app/Models/BoxPhoto.php' <<'DISPATCH_FILE_END_4'
<?php

namespace App\Models;

use Illuminate\Database\Eloquent\Builder;
use Illuminate\Database\Eloquent\Model;
use Illuminate\Database\Eloquent\Relations\BelongsTo;
use Illuminate\Support\Facades\Storage;

/** One photo taken while scanning. Every capture is its own row and file; nothing is replaced. */
class BoxPhoto extends Model
{
    public const STEPS = [
        'unload' => 'Unloading a container',
        'load' => 'Loading a delivery truck',
        'hub_load' => 'Loading at a partner hub',
        'wh_load' => 'Warehouse to warehouse: loading',
        'wh_unload' => 'Warehouse to warehouse: unloading',
        'return' => 'Returning boxes',
        'hub_receive' => 'Receiving at a partner hub',
    ];

    public const SHORT = [
        'unload' => 'Unload', 'load' => 'Load', 'hub_load' => 'Hub load',
        'wh_load' => 'WH transfer load', 'wh_unload' => 'WH transfer unload', 'return' => 'Return', 'hub_receive' => 'Hub receive',
    ];

    public const CONDITIONS = ['good' => 'Good', 'damaged' => 'Damaged', 'wet' => 'Wet', 'open' => 'Open'];

    protected $guarded = [];

    protected function casts(): array
    {
        return ['taken_at' => 'datetime', 'is_batch' => 'boolean'];
    }

    public function box(): BelongsTo
    {
        return $this->belongsTo(Invoice::class, 'invoice_id');
    }

    public function container(): BelongsTo
    {
        return $this->belongsTo(Container::class);
    }

    public function deliverylog(): BelongsTo
    {
        return $this->belongsTo(Deliverylog::class);
    }

    public function whdeliverylog(): BelongsTo
    {
        return $this->belongsTo(Whdeliverylog::class);
    }

    public function user(): BelongsTo
    {
        return $this->belongsTo(User::class);
    }

    public function warehouse(): BelongsTo
    {
        return $this->belongsTo(Warehouse::class);
    }

    public function logistichub(): BelongsTo
    {
        return $this->belongsTo(Logistichub::class);
    }

    /**
     * Who may see which photos: admin and warehouse staff see all;
     * partner hub staff see photos of boxes sent to their hub or taken by them.
     */
    public function scopeVisibleTo(Builder $query, ?User $user): Builder
    {
        if (! $user) {
            return $query->whereRaw('1 = 0');
        }
        if ($user->hasRole('super_admin')) {
            return $query;
        }
        $hub = $user->logistichub_id ? Logistichub::find($user->logistichub_id) : null;
        if (! $hub || ! $hub->is_company) {
            // admin and warehouse staff
            return ($hub || $user->warehouse_id) ? $query : $query->whereRaw('1 = 0');
        }

        return $query->where(fn (Builder $q) => $q->where('logistichub_id', $hub->id)
            ->orWhereIn('invoice_id', Tripinvoice::where('logistichub_id', $hub->id)->select('invoice_id')));
    }

    public function scopeSearch(Builder $query, string $term): Builder
    {
        $term = trim($term);
        if ($term === '') {
            return $query;
        }

        return $query->where(fn (Builder $q) => $q->where('invoice', 'like', "%{$term}%")
            ->orWhereHas('container', fn (Builder $c) => $c->where('container_no', 'like', "%{$term}%"))
            ->orWhereHas('deliverylog', fn (Builder $d) => $d->where('trip_number', 'like', "%{$term}%"))
            ->orWhereHas('whdeliverylog', fn (Builder $d) => $d->where('trip_number', 'like', "%{$term}%")));
    }

    public function url(): string
    {
        return route('box-photos.show', $this);
    }

    public function downloadUrl(): string
    {
        return route('box-photos.download', $this);
    }

    /** Where it was taken: container or trip. */
    public function reference(): string
    {
        return match (true) {
            (bool) $this->deliverylog_id => 'Trip '.($this->deliverylog?->trip_number ?? '#'.$this->deliverylog_id),
            (bool) $this->whdeliverylog_id => 'WH trip '.($this->whdeliverylog?->trip_number ?? '#'.$this->whdeliverylog_id),
            (bool) $this->container_id => 'Container '.($this->container?->container_no ?? '#'.$this->container_id),
            default => '—',
        };
    }

    public function place(): string
    {
        return $this->warehouse?->name ?? $this->logistichub?->hub_name ?? '';
    }

    /** INV004521_unload_2.jpg — position among the photos of this box at this step. */
    public function fileName(): string
    {
        $n = static::where('invoice_id', $this->invoice_id)->where('step', $this->step)->where('is_batch', $this->is_batch)
            ->where('id', '<=', $this->id)->count();
        $base = $this->is_batch ? 'batch_'.str($this->reference())->slug('_') : ($this->invoice ?: 'box');

        return $base.'_'.$this->step.'_'.max(1, $n).'.jpg';
    }

    public function exists(): bool
    {
        return Storage::disk('local')->exists($this->path);
    }

    protected static function booted(): void
    {
        static::deleting(fn (BoxPhoto $p) => Storage::disk('local')->delete($p->path));
    }
}
DISPATCH_FILE_END_4

# ---------------------------------------------------------------- app/Models/Shipping/TruckReceipt.php
mkdir -p 'app/Models/Shipping'
cat > 'app/Models/Shipping/TruckReceipt.php' <<'DISPATCH_FILE_END_5'
<?php

namespace App\Models\Shipping;

use App\Models\Deliverylog;
use App\Models\Logistichub;
use Illuminate\Database\Eloquent\Model;
use Illuminate\Database\Eloquent\Relations\BelongsTo;

/** A partner hub received a truck (trip) from Manila: when, by whom, how many boxes were missing. */
class TruckReceipt extends Model
{
    protected $guarded = [];

    protected function casts(): array
    {
        return ['finished_at' => 'datetime'];
    }

    public function trip(): BelongsTo
    {
        return $this->belongsTo(Deliverylog::class, 'deliverylog_id');
    }

    public function hub(): BelongsTo
    {
        return $this->belongsTo(Logistichub::class, 'logistichub_id');
    }
}
DISPATCH_FILE_END_5

# ---------------------------------------------------------------- app/Models/Shipping/TruckReceiptScan.php
mkdir -p 'app/Models/Shipping'
cat > 'app/Models/Shipping/TruckReceiptScan.php' <<'DISPATCH_FILE_END_6'
<?php

namespace App\Models\Shipping;

use Illuminate\Database\Eloquent\Model;

/** One box scanned in at the partner hub off a truck. */
class TruckReceiptScan extends Model
{
    public $timestamps = false;

    protected $guarded = [];

    protected function casts(): array
    {
        return ['created_at' => 'datetime'];
    }
}
DISPATCH_FILE_END_6

# ---------------------------------------------------------------- app/Support/Help/DefaultGuides.php
mkdir -p 'app/Support/Help'
cat > 'app/Support/Help/DefaultGuides.php' <<'DISPATCH_FILE_END_7'
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
                'slug' => 'box-sizes', 'topic' => 'settings', 'icon' => '📐', 'apps' => ['admin'],
                'title_en' => 'Box sizes: fill trucks by space', 'title_tl' => 'Laki ng box: punuin ang truck ayon sa espasyo',
                'summary_en' => 'Big boxes take more room. Set how much space each box type from your manifests takes, and the AI trip helper fills trucks by space, not by count.',
                'summary_tl' => 'Mas maraming espasyo ang malaking box. Itakda kung gaano kalaki ang bawat box type mula sa manifest, at pupunuin ng AI trip helper ang truck ayon sa espasyo, hindi sa bilang.',
                'when_en' => 'Trucks look half empty on the plan but are full at the loading bay, or the other way round.',
                'when_tl' => 'Mukhang kalahati lang ang truck sa plano pero puno na sa loading bay, o baligtad.',
                'steps' => [
                    $s('Open Box sizes', 'Settings → Box sizes. The box types from your manifests are listed with how many boxes of each.', 'Buksan ang Box sizes', 'Settings → Box sizes. Nakalista ang mga box type mula sa manifest at kung ilan ang bawat isa.'),
                    $s('Choose your normal box', 'The most common type is your normal box (1). Press "Make this the normal box" on another one to change it.', 'Piliin ang normal na box', 'Ang pinakamarami ang normal na box (1). Pindutin ang "Make this the normal box" sa iba para palitan.'),
                    $s('Set the other sizes', 'Use − and + next to each type: half the size = ½, one and a half = 1½, double = 2. New types show as "New · not set" and count as 1 until you set them.', 'Itakda ang ibang laki', 'Gamitin ang − at + sa bawat type: kalahati = ½, isa\'t kalahati = 1½, doble = 2. Ang bagong type ay "New · not set" at bilang na 1 hangga\'t hindi naitatakda.'),
                    $s('Join the same box', 'Under "These look like the same box", press Join when two names are one box ("LG" and "Large").', 'Pagsamahin ang parehong box', 'Sa "These look like the same box", pindutin ang Join kapag iisang box ang dalawang pangalan ("LG" at "Large").'),
                    $s('Set each truck\'s space', 'Under Truck space, set how many normal boxes fit in each truck. "Last 90 days" shows the most it carried.', 'Itakda ang espasyo ng truck', 'Sa Truck space, itakda kung ilang normal na box ang kasya sa bawat truck. Ipinapakita ng "Last 90 days" ang pinakamaraming naisakay.'),
                ],
                'result_en' => 'Trip drafts show "52 / 60 space · 44 boxes", and the Scan app shows the space used while loading.',
                'result_tl' => 'Ipinapakita ng draft ng trip ang "52 / 60 space · 44 boxes", at ng Scan app ang nagamit na espasyo habang naglo-load.',
                'problems' => [
                    $p('A box has no type on the manifest', 'It counts as your normal box (1).', 'Walang box type sa manifest', 'Bilang ito na normal na box (1).'),
                ],
                'pages' => ['pages.box-sizes', 'resources.trucks.*'],
                'links' => ['admin' => 'pages.box-sizes'],
                'related' => ['ai-trip-helper', 'load-truck'], 'sort' => 30,
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
            // ───────────────────────────── warehouse sections ─────────────────────────────
            [
                'slug' => 'warehouse-sections', 'topic' => 'boxes', 'icon' => '🗂️', 'apps' => ['admin', 'warehouse', 'scan'],
                'title_en' => 'Warehouse sections, box sets and the waiting truck', 'title_tl' => 'Mga seksyon ng bodega, set ng box at truck na naghihintay',
                'summary_en' => 'At unload the Scan app shows the section of each box from the receiver\'s province, keeps a customer\'s boxes together, and can load boxes straight onto a waiting truck.',
                'summary_tl' => 'Sa unloading, ipinapakita ng Scan app ang seksyon ng bawat box ayon sa probinsya ng receiver, pinagsasama ang mga box ng isang customer, at puwedeng ikarga agad sa truck na naghihintay.',
                'when_en' => 'Every container unload and every truck you load.',
                'when_tl' => 'Sa bawat pag-unload ng container at bawat truck na kinakargahan.',
                'steps' => [
                    $s('Set the sections once', 'Admin → Settings → Warehouse sections: one section per destination, with its provinces. Print the QR labels if you use the label scan.', 'I-set ang mga seksyon minsan', 'Admin → Settings → Warehouse sections: isang seksyon bawat destinasyon, kasama ang mga probinsya. I-print ang QR labels kung gagamit ng label scan.'),
                    $s('Scan at the container door', 'Scan each box as it comes off. The big letter on the phone is its section: put the box there. X means check the address first.', 'Mag-scan sa pinto ng container', 'I-scan ang bawat box pagbaba. Ang malaking letra sa phone ang seksyon nito: doon ilagay. Ang X ay check address muna.'),
                    $s('Keep sets together', '"Box 2 of 3" shows where the customer\'s other boxes are: still in this container, or in another one.', 'Pagsamahin ang set', 'Ang "Box 2 of 3" ay nagsasabi kung nasaan ang ibang box ng customer: nasa container pa, o nasa ibang container.'),
                    $s('A truck is waiting', 'The office opens the transfer trip (Trips → Transfers to other warehouses) and taps "🚚 The truck is here now". Then scan as always: a box for that warehouse shows a big orange TRUCK and is already loaded. It switches off when the trip is locked.', 'May truck na naghihintay', 'Bubuksan ng office ang transfer trip (Trips → Transfers to other warehouses) at pipindutin ang "🚚 The truck is here now". Tapos mag-scan gaya ng dati: ang box para sa warehouse na iyon ay may malaking orange na TRUCK at naka-load na. Mag-o-off ito kapag ni-lock ang trip.'),
                    $s('Many phones at once', 'Several people can scan the same container or truck. The counter is shared; a box already scanned by someone else is not counted again.', 'Sabay-sabay ang maraming phone', 'Puwedeng sabay-sabay mag-scan ang ilang tao sa iisang container o truck. Iisa ang bilang; hindi na binibilang ulit ang box na na-scan na ng iba.'),
                ],
                'result_en' => 'Every box is in its section or on its truck, and a customer\'s boxes stay together.',
                'result_tl' => 'Nasa tamang seksyon o truck ang bawat box, at magkakasama ang mga box ng isang customer.',
                'problems' => [
                    $p('It says Wrong hub when loading', 'The box is for another partner hub than this trip. Put it back in its section and tell the office.', 'Sabi ay Wrong hub sa loading', 'Ang box ay para sa ibang partner hub. Ibalik sa seksyon nito at sabihan ang office.'),
                    $p('Customers missing boxes at the end', 'On the Done screen, find the boxes, or pick why each one stays behind (not arrived, damaged, cannot find, truck full).', 'May customer na kulang ang box sa dulo', 'Sa Done screen, hanapin ang box, o piliin kung bakit naiwan (wala pa, sira, hindi makita, puno ang truck).'),
                ],
                'pages' => ['pages.warehouse-sections', 'pages.scaninvoice', 'pages.unloadedcontainer'],
                'links' => ['admin' => 'pages.warehouse-sections'],
                'related' => ['unload-container', 'load-truck'], 'sort' => 25,
            ],
            // ───────────────────────────── sea shipments ─────────────────────────────
            [
                'slug' => 'sea-shipments', 'topic' => 'trucks', 'icon' => '🚢', 'apps' => ['admin', 'warehouse', 'company', 'scan'],
                'title_en' => 'Sea shipments to Visayas and Mindanao', 'title_tl' => 'Sea shipment papuntang Visayas at Mindanao',
                'summary_en' => 'A normal trip to the port, then the van and seal, the port check, the ship, and receiving at the partner hub. Container now, RoRo later.',
                'summary_tl' => 'Normal na trip papuntang port, tapos ang van at seal, port check, barko, at pag-receive sa partner hub. Container ngayon, RoRo sa susunod.',
                'when_en' => 'Every container or RoRo truck going to a partner hub by sea.',
                'when_tl' => 'Bawat container o RoRo truck na papunta sa partner hub sa dagat.',
                'steps' => [
                    $s('Make the trip and the shipment', 'Make a normal trip to the partner hub with its boxes (Delivery Log). Then Sea shipments → pick the trip → Make shipment.', 'Gawin ang trip at shipment', 'Gumawa ng normal na trip papunta sa partner hub kasama ang mga box (Delivery Log). Tapos Sea shipments → piliin ang trip → Make shipment.'),
                    $s('Load and seal', 'Scan app → Load truck: sets and wrong hub are checked. Type the seal number and press "Mark: Loaded & sealed".', 'I-load at i-seal', 'Scan app → Load truck: tinitingnan ang set at wrong hub. I-type ang seal number at pindutin ang "Mark: Loaded & sealed".'),
                    $s('Port check', 'Full scan (Scan app → Port check), count only with a photo of the receipt, or off with a reason.', 'Port check', 'Full scan (Scan app → Port check), bilang lang kasama ang picture ng resibo, o off na may dahilan.'),
                    $s('Ship details', 'Type the vessel, BL and ETA and press "Mark: Sailed". The receiver sees "On the way by sea".', 'Detalye ng barko', 'I-type ang vessel, BL at ETA at pindutin ang "Mark: Sailed". Makikita ng receiver ang "On the way by sea".'),
                    $s('Receive at the hub', 'Partner hub: Scan app → Receive container, then Incoming shipments → Finish receiving. Missing boxes get an Invoice Issue; boxes for another hub go to Wrong hub & returns.', 'I-receive sa hub', 'Partner hub: Scan app → Receive container, tapos Incoming shipments → Finish receiving. Ang nawawalang box ay may Invoice Issue; ang box ng ibang hub ay nasa Wrong hub & returns.'),
                ],
                'result_en' => 'You know where every box is from the warehouse to the hub, and what the shipment cost per box.',
                'result_tl' => 'Alam mo kung nasaan ang bawat box mula bodega hanggang hub, at magkano ang gastos bawat box.',
                'problems' => [
                    $p('The hub cannot load a box on its truck', 'The box is still on a sea shipment that was not received. Receive the container first.', 'Hindi ma-load ng hub ang box', 'Nasa sea shipment pa ang box na hindi pa na-receive. I-receive muna ang container.'),
                    $p('"Not handed over at the port"', 'Fewer boxes at the port than left the warehouse. Check the truck now; with a full scan the app lists which ones.', '"Not handed over at the port"', 'Mas kaunti ang box sa port kaysa umalis sa bodega. Tingnan agad ang truck; sa full scan, ililista ng app kung alin.'),
                ],
                'pages' => ['pages.sea-shipments', 'pages.sea-shipment', 'pages.incoming-shipments', 'pages.wrong-hub'],
                'links' => ['admin' => 'pages.sea-shipments', 'warehouse' => 'pages.sea-shipments', 'company' => 'pages.incoming-shipments'],
                'related' => ['warehouse-sections', 'load-truck'], 'sort' => 45,
            ],
            [
                'slug' => 'section-count', 'topic' => 'boxes', 'icon' => '🔢', 'apps' => ['warehouse', 'scan'],
                'title_en' => 'Count a section and move boxes', 'title_tl' => 'Bilangin ang seksyon at ilipat ang box',
                'summary_en' => 'Scan every box on a section. A box in the wrong place is moved to this section; boxes not found are listed.',
                'summary_tl' => 'I-scan ang bawat box sa seksyon. Ang box na nasa maling lugar ay ililipat dito; ililista ang hindi nakita.',
                'when_en' => 'Once a week, or when a box cannot be found.',
                'when_tl' => 'Minsan sa isang linggo, o kapag may box na hindi makita.',
                'steps' => [
                    $s('Pick the section', 'Scan app → Count a section → pick it. Several phones can count the same section.', 'Piliin ang seksyon', 'Scan app → Count a section → piliin. Puwedeng sabay-sabay ang ilang phone.'),
                    $s('Scan every box', 'Scan each box on the section. "Moved to section D" means it was somewhere else in the system: now it is here.', 'I-scan ang bawat box', 'I-scan ang bawat box sa seksyon. Ang "Moved to section D" ay nasa ibang lugar sa system: dito na ngayon.'),
                    $s('Close the count', 'Press Done: the boxes not found are listed. Look for them, then press Close the count.', 'Isara ang bilang', 'Pindutin ang Done: nakalista ang hindi nakita. Hanapin, tapos pindutin ang Close the count.'),
                ],
                'result_en' => 'The system knows where every box is. Warehouse → Sections → Find a box shows it.',
                'result_tl' => 'Alam ng system kung nasaan ang bawat box. Warehouse → Sections → Find a box ang magpapakita.',
                'problems' => [],
                'pages' => ['pages.sections'], 'links' => ['warehouse' => 'pages.sections'],
                'related' => ['warehouse-sections'], 'sort' => 26,
            ],
            [
                'slug' => 'return-shipments', 'topic' => 'boxes', 'icon' => '↩️', 'apps' => ['company', 'warehouse', 'admin', 'scan'],
                'title_en' => 'Send boxes back to the warehouse', 'title_tl' => 'Ibalik ang mga box sa bodega',
                'summary_en' => 'Returns and wrong-hub boxes go on a return shipment (RET-0001). The warehouse scans them in; then they are back in the pool, in their section.',
                'summary_tl' => 'Ang returns at wrong-hub na box ay ilalagay sa return shipment (RET-0001). I-scan ng bodega pagdating; saka lang sila babalik sa pool, sa tamang seksyon.',
                'when_en' => 'A box is refused, the receiver moved, or the box belongs to a Luzon area.',
                'when_tl' => 'Ayaw tanggapin ang box, lumipat ang receiver, o ang box ay para sa Luzon.',
                'steps' => [
                    $s('Put it on the return shipment', 'Partner hub: Wrong hub & returns → Back to warehouse. The box goes on this hub\'s return shipment.', 'Ilagay sa return shipment', 'Partner hub: Wrong hub & returns → Back to warehouse. Mapupunta ang box sa return shipment ng hub.'),
                    $s('Send it', 'Tab Return shipment: van, seal, vessel, ETA and cost, then Mark: Sent to the warehouse.', 'Ipadala', 'Tab Return shipment: van, seal, vessel, ETA at gastos, tapos Mark: Sent to the warehouse.'),
                    $s('Receive at the warehouse', 'Scan app → Receive returns: scan each box. The app shows its section. Then Boxes coming back → Finish receiving.', 'I-receive sa bodega', 'Scan app → Receive returns: i-scan ang bawat box. Ipapakita ng app ang seksyon. Tapos Boxes coming back → Finish receiving.'),
                ],
                'result_en' => 'The box is back in the pool to be delivered again. A box that did not arrive gets an Invoice Issue.',
                'result_tl' => 'Balik sa pool ang box para i-deliver ulit. Ang hindi dumating ay may Invoice Issue.',
                'problems' => [],
                'pages' => ['pages.wrong-hub', 'pages.coming-back'], 'links' => ['company' => 'pages.wrong-hub', 'warehouse' => 'pages.coming-back'],
                'related' => ['sea-shipments'], 'sort' => 46,
            ],
            [
                'slug' => 'receive-truck', 'topic' => 'boxes', 'icon' => '📥', 'apps' => ['company', 'scan'],
                'title_en' => 'Receive the truck from Manila', 'title_tl' => 'I-receive ang truck galing Manila',
                'summary_en' => 'Partner hubs reached by truck scan every box in when the truck arrives. Boxes not scanned get a Missing box issue the same day.',
                'summary_tl' => 'Ang partner hub na naaabot ng truck ay mag-i-scan ng bawat box pagdating ng truck. Ang hindi na-scan ay may Missing box issue sa araw ding iyon.',
                'when_en' => 'Every truck from Manila that brings boxes to your hub. Sea shipments use Receive container instead.',
                'when_tl' => 'Bawat truck galing Manila na may box para sa hub. Ang sea shipment ay sa Receive container.',
                'steps' => [
                    $s('Pick the truck', 'Scan app → Receive truck → pick the trip that arrived.', 'Piliin ang truck', 'Scan app → Receive truck → piliin ang trip na dumating.'),
                    $s('Scan each box', 'Scan every box as it comes off. Take the photo if the app asks. Many phones can scan at once.', 'I-scan ang bawat box', 'I-scan ang bawat box pagbaba. Kumuha ng litrato kung hihingin. Puwedeng sabay-sabay ang maraming phone.'),
                    $s('Finish receiving', 'Tap Done, check the boxes not scanned, then Finish receiving. Each missing box gets a Missing box issue.', 'Finish receiving', 'Pindutin ang Done, tingnan ang hindi na-scan, tapos Finish receiving. May Missing box issue ang bawat kulang.'),
                ],
                'result_en' => 'Manila sees "Received by your hub" on the trip, with the missing boxes.',
                'result_tl' => 'Makikita ng Manila ang "Received by" sa trip, kasama ang mga kulang.',
                'problems' => [
                    $p('It says Not on this truck', 'The box is on another trip. Keep it apart and tell the office.', 'Sabi ay Not on this truck', 'Nasa ibang trip ang box. Ihiwalay at sabihan ang office.'),
                    $p('It says Use Receive container', 'The box came on a sea shipment. Receive it with Receive container.', 'Sabi ay Use Receive container', 'Galing sa sea shipment ang box. I-receive sa Receive container.'),
                ],
                'pages' => [], 'links' => [],
                'related' => ['sea-shipments'], 'sort' => 47,
            ],
            [
                'slug' => 'side-menu', 'topic' => 'apps', 'icon' => '🧭', 'apps' => ['admin', 'warehouse', 'company'],
                'title_en' => 'Find your way in the side menu', 'title_tl' => 'Paano hanapin ang page sa side menu',
                'summary_en' => 'The menu is grouped by the work of the day. Some pages have a new, clearer name; nothing was removed.',
                'summary_tl' => 'Naka-grupo ang menu ayon sa trabaho sa araw. May ilang page na may bago at mas malinaw na pangalan; walang tinanggal.',
                'when_en' => 'You cannot find a page you used before.',
                'when_tl' => 'Hindi mo makita ang page na ginagamit mo dati.',
                'steps' => [
                    $s('Open the group', 'Click a group name (Boxes, Trips, Settings · …) to open or close it. The menu remembers what you closed.', 'Buksan ang grupo', 'I-click ang pangalan ng grupo (Boxes, Trips, Settings · …) para buksan o isara. Tatandaan ng menu ang isinara mo.'),
                    $s('New names', 'Search Invoice → Find a box · Invoice Issue → Box issues · Deliverylogs → Delivery trips · WH Delivery Logs → Transfers to other warehouses · Logistichubs → Logistic hubs · Panelcategories → Account types · Workpositions → Job positions · Vehicles → Trucks · Company Crew → Crew.', 'Mga bagong pangalan', 'Search Invoice → Find a box · Invoice Issue → Box issues · Deliverylogs → Delivery trips · WH Delivery Logs → Transfers to other warehouses · Logistichubs → Logistic hubs · Panelcategories → Account types · Workpositions → Job positions · Vehicles → Trucks · Company Crew → Crew.'),
                    $s('Warehouse truck scans', 'Hub Load Truck → Load delivery truck · Load Truck → Load transfer truck · Unload Truck → Receive transfer truck · Hub Return Boxes → Return boxes.', 'Truck scan sa bodega', 'Hub Load Truck → Load delivery truck · Load Truck → Load transfer truck · Unload Truck → Receive transfer truck · Hub Return Boxes → Return boxes.'),
                ],
                'result_en' => 'A number beside a page shows what waits there (sea shipments on the way, wrong-hub boxes, boxes coming back).',
                'result_tl' => 'Ang numero sa tabi ng page ay ang naghihintay doon (sea shipment na papunta, wrong-hub na box, box na pabalik).',
                'problems' => [],
                'pages' => [], 'links' => [],
                'related' => [], 'sort' => 1,
            ],
        ];
    }
}
DISPATCH_FILE_END_7

# ---------------------------------------------------------------- app/Support/ScanModes.php
mkdir -p 'app/Support'
cat > 'app/Support/ScanModes.php' <<'DISPATCH_FILE_END_8'
<?php

namespace App\Support;

use App\Filament\Company\Pages\LoadTruck as HubLoadTruck;
use App\Filament\Company\Pages\ReturnBoxes as HubReturnBoxesCompany;
use App\Filament\Pages\ReturnBoxes as AdminReturnBoxes;
use App\Filament\Pages\Scaninvoice as AdminUnload;
use App\Filament\Pages\Scanload as AdminLoad;
use App\Filament\Warehouse\Pages\Hubloaded as WarehouseLoad;
use App\Filament\Warehouse\Pages\HubReturnBoxes as WarehouseReturn;
use App\Filament\Warehouse\Pages\Unloadedcontainer as WarehouseUnload;
use App\Filament\Warehouse\Pages\Whloaded;
use App\Filament\Warehouse\Pages\Whunloaded;
use App\Filament\Shared\Shipping\PortCheckStation;
use App\Filament\Shared\Shipping\ReceiveShipmentStation;
use App\Models\User;

/**
 * Which scans a person gets in the Scan app, from the account type set on the user.
 * Each scan reuses an existing scan page (its rules, limits and photo step) behind the scenes.
 */
class ScanModes
{
    /** @return array<string, array{label: string, sub: string, icon: string, class: class-string, field: string, kind: string, ok: string, done: string}> */
    public static function for(?User $user): array
    {
        $code = $user?->panelcategory?->code;

        $unload = ['label' => 'Unload container', 'sub' => 'Boxes off the ship container', 'icon' => 'container', 'field' => 'container_id', 'kind' => 'container', 'ok' => 'Verified · off the container', 'done' => 'Container unloaded'];
        $load = ['label' => 'Load truck', 'sub' => 'Onto a delivery trip', 'icon' => 'truck', 'field' => 'deliverylog_id', 'kind' => 'trip', 'ok' => 'Loaded on the truck', 'done' => 'Truck loaded'];
        $return = ['label' => 'Return boxes', 'sub' => 'Not delivered, back in', 'icon' => 'return', 'field' => 'deliverylog_id', 'kind' => 'trip', 'ok' => 'Returned to inventory', 'done' => 'Returns done'];
        $sea = \App\Support\Shipping\Shipments::ready();
        $port = ['label' => 'Port check', 'sub' => 'Boxes handed over at the port', 'icon' => 'out', 'field' => 'sea_shipment_id', 'kind' => 'shipment', 'ok' => 'Handed over at the port', 'done' => 'Port check done', 'class' => PortCheckStation::class];
        $count = ['label' => 'Count a section', 'sub' => 'Check a section, move boxes into it', 'icon' => 'container', 'field' => 'wh_section_id', 'kind' => 'section', 'ok' => 'Counted', 'done' => 'Section counted', 'class' => \App\Filament\Shared\SectionCountStation::class];
        $retReceive = ['label' => 'Receive returns', 'sub' => 'Boxes coming back from a hub', 'icon' => 'in', 'field' => 'return_shipment_id', 'kind' => 'return shipment', 'ok' => 'Back at the warehouse', 'done' => 'Returns received', 'class' => \App\Filament\Shared\Shipping\ReturnReceiveStation::class];
        $receive = ['label' => 'Receive container', 'sub' => 'Sea shipment arriving at your hub', 'icon' => 'in', 'field' => 'sea_shipment_id', 'kind' => 'shipment', 'ok' => 'Received at your hub', 'done' => 'Container received', 'class' => ReceiveShipmentStation::class];

        return match ($code) {
            'whse' => [
                'unload' => $unload + ['class' => WarehouseUnload::class],
                'load' => $load + ['class' => WarehouseLoad::class],
                'wh_load' => ['label' => 'Warehouse load', 'sub' => 'To another warehouse', 'icon' => 'out', 'field' => 'deliverylog_id', 'kind' => 'transfer trip', 'ok' => 'Loaded for the transfer', 'done' => 'Transfer loaded', 'class' => Whloaded::class],
                'wh_unload' => ['label' => 'Warehouse unload', 'sub' => 'Arriving from another warehouse', 'icon' => 'in', 'field' => 'deliverylog_id', 'kind' => 'arriving transfer', 'ok' => 'Received · added to inventory', 'done' => 'Transfer received', 'class' => Whunloaded::class],
                'return' => $return + ['class' => WarehouseReturn::class],
            ] + ($sea ? ['port' => $port] : []) + (\App\Support\Shipping\Returns::ready() ? ['ret_receive' => $retReceive] : []) + (\App\Support\Boxes\SectionCount::ready() && \App\Support\Boxes\Sections::used($user?->warehouse_id) ? ['count' => $count] : []),
            'co' => [
                'hub_load' => ['label' => 'Hub load', 'sub' => "Onto your hub's own trucks", 'icon' => 'truck', 'field' => 'deliverylog_id', 'kind' => 'hub trip', 'ok' => 'Loaded on the hub truck', 'done' => 'Hub truck loaded', 'class' => HubLoadTruck::class],
                'return' => $return + ['class' => HubReturnBoxesCompany::class, 'ok' => 'Back at your hub'],
            ] + static::hubReceive($user, $sea, $receive),
            'adm' => [
                'unload' => $unload + ['class' => AdminUnload::class],
                'load' => $load + ['class' => AdminLoad::class],
                'return' => $return + ['class' => AdminReturnBoxes::class],
            ] + ($sea ? ['port' => $port] : []),
            default => [],
        };
    }

    /**
     * Partner hub: Receive container for hubs reached by sea, Receive truck for hubs reached by truck
     * (Settings · Hubs · island & sea). The other one shows only while something is arriving that way.
     */
    protected static function hubReceive(?User $user, bool $sea, array $receive): array
    {
        $hubId = (int) $user?->logistichub_id;
        $bySea = \App\Support\Shipping\Islands::ready() && $hubId ? (bool) \App\Models\Logistichub::whereKey($hubId)->value('by_sea') : null;
        $out = [];
        if ($sea && ($bySea !== false || \App\Models\Shipping\SeaShipment::where('logistichub_id', $hubId)->whereIn('status', ['sailed', 'arrived', 'picked_up'])->exists())) {
            $out['ship_receive'] = $receive;
        }
        if (\App\Support\Shipping\TruckReceive::ready() && ($bySea !== true || \App\Support\Shipping\TruckReceive::trips($hubId)->isNotEmpty())) {
            $out['truck_receive'] = ['label' => 'Receive truck', 'sub' => 'Boxes from Manila arriving by truck', 'icon' => 'in', 'field' => 'deliverylog_id', 'kind' => 'truck',
                'ok' => 'Received at your hub', 'done' => 'Truck received', 'class' => \App\Filament\Shared\Shipping\TruckReceiveStation::class];
        }

        return $out;
    }

    /** "Calgary Warehouse" or "Cebu Partner Hub" for the top of the app. */
    public static function place(?User $user): string
    {
        return match ($user?->panelcategory?->code) {
            'whse' => $user->warehouse?->name ?? 'Warehouse',
            'co' => $user->logistichub?->hub_name ?? 'Partner hub',
            'adm' => $user->logistichub?->hub_name ?? 'Main office',
            default => '',
        };
    }
}
DISPATCH_FILE_END_8

# ---------------------------------------------------------------- app/Support/Shipping/TruckReceive.php
mkdir -p 'app/Support/Shipping'
cat > 'app/Support/Shipping/TruckReceive.php' <<'DISPATCH_FILE_END_9'
<?php

namespace App\Support\Shipping;

use App\Models\Boxissue;
use App\Models\Deliverylog;
use App\Models\Invoice;
use App\Models\Invoiceissue;
use App\Models\Shipping\SeaShipment;
use App\Models\Shipping\TruckReceipt;
use App\Models\Shipping\TruckReceiptScan;
use App\Models\Shipping\WrongHubBox;
use App\Models\Tripinvoice;
use App\Models\User;
use App\Support\Boxes\BoxSets;
use Illuminate\Database\Eloquent\Builder;
use Illuminate\Support\Collection;
use Illuminate\Support\Facades\Auth;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Schema;
use Illuminate\Support\Str;

/**
 * Partner hub by truck (Baguio and other Luzon hubs): scan the boxes in when the truck from
 * Manila arrives, then Finish receiving. Boxes not scanned get a Missing box issue the same day.
 * Sea shipments are received with Receive container instead, so a box is never scanned in twice.
 */
class TruckReceive
{
    public static function ready(): bool
    {
        static $ready;

        return $ready ??= Schema::hasTable('truck_receipts');
    }

    /** Trips that went to the port as a sea shipment (received with Receive container). */
    public static function seaTripIds(): Builder|array
    {
        return Shipments::ready() ? SeaShipment::query()->select('deliverylog_id') : [];
    }

    /** Boxes of this trip for this hub, scanned onto the truck in Manila. */
    public static function rows(int $tripId, int $hubId): Builder
    {
        return Tripinvoice::query()->where('deliverylog_id', $tripId)->where('logistichub_id', $hubId)->where('is_loaded', true);
    }

    /** Trucks arriving at this hub, not received yet. */
    public static function trips(?int $hubId): Collection
    {
        if (! $hubId || ! static::ready()) {
            return collect();
        }
        $done = TruckReceipt::where('logistichub_id', $hubId)->whereNotNull('finished_at')->pluck('deliverylog_id');

        return Deliverylog::with('truck:id,plate_no')
            ->whereIn('id', Tripinvoice::where('logistichub_id', $hubId)->where('is_loaded', true)
                ->where(fn ($q) => $q->where('is_delivered', false)->orWhereNull('is_delivered'))->select('deliverylog_id'))
            ->whereNotIn('id', static::seaTripIds())
            ->whereNotIn('id', $done)
            ->where('created_at', '>=', now()->subDays(60))
            ->latest('id')->limit(40)->get();
    }

    /** @return array{got: int, of: int, missing: Collection} */
    public static function counts(int $tripId, int $hubId): array
    {
        $rows = static::rows($tripId, $hubId)->get(['invoice_id', 'invoice', 'loaded_by', 'loaded_at']);
        $got = TruckReceiptScan::where('deliverylog_id', $tripId)->whereIn('invoice_id', $rows->pluck('invoice_id'))->pluck('invoice_id')->all();

        return ['got' => count($got), 'of' => $rows->count(), 'missing' => $rows->reject(fn ($r) => in_array($r->invoice_id, $got, true))->values()];
    }

    public static function receipt(int $tripId, int $hubId): ?TruckReceipt
    {
        return TruckReceipt::where('deliverylog_id', $tripId)->where('logistichub_id', $hubId)->first();
    }

    /** Scan one box in. Returns the scan, or null when it was already scanned. */
    public static function scan(int $tripId, int $hubId, Tripinvoice $row): ?TruckReceiptScan
    {
        $scan = TruckReceiptScan::firstOrCreate(['deliverylog_id' => $tripId, 'invoice_id' => $row->invoice_id],
            ['logistichub_id' => $hubId, 'user_id' => Auth::id(), 'created_at' => now()]);
        TruckReceipt::firstOrCreate(['deliverylog_id' => $tripId, 'logistichub_id' => $hubId]);

        return $scan->wasRecentlyCreated ? $scan : null;
    }

    /** The box's section is for another partner hub: put it on the Wrong hub & returns list. */
    public static function checkWrongHub(int $hubId, Tripinvoice $row): ?WrongHubBox
    {
        $section = $row->invdata?->whSection;
        if (! $section?->logistichub_id || (int) $section->logistichub_id === $hubId) {
            return null;
        }

        return WrongHubBox::firstOrCreate(['invoice_id' => $row->invoice_id, 'logistichub_id' => $hubId, 'status' => 'waiting'], [
            'tripinvoice_id' => $row->id, 'correct_hub_id' => $section->logistichub_id, 'reason' => 'wrong_hub', 'created_by' => Auth::id(),
        ]);
    }

    /** Finish receiving: every box not scanned gets a Missing box issue. Returns how many. */
    public static function finish(Deliverylog $trip, int $hubId, ?User $by = null): int
    {
        $by ??= Auth::user();
        $c = static::counts($trip->id, $hubId);
        $hub = \App\Models\Logistichub::find($hubId);
        $type = Boxissue::firstOrCreate(['issue_type' => 'Missing box']);
        $made = 0;
        DB::transaction(function () use ($c, $trip, $hubId, $hub, $type, $by, &$made) {
            foreach ($c['missing'] as $row) {
                $exists = Invoiceissue::where('invoice_id', $row->invoice_id)->where('boxissue_id', $type->id)->where('remarks', 'like', '%trip '.$trip->trip_number.'%')->exists();
                if (! $exists) {
                    Invoiceissue::create(['invoice' => $row->invoice, 'invoice_id' => $row->invoice_id, 'container_id' => Invoice::whereKey($row->invoice_id)->value('container_id'),
                        'boxissue_id' => $type->id, 'remarks' => 'Not on trip '.$trip->trip_number.' when '.($hub?->hub_name ?? 'the hub').' received the truck.', 'user_id' => $by?->id]);
                    $made++;
                }
            }
            TruckReceipt::updateOrCreate(['deliverylog_id' => $trip->id, 'logistichub_id' => $hubId],
                ['finished_at' => now(), 'finished_by' => $by?->id, 'missing' => $c['missing']->count()]);
        });

        return $made;
    }

    /** The customer's boxes at the hub: "1 of 2 received · 1 more on this truck". */
    public static function setAtHub(int $tripId, int $hubId, Invoice $invoice): ?array
    {
        $all = BoxSets::members($invoice);
        if ($all->count() < 2) {
            return null;
        }
        $ids = $all->pluck('id');
        $onTruck = static::rows($tripId, $hubId)->whereIn('invoice_id', $ids)->pluck('invoice_id')->all();
        $got = TruckReceiptScan::where('deliverylog_id', $tripId)->whereIn('invoice_id', $ids)->count();
        $toScan = count($onTruck) - $got;
        $notHere = $all->reject(fn ($b) => in_array($b->id, $onTruck, true))->count();
        $parts = [];
        if ($toScan > 0) {
            $parts[] = $toScan.' more on this truck';
        }
        if ($notHere > 0) {
            $parts[] = $notHere.' not on this truck (still in Manila or on another trip)';
        }

        return ['n' => $got, 'of' => $all->count(), 'name' => Str::title((string) $invoice->receiver_name),
            'text' => $parts ? implode(' · ', $parts) : '✓ All '.$all->count().' boxes at your hub', 'kind' => $notHere ? 'split' : ($toScan ? 'wait' : 'done')];
    }
}
DISPATCH_FILE_END_9

# ---------------------------------------------------------------- database/migrations/2026_11_15_000032_create_truck_receipts.php
mkdir -p 'database/migrations'
cat > 'database/migrations/2026_11_15_000032_create_truck_receipts.php' <<'DISPATCH_FILE_END_10'
<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

/** Partner hub by truck (Luzon): the hub scans the boxes in when the truck arrives (Scan app · Receive truck). */
return new class extends Migration
{
    public function up(): void
    {
        if (! Schema::hasTable('truck_receipts')) {
            Schema::create('truck_receipts', function (Blueprint $t) {
                $t->id();
                $t->foreignId('deliverylog_id');
                $t->foreignId('logistichub_id');
                $t->timestamp('finished_at')->nullable();
                $t->foreignId('finished_by')->nullable();
                $t->unsignedInteger('missing')->default(0);
                $t->timestamps();
                $t->unique(['deliverylog_id', 'logistichub_id']);
            });
        }
        if (! Schema::hasTable('truck_receipt_scans')) {
            Schema::create('truck_receipt_scans', function (Blueprint $t) {
                $t->id();
                $t->foreignId('deliverylog_id');
                $t->foreignId('logistichub_id');
                $t->foreignId('invoice_id');
                $t->foreignId('user_id')->nullable();
                $t->timestamp('created_at')->nullable();
                $t->unique(['deliverylog_id', 'invoice_id']);
            });
        }

        // New help guides (Receive truck, and Find your way in the side menu).
        \App\Support\Help\Help::installDefaults();
    }

    public function down(): void
    {
        Schema::dropIfExists('truck_receipt_scans');
        Schema::dropIfExists('truck_receipts');
    }
};
DISPATCH_FILE_END_10

# ---------------------------------------------------------------- resources/views/filament/scan/app.blade.php
mkdir -p 'resources/views/filament/scan'
cat > 'resources/views/filament/scan/app.blade.php' <<'DISPATCH_FILE_END_11'
@php
    $ring = fn (int $done, int $total, int $len = 289) => $len - ($total > 0 ? round($len * min($done, $total) / $total) : 0);
    $condOrder = array_keys($conditions);
@endphp
<x-filament-panels::page>
<div class="ds-sa" x-data x-on:scan-app-result.window="if (navigator.vibrate) navigator.vibrate($event.detail.status === 'success' ? 60 : [80, 60, 80])">

    {{-- ============================== start ============================== --}}
    @if ($screen === 'home')
        <section class="ds-sa__screen ds-sa__home" wire:key="home">
            <header class="ds-sa__hello">
                <span><small>{{ $place }}</small><strong>{{ $greeting }}, {{ $firstName }}</strong></span>
                <button type="button" class="ds-sa__help" x-on:click="$dispatch('open-help', { slug: 'scan-tips' })" aria-label="Help">?</button>
                <span class="ds-sa__avatar">{{ $initials }}</span>
            </header>

            <div class="ds-sa__today">
                <span class="ds-sa__ring">
                    <svg viewBox="0 0 110 110"><circle cx="55" cy="55" r="46" class="is-track"/><circle cx="55" cy="55" r="46" class="is-fill" style="stroke-dashoffset: {{ $ring(min($today['scans'], 500), 500) }}"/></svg>
                    <span><strong>{{ $today['scans'] }}</strong><small>today</small></span>
                </span>
                <dl>
                    <dt>Boxes scanned</dt><dd>{{ number_format($today['scans']) }}</dd>
                    <dt>Photos</dt><dd>{{ number_format($today['photos']) }}</dd>
                    <dt>Problems</dt><dd class="is-bad">{{ $today['problems'] }}</dd>
                </dl>
            </div>

            @if ($modes)
                <p class="ds-sa__label">Start scanning</p>
                <div class="ds-sa__list">
                    @foreach ($modes as $key => $m)
                        <button type="button" class="ds-sa__row" wire:click="open('{{ $key }}')">
                            <span class="ds-sa__chip">@include('filament.scan.icon', ['name' => $m['icon']])</span>
                            <span class="ds-sa__rowtext"><strong>{{ $m['label'] }}</strong><small>{{ $m['sub'] }}</small></span>
                            @php($w = $waiting[$key] ?? 0)
                            <span @class(['ds-sa__waiting', 'is-none' => ! $w])>{{ $w ? $w.' waiting' : 'All done' }}</span>
                            <span class="ds-sa__chev" aria-hidden="true">›</span>
                        </button>
                    @endforeach
                </div>
            @else
                <div class="ds-sa__note">Your account can't scan here. Ask the office to set your account to Warehouse or Company.</div>
            @endif

            <footer class="ds-sa__foot">
                <span class="ds-sa__online"><i></i>Online · every scan is saved</span>
                <span class="ds-sa__footlinks">
                    <button type="button" class="ds-pwa-install" onclick="window.dsInstallApp && window.dsInstallApp()">Install app</button>
                    <form method="POST" action="{{ filament()->getLogoutUrl() }}">@csrf<button type="submit">Sign out</button></form>
                </span>
            </footer>
        </section>
    @endif

    {{-- ============================== pick ============================== --}}
    @if ($screen === 'pick' && $def)
        <section class="ds-sa__screen ds-sa__pick" wire:key="pick-{{ $this->mode }}">
            <button type="button" class="ds-sa__pill" wire:click="home"><span aria-hidden="true">‹</span> Back</button>
            <header class="ds-sa__title ds-sa__title--help"><span><small>{{ $def['label'] }}</small><strong>Choose the {{ $def['kind'] }}</strong></span><button type="button" class="ds-sa__help" x-on:click="$dispatch('open-help', { slug: '{{ \App\Support\Help\Help::forScanMode($this->mode) }}' })" aria-label="Help">?</button></header>

            @forelse ($choices as $i => $c)
                <button type="button" @class(['ds-sa__choice', 'is-finished' => $c['finished']]) style="animation-delay: {{ $i * 50 }}ms" wire:click="pick({{ $c['id'] }})" wire:key="c-{{ $c['id'] }}">
                    <span class="ds-sa__choicetext">
                        <strong>{{ $c['name'] }}</strong>
                        @if ($c['sub'])<small>{{ $c['sub'] }}</small>@endif
                        <small class="is-num">{{ $c['done'] }} of {{ $c['total'] }} scanned{{ $c['finished'] ? (($c['active'] ?? true) ? ' · finished' : ' · closed') : '' }}</small>
                    </span>
                    <span class="ds-sa__ring is-small">
                        <svg viewBox="0 0 110 110"><circle cx="55" cy="55" r="46" class="is-track"/><circle cx="55" cy="55" r="46" class="is-fill" style="stroke-dashoffset: {{ $ring($c['done'], $c['total']) }}"/></svg>
                        <span><b>{{ $c['total'] ? round($c['done'] / $c['total'] * 100) : 0 }}%</b></span>
                    </span>
                </button>
            @empty
                <div class="ds-sa__note">Nothing left to scan for {{ strtolower($def['label']) }}. Everything open is 100% scanned.</div>
            @endforelse

            @if ($finishedCount)
                <button type="button" class="ds-sa__more" wire:click="toggleFinished">
                    {{ $showFinished ? 'Hide finished' : 'Show finished ('.$finishedCount.')' }}
                </button>
            @endif
        </section>
    @endif

    {{-- ============================== scan ============================== --}}
    @if ($screen === 'scan' && $def)
        <section class="ds-sa__screen ds-sa__scan" wire:key="scan-{{ $this->mode }}-{{ $choice }}">
            @if ($aiFlag)
                <div class="ds-sa__aiflag" wire:key="aiflag-{{ $aiFlag->id }}">
                    <span class="ds-sa__aibadge">AI</span>
                    <span><b>{{ $aiFlag->invoice }} looks {{ strtolower($aiFlag->label()) }}?</b><small>{{ $aiFlag->note }}</small></span>
                    <button type="button" wire:click="aiFlagAnswer({{ $aiFlag->id }}, true)">Yes, mark it</button>
                    <button type="button" class="is-plain" wire:click="aiFlagAnswer({{ $aiFlag->id }}, false)">It's fine</button>
                </div>
            @elseif ($aiPending)
                <span wire:poll.8s class="hidden"></span>
            @endif
            <div class="ds-sa__cam" wire:ignore
                 x-data="barcodeScanner(@js(['method' => 'scan', 'formats' => ['code_128', 'code_39', 'ean_13', 'ean_8', 'upc_a', 'itf', 'qr_code'], 'autoStart' => true, 'continuous' => true, 'cooldown' => 2500, 'beep' => true]))">
                <video x-ref="video" playsinline muted autoplay></video>
                <div class="ds-sa__frame" x-bind:class="{ 'is-hit': flash }"><i></i><i></i><i></i><i></i><span x-show="scanning" class="ds-sa__sweep"></span></div>
                <p class="ds-sa__camtext" x-show="loading" x-cloak>Starting camera…</p>
                <p class="ds-sa__camtext" x-show="! scanning && ! loading && ! error">Camera is off · tap the round button</p>
                <p class="ds-sa__camtext is-error" x-show="error" x-text="error" x-cloak></p>
                <p class="ds-sa__camtext is-hint" x-show="hint && ! error" x-text="hint" x-cloak></p>

                <div class="ds-sa__controls">
                    <label class="ds-sa__type">
                        <input type="text" x-model="manualCode" x-on:keydown.enter.prevent="submitManual()" placeholder="Type or use a handheld scanner" autocomplete="off" autocapitalize="characters" spellcheck="false" enterkeyhint="go" aria-label="Box number">
                        <button type="button" x-on:click="submitManual()" aria-label="Find">→</button>
                    </label>
                    <div class="ds-sa__buttons">
                        <button type="button" class="ds-sa__round" x-show="torchSupported && scanning" x-on:click="toggleTorch()" x-bind:class="{ 'is-on': torchOn }" aria-label="Flashlight" x-cloak>
                            <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M9 2h6l-1 6h-4zM10 8h4v12a2 2 0 0 1-4 0z"/></svg>
                        </button>
                        <button type="button" class="ds-sa__shutter" x-on:click="toggle()" x-bind:aria-label="scanning ? 'Stop camera' : 'Start camera'">
                            <span x-bind:class="{ 'is-live': scanning }"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><path d="M4 8V5a1 1 0 0 1 1-1h3M16 4h3a1 1 0 0 1 1 1v3M20 16v3a1 1 0 0 1-1 1h-3M8 20H5a1 1 0 0 1-1-1v-3M7 12h10"/></svg></span>
                        </button>
                        <button type="button" class="ds-sa__round is-text" wire:click="finish">Done</button>
                    </div>
                </div>
            </div>

            <header class="ds-sa__bar">
                <button type="button" class="ds-sa__back" wire:click="back" aria-label="Back">‹</button>
                <span class="ds-sa__bartext"><small>{{ $def['label'] }}</small><strong>{{ $target['name'] ?? '' }}{{ ! empty($target['sub']) ? ' · '.$target['sub'] : '' }}</strong></span>
                <span class="ds-sa__ring is-tiny">
                    <svg viewBox="0 0 110 110"><circle cx="55" cy="55" r="46" class="is-track"/><circle cx="55" cy="55" r="46" class="is-fill" style="stroke-dashoffset: {{ $ring($progress['loaded'] ?? 0, $progress['total'] ?? 0) }}"/></svg>
                </span>
                <span class="ds-sa__count"><strong>{{ $progress['loaded'] ?? 0 }}</strong><small>of {{ $progress['total'] ?? 0 }}</small>@if ($space)<small class="ds-sa__space">{{ \App\Support\BoxSizes::fmt($space['loaded']) }}{{ $space['cap'] ? ' / '.$space['cap'] : '' }} space</small>@endif</span>
                <button type="button" class="ds-sa__help" x-on:click="$dispatch('open-help', { slug: '{{ \App\Support\Help\Help::forScanMode($this->mode) }}' })" aria-label="Help">?</button>
            </header>

            @if (count($team) > 1)
                <div class="ds-sx__team" aria-label="Who scanned">
                    @foreach (array_slice($team, 0, 4) as $m)<span @class(['is-me' => $m['me']])>{{ $m['name'] }} <b>{{ $m['n'] }}</b></span>@endforeach
                </div>
            @endif

            @if ($this->mode === 'unload' && $trucks)
                @foreach ($trucks as $tk)
                    <div class="ds-sx__here"><b>🚚 Truck to {{ $tk['to'] }} is here</b><span>{{ $tk['onTruck'] }} on truck</span></div>
                @endforeach
            @endif

            @if (! $status && $loadNext && $loadNext['stop'])
                @include('filament.partials.load-next', ['next' => $loadNext, 'dark' => true])
            @endif

            @if ($status === 'success' && $box)
                <div class="ds-sa__sheet is-ok" wire:key="ok-{{ $invoiceId }}-{{ $sessionScans }}">
                    <span class="ds-sa__grab"></span>
                    <div class="ds-sa__hit">
                        <span class="ds-sa__mark is-ok"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="3" stroke-linecap="round" stroke-linejoin="round"><path d="m5 12.5 4.5 4.5L19 7.5"/></svg></span>
                        <span><strong>{{ $box->invoice }}</strong><small>{{ $def['ok'] }}</small></span>
                        @if ($boxSize && $boxSize['space'] != 1)<em class="ds-sa__size">{{ $boxSize['name'] }} · takes {{ \App\Support\BoxSizes::fmt($boxSize['space']) }} space</em>@elseif ($box->boxtype)<em>{{ $box->boxtype }}</em>@endif
                    </div>
                    @if ($this->mode === 'count')<p class="ds-sa__msg">{{ $message }}</p>@endif
                    @if ($route)
                        <div @class(['ds-sx__tile', 'is-truck' => ($route['kind'] ?? '') === 'truck']) style="--sx: {{ $route['color'] ?? '#1d6fb8' }}">
                            <small>{{ ($route['kind'] ?? '') === 'truck' ? 'Carry this box to' : 'Put this box in' }}</small>
                            <strong>{{ ($route['kind'] ?? '') === 'truck' ? 'TRUCK' : $route['code'] }}</strong>
                            <span>{{ ($route['kind'] ?? '') === 'truck' ? $route['name'].(! empty($route['plate']) ? ' · '.$route['plate'] : '') : $route['name'] }}</span>
                            @if (($route['kind'] ?? '') === 'truck')<em>✓ Already loaded on trip {{ $route['trip'] }}. No need to scan it again.</em>@endif
                            @if (! empty($route['why']))<em>{{ $route['why'] }}</em>@endif
                            @if (! empty($route['pending']))<em>Then scan the QR on section {{ $route['code'] }}.</em>@endif
                        </div>
                        @if (($route['kind'] ?? '') === 'truck')
                            <button type="button" class="ds-sx__link" wire:click="putInSection">Put in section instead</button>
                        @endif
                    @endif
                    @if ($setInfo)
                        <div @class(['ds-sx__set', 'is-'.$setInfo['kind']])>
                            <span><b>{{ $setInfo['name'] }}</b> · box {{ $setInfo['n'] }} of {{ $setInfo['of'] }}</span>
                            <span class="ds-sx__dots">@for ($i = 1; $i <= min(12, $setInfo['of']); $i++)<i @class(['is-on' => $i <= $setInfo['n']])></i>@endfor</span>
                            <small>{{ $setInfo['text'] }}</small>
                            @if (! empty($setInfo['rows']))
                                <ul class="ds-sx__setrows">@foreach ($setInfo['rows'] as $sr)<li><span>{{ $sr['i'] }}</span>{{ $sr['t'] }}</li>@endforeach</ul>
                            @endif
                            @foreach ($setInfo['add'] ?? [] as $sa)
                                <button type="button" class="ds-sx__setadd" wire:click="addSetBox({{ $sa['id'] }})">Bring {{ $sa['invoice'] }} from section {{ $sa['section'] ?? '?' }} · add to truck</button>
                            @endforeach
                        </div>
                    @endif
                    @if ($spot)
                        <div class="ds-ld__spot is-{{ $spot['zone'] }}"><strong>{{ \App\Models\Maps\TripStop::ZONES[$spot['zone']] ?? '' }}</strong><span>Stop {{ $spot['stop'] }} · {{ ['front' => 'deep inside, next to the cab', 'middle' => 'in the middle', 'back' => 'near the door'][$spot['zone']] ?? '' }}</span></div>
                    @endif
                    <div class="ds-sa__who">
                        <span>{{ mb_strtoupper(mb_substr($box->receiver_name ?? '?', 0, 2)) }}</span>
                        <span><strong>{{ \Illuminate\Support\Str::title($box->receiver_name) }}</strong><small>{{ collect([$box->receiver_barangay, $box->receiver_city])->filter()->map(fn ($p) => \Illuminate\Support\Str::title($p))->join(', ') }}</small></span>
                    </div>

                    @if ($this->photosOn())
                        @php($ci = max(0, (int) array_search($condition ?? 'good', $condOrder, true)))
                        <div class="ds-sa__seg" role="group" aria-label="How does the box look?">
                            <span class="ds-sa__segthumb is-{{ $condition ?? 'good' }}" style="left: calc(4px + {{ $ci }} * (100% - 8px) / 4)"></span>
                            @foreach ($conditions as $key => $label)
                                <button type="button" wire:click="setCondition('{{ $key }}')" @class(['is-on' => ($condition ?? 'good') === $key]) aria-pressed="{{ ($condition ?? 'good') === $key ? 'true' : 'false' }}"><i class="is-{{ $key }}"></i>{{ $label }}</button>
                            @endforeach
                        </div>
                        @if (in_array($condition, ['damaged', 'wet', 'open'], true))
                            <input type="text" class="ds-sa__note-in" wire:model.blur="note" maxlength="250" placeholder="What is wrong? (optional)" aria-label="What is wrong?">
                        @endif

                        <div class="ds-sa__photos"
                             x-data="{ busy: false, failed: false, pct: 0,
                                take() { this.failed = false; this.$refs.file.value = ''; this.$refs.file.click() },
                                async send(e) {
                                    const file = e.target.files[0]; if (! file) return;
                                    this.busy = true; this.pct = 0; let out = file;
                                    out = window.dsShrinkPhoto ? await window.dsShrinkPhoto(file) : file;
                                    $wire.upload('boxPhoto', out, () => $wire.saveBoxPhoto().then(() => { this.busy = false }), () => { this.busy = false; this.failed = true }, (ev) => { this.pct = ev.detail.progress });
                                } }">
                            <input type="file" accept="image/*" capture="environment" x-ref="file" class="hidden" x-on:change="send($event)">
                            @foreach ($shots as $shot)
                                <a href="{{ $shot->url() }}" target="_blank" class="ds-sa__shot"><img src="{{ $shot->url() }}" alt="Photo {{ $loop->iteration }}"></a>
                            @endforeach
                            <button type="button" class="ds-sa__addphoto" x-on:click="take()" x-bind:disabled="busy">
                                <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M4 8h3l2-3h6l2 3h3v11H4z"/><circle cx="12" cy="13" r="3.5"/></svg>
                                <span x-show="! busy">{{ $shots->isEmpty() ? 'Add photo · optional' : 'Add another' }}</span>
                                <span x-show="busy" x-cloak>Saving… <span x-text="pct + '%'"></span></span>
                            </button>
                            <p class="ds-sa__err" x-show="failed" x-cloak>The photo did not upload. Try again.</p>
                        </div>
                    @endif
                    <button type="button" class="ds-sa__primary" wire:click="dismiss">Scan next box</button>
                </div>
            @elseif ($status === 'success' && $route)
                <div class="ds-sa__sheet is-ok" wire:key="placed-{{ $sessionScans }}">
                    <span class="ds-sa__grab"></span>
                    <div class="ds-sx__tile" style="--sx: {{ $route['color'] ?? '#1d6fb8' }}"><small>Saved in</small><strong>{{ $route['code'] }}</strong><span>{{ $route['name'] }}</span></div>
                    <p class="ds-sa__msg">{{ $message }}</p>
                    <button type="button" class="ds-sa__primary" wire:click="dismiss">Scan next box</button>
                </div>
            @elseif ($status === 'warning' && $wrongHub)
                <div class="ds-sa__sheet is-bad" wire:key="wronghub-{{ $sessionScans }}-{{ $wrongHub['code'] }}">
                    <span class="ds-sa__grab"></span>
                    <div class="ds-sa__hit is-shake">
                        <span class="ds-sa__mark is-bad">⛔</span>
                        <span><small class="ds-ld__kicker">Wrong hub</small><strong>{{ $wrongHub['code'] }} is for {{ $wrongHub['for'] }}</strong></span>
                    </div>
                    <p class="ds-sa__msg">This trip goes to {{ $wrongHub['trip'] }}. Not loaded. Put it back in section {{ $wrongHub['section'] }} and tell the office.</p>
                    <button type="button" class="ds-sa__primary" wire:click="dismiss">OK, put it back</button>
                    <button type="button" class="ds-sa__secondary" wire:click="loadAnyway">The office says load it</button>
                </div>
            @elseif ($status === 'warning' && $early)
                <div class="ds-sa__sheet is-warn" wire:key="early-{{ $sessionScans }}-{{ $early['code'] }}">
                    <span class="ds-sa__grab"></span>
                    <div class="ds-sa__hit">
                        <span class="ds-sa__mark is-warn">!</span>
                        <span><small class="ds-ld__kicker">Too early</small><strong>{{ $early['code'] }} is for stop {{ $early['stop'] }}{{ $early['place'] ? ' ('.$early['place'].')' : '' }}</strong></span>
                    </div>
                    <p class="ds-sa__msg">It's delivered earlier, so it goes in later, {{ $early['zone'] === 'back' ? 'at the door' : 'in the middle' }}. Put it aside and load stop {{ $early['nextStop'] }} now.</p>
                    <button type="button" class="ds-sa__primary" wire:click="dismiss">OK, put aside</button>
                    <button type="button" class="ds-sa__secondary" wire:click="loadAnyway">Load it anyway</button>
                </div>
            @elseif ($status === 'warning')
                <div class="ds-sa__sheet is-warn" wire:key="warn-{{ $sessionScans }}-{{ md5($message) }}">
                    <span class="ds-sa__grab"></span>
                    <div class="ds-sa__hit">
                        <span class="ds-sa__mark is-warn">!</span>
                        <span><strong>{{ $box?->invoice ?? 'Check this box' }}</strong><small>{{ $message }}</small></span>
                    </div>
                    <button type="button" class="ds-sa__secondary" wire:click="dismiss">OK, scan next</button>
                </div>
            @elseif ($status === 'danger')
                <div class="ds-sa__sheet is-bad" wire:key="bad-{{ $sessionScans }}-{{ md5($message) }}">
                    <span class="ds-sa__grab"></span>
                    <div class="ds-sa__hit is-shake">
                        <span class="ds-sa__mark is-bad"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="3" stroke-linecap="round"><path d="M6 6l12 12M18 6 6 18"/></svg></span>
                        <span><strong>{{ $missing ?? $box?->invoice ?? 'Wrong box' }}</strong><small>Not on this {{ $def['kind'] }}</small></span>
                    </div>
                    <p class="ds-sa__msg">{{ $message }}</p>
                    @if ($missing && $this->mode === 'unload')
                        {{ $this->unmanifestedAction }}
                    @endif
                    <button type="button" class="ds-sa__secondary" wire:click="dismiss">Keep it aside, scan next</button>
                </div>
            @endif
        </section>
    @endif

    {{-- ============================== done ============================== --}}
    @if ($screen === 'done' && $def)
        <section class="ds-sa__screen ds-sa__done" wire:key="done">
            <span class="ds-sa__ring is-big">
                <svg viewBox="0 0 110 110"><circle cx="55" cy="55" r="48" class="is-track"/><circle cx="55" cy="55" r="48" class="is-fill is-ok" style="stroke-dasharray: 302; stroke-dashoffset: {{ $ring($progress['loaded'] ?? 0, $progress['total'] ?? 0, 302) }}"/></svg>
                <span><i><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.6" stroke-linecap="round" stroke-linejoin="round"><path d="m5 12.5 4.5 4.5L19 7.5"/></svg></i></span>
            </span>
            @php($complete = ($progress['total'] ?? 0) > 0 && ($progress['loaded'] ?? 0) >= $progress['total'])
            <h2>{{ $complete ? $def['done'] : ($progress['loaded'] ?? 0).' of '.($progress['total'] ?? 0).' scanned' }}</h2>
            <p>{{ $target['name'] ?? '' }}{{ ! empty($target['sub']) ? ' · '.$target['sub'] : '' }}</p>
            <div class="ds-sa__totals">
                <span><strong>{{ $sessionScans }}</strong><small>scanned now</small></span>
                <span><strong>{{ $today['photos'] }}</strong><small>photos today</small></span>
                <span><strong class="is-bad">{{ $today['problems'] }}</strong><small>problems today</small></span>
            </div>
            <p class="ds-sa__note">{{ $complete ? 'Everything on this '.$def['kind'].' is scanned. The office sees it right away.' : 'You can come back and finish later; every scan is already saved.' }}</p>
            @if ($topUp && $topUp['room'] >= 1)
                <div class="ds-sx__topup">
                    <strong>Room for about {{ \App\Support\BoxSizes::fmt($topUp['room']) }} more on the truck</strong>
                    @forelse ($topUp['boxes'] as $tb)
                        <div class="ds-sx__toprow" wire:key="tu-{{ $tb['id'] }}">
                            <span><b>{{ $tb['invoice'] }} · {{ $tb['name'] }}</b><small>{{ $tb['place'] }}{{ $tb['section'] ? ' · section '.$tb['section'] : '' }}{{ $tb['space'] != 1 ? ' · takes '.\App\Support\BoxSizes::fmt($tb['space']) : '' }}</small></span>
                            <button type="button" wire:click="topUpAdd({{ $tb['id'] }})">Add</button>
                        </div>
                    @empty
                        <small>No waiting boxes for these provinces.</small>
                    @endforelse
                    <small>Waiting boxes for the same provinces, oldest and priority first. Add one, then scan it onto the truck.</small>
                </div>
            @endif
            @if ($receiveResult)
                <div class="ds-sx__open">
                    <strong>{{ $receiveResult['got'] }} of {{ $receiveResult['of'] }} boxes received</strong>
                    @if (count($receiveResult['missing']))
                        <span>{{ $receiveResult['of'] - $receiveResult['got'] }} not scanned:</span>
                        @foreach ($receiveResult['missing'] as $rm)
                            <span class="ds-sx__miss"><span>{{ $rm['code'] }} <small>{{ $rm['sub'] }}</small></span></span>
                        @endforeach
                        <small>Look in the truck once more. Found it? Keep scanning.</small>
                    @else
                        <span>✓ Every box arrived.</span>
                    @endif
                    @if ($receiveResult['finished'])
                        <span>✓ Receiving finished.</span>
                    @else
                        <button type="button" class="ds-sa__secondary" wire:click="finishReceiving" wire:confirm="Finish receiving? Boxes not scanned get a Missing box issue each.">Finish receiving</button>
                    @endif
                </div>
            @endif
            @if ($countResult)
                <div class="ds-sx__open">
                    <strong>Section {{ $countResult['code'] }}: {{ $countResult['found'] }} found{{ $countResult['moved'] ? ' · '.$countResult['moved'].' moved in' : '' }}</strong>
                    @if (count($countResult['missing']))
                        <span>{{ count($countResult['missing']) }} missing: {{ implode(', ', array_slice($countResult['missing'], 0, 12)) }}{{ count($countResult['missing']) > 12 ? '…' : '' }}</span>
                    @else
                        <span>✓ Nothing missing.</span>
                    @endif
                    <button type="button" class="ds-sa__secondary" wire:click="closeCount" wire:confirm="Close the count of section {{ $countResult['code'] }}?">Close the count</button>
                </div>
            @endif
            @if (count($openSets))
                @if ($noReason)<p class="ds-sx__stop">⛔ Not ready to leave: {{ $noReason }} {{ $noReason === 1 ? 'customer has' : 'customers have' }} boxes left behind with no reason.</p>@endif
                <div class="ds-sx__open">
                    <strong>{{ count($openSets) }} {{ count($openSets) === 1 ? 'customer is' : 'customers are' }} missing boxes</strong>
                    @foreach ($openSets as $os)
                        <div class="ds-sx__openrow" wire:key="os-{{ $os['key'] }}">
                            <span><b>{{ $os['name'] }}</b> · {{ $os['have'] }} of {{ $os['of'] }} on the truck</span>
                            @foreach ($os['missing'] as $mb)
                                <span class="ds-sx__miss"><span>{{ $mb['invoice'] }} <small>{{ $mb['where'] }}</small></span>
                                    <span class="ds-sx__why">@foreach ($splitReasons as $rk => $rl)<button type="button" wire:click="splitReason({{ $mb['id'] }}, '{{ $rk }}')" @class(['is-on' => $mb['reason'] === $rk])>{{ $rl }}</button>@endforeach</span>
                                </span>
                            @endforeach
                        </div>
                    @endforeach
                    <small>Find the boxes, or pick why each one stays behind. The office sees it on the trip.</small>
                </div>
            @endif
            <button type="button" class="ds-sa__primary" wire:click="pick({{ $choice }})">Keep scanning</button>
            <button type="button" class="ds-sa__secondary" wire:click="home">Back to start</button>
        </section>
    @endif
</div>
<x-filament-actions::modals />
</x-filament-panels::page>
DISPATCH_FILE_END_11

# ---------------------------------------------------------------- tests/Feature/ReceiveTruckTest.php
mkdir -p 'tests/Feature'
cat > 'tests/Feature/ReceiveTruckTest.php' <<'DISPATCH_FILE_END_12'
<?php

use App\Filament\Scan\Pages\ScanApp;
use App\Models\Deliverylog;
use App\Models\Invoiceissue;
use App\Models\Logistichub;
use App\Models\Shipping\TruckReceipt;
use App\Models\Tripinvoice;
use App\Models\User;
use App\Support\ScanModes;
use Database\Seeders\DemoSeeder;
use Filament\Facades\Filament;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Livewire\Livewire;

uses(RefreshDatabase::class);

beforeEach(function () {
    $this->seed(DemoSeeder::class);
    Filament::setCurrentPanel(Filament::getPanel('scan'));
    $this->main = Logistichub::where('hub_code', 'MNL')->firstOrFail();
    $this->hub = Logistichub::where('hub_code', 'CEB')->firstOrFail();
    $this->trip = Deliverylog::where('logistichub_id', $this->main->id)->firstOrFail();
    $this->rows = Tripinvoice::where('deliverylog_id', $this->trip->id)->where('is_loaded', true)->take(3)->get();
    Tripinvoice::whereKey($this->rows->modelKeys())->update(['logistichub_id' => $this->hub->id, 'hub_assigned' => false]);
    $base = User::where('email', 'company@example.com')->firstOrFail();
    $this->user = $base->replicate()->fill(['email' => 'rt-'.$base->email]);
    $this->user->save();
});

it('shows Receive truck to hubs reached by truck, and Receive container to hubs reached by sea', function () {
    $this->hub->forceFill(['by_sea' => false])->save();
    expect(array_keys(ScanModes::for($this->user)))->toBe(['hub_load', 'return', 'truck_receive']);

    // A sea hub sees Receive truck only while a truck is arriving.
    $this->hub->forceFill(['by_sea' => true])->save();
    expect(array_keys(ScanModes::for($this->user)))->toBe(['hub_load', 'return', 'ship_receive', 'truck_receive']);
    Tripinvoice::whereKey($this->rows->modelKeys())->update(['logistichub_id' => $this->main->id]);
    expect(array_keys(ScanModes::for($this->user)))->toBe(['hub_load', 'return', 'ship_receive']);
});

it('receives the truck box by box, and opens a Missing box issue for each box not scanned', function () {
    $this->hub->forceFill(['by_sea' => false])->save();
    $this->actingAs($this->user);
    [$a, $b, $c] = $this->rows->pluck('invoice')->all();

    Livewire::test(ScanApp::class)->call('open', 'truck_receive')->assertSee($this->trip->trip_number.' from Manila')
        ->call('pick', $this->trip->id)
        ->call('scan', $a)->assertSet('status', 'success')->assertSee('Received at your hub')
        ->call('dismiss')->call('scan', $a)->assertSet('status', 'warning')->assertSet('message', fn ($m) => str_contains($m, 'already received'))
        ->call('dismiss')->call('scan', $b)->assertSet('status', 'success')
        ->call('finish')->assertSee('2 of 3 boxes received')->assertSee($c)
        ->call('finishReceiving')->assertNotified();

    $r = TruckReceipt::where('deliverylog_id', $this->trip->id)->first();
    expect($r->finished_at)->not->toBeNull()->and($r->missing)->toBe(1)
        ->and(Invoiceissue::where('invoice', $c)->where('remarks', 'like', '%'.$this->trip->trip_number.'%')->exists())->toBeTrue()
        ->and(Invoiceissue::where('invoice', $a)->where('remarks', 'like', '%'.$this->trip->trip_number.'%')->exists())->toBeFalse();

    // Received trucks leave the list.
    expect(\App\Support\Shipping\TruckReceive::trips($this->hub->id))->toBeEmpty();
});

it('asks for the hub photo at Receive truck and Receive container', function () {
    expect(\App\Models\BoxPhoto::STEPS)->toHaveKey('hub_receive')
        ->and(app(\App\Filament\Shared\Shipping\TruckReceiveStation::class)->photoStep())->toBe('hub_receive')
        ->and(app(\App\Filament\Shared\Shipping\ReceiveShipmentStation::class)->photoStep())->toBe('hub_receive')
        ->and(app(\App\Filament\Shared\Shipping\PortCheckStation::class)->photoStep())->toBeNull();
});
DISPATCH_FILE_END_12

# ---------------------------------------------------------------- tests/Feature/ScanAppTest.php
mkdir -p 'tests/Feature'
cat > 'tests/Feature/ScanAppTest.php' <<'DISPATCH_FILE_END_13'
<?php

use App\Filament\Scan\Pages\ScanApp;
use App\Models\BoxPhoto;
use App\Models\Container;
use App\Models\Deliverylog;
use App\Models\Invoice;
use App\Models\Tripinvoice;
use App\Models\Unmanifested;
use App\Models\User;
use App\Models\Whdeliverylog;
use App\Models\Whtripinvoice;
use App\Support\ScanModes;
use Database\Seeders\DemoSeeder;
use Filament\Facades\Filament;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Illuminate\Http\UploadedFile;
use Illuminate\Support\Facades\Storage;
use Livewire\Livewire;

uses(RefreshDatabase::class);

beforeEach(function () {
    $this->seed(DemoSeeder::class);
    Storage::fake('local');
    Storage::fake('public');
    Filament::setCurrentPanel(Filament::getPanel('scan'));
});

/** A copy of a demo user without the super_admin role, so we test the account type alone. */
function scanUser(string $email): User
{
    $base = User::where('email', $email)->firstOrFail();
    $u = $base->replicate()->fill(['email' => 'scan-'.$email]);
    $u->save();

    return $u;
}

it('lets warehouse, partner hub and office accounts in, but not drivers', function () {
    $this->actingAs(scanUser('warehouse@example.com'))->get('/scan')->assertOk()->assertSee('Unload container')->assertSee('Warehouse unload');
    $this->flushSession();
    $this->actingAs(scanUser('company@example.com'))->get('/scan')->assertOk()->assertSee('Hub load')->assertDontSee('Unload container');
    $this->flushSession();
    $this->actingAs(scanUser('admin@example.com'))->get('/scan')->assertOk()->assertSee('Load truck');
    $this->flushSession();
    $this->actingAs(scanUser('driver@example.com'))->get('/scan')->assertForbidden();
});

it('gives each account type its own scans', function () {
    expect(array_keys(ScanModes::for(scanUser('warehouse@example.com'))))->toBe(['unload', 'load', 'wh_load', 'wh_unload', 'return', 'port', 'ret_receive'])
        ->and(array_keys(ScanModes::for(scanUser('company@example.com'))))->toBe(['hub_load', 'return', 'truck_receive'])
        ->and(array_keys(ScanModes::for(scanUser('admin@example.com'))))->toBe(['unload', 'load', 'return', 'port'])
        ->and(ScanModes::for(scanUser('driver@example.com')))->toBe([]);
});

it('unloads a container box by box, with an optional photo, using the same rules as Unload Container', function () {
    $user = scanUser('warehouse@example.com');
    $this->actingAs($user);
    $container = Container::where('warehouse_id', $user->warehouse_id)->firstOrFail();
    $box = Invoice::where('container_id', $container->id)->where('is_verified', false)->firstOrFail();

    $page = Livewire::test(ScanApp::class)
        ->call('open', 'unload')->assertSet('screen', 'pick')->assertSee($container->container_no)
        ->call('pick', $container->id)->assertSet('screen', 'scan')
        ->call('scan', $box->invoice)
        ->assertSet('status', 'success')->assertSee('Verified · off the container')->assertSee('Add photo · optional')
        ->call('setCondition', 'damaged')->assertSee('What is wrong?')
        ->set('note', 'Corner crushed')
        ->set('boxPhoto', UploadedFile::fake()->image('p.jpg', 2000, 1500))
        ->call('saveBoxPhoto')->assertHasNoErrors();

    expect($box->fresh()->is_verified)->toBeTrue();
    $photo = BoxPhoto::sole();
    expect($photo->step)->toBe('unload')->and($photo->condition)->toBe('damaged')->and($photo->note)->toBe('Corner crushed')
        ->and($photo->container_id)->toBe($container->id)->and($photo->user_id)->toBe($user->id);

    // a box that is not on the manifest
    $page->call('scan', 'NOTONMANIFEST1')->assertSet('status', 'danger')->assertSet('missing', 'NOTONMANIFEST1')
        ->assertSee('Not on this container')
        ->callAction('unmanifested', data: ['attachment_pic' => [UploadedFile::fake()->image('u.jpg')], 'remarks' => 'Found inside'])
        ->assertHasNoActionErrors()->assertSet('missing', null);
    expect(Unmanifested::where('invoice', 'NOTONMANIFEST1')->where('container_id', $container->id)->exists())->toBeTrue();

    $page->call('finish')->assertSet('screen', 'done')->assertSee('Keep scanning')->call('home')->assertSet('screen', 'home');
});

it('loads a delivery truck and refuses a box from another trip', function () {
    $user = scanUser('admin@example.com');
    $this->actingAs($user);
    $trip = Deliverylog::where('logistichub_id', $user->logistichub_id)->whereNotNull('truck_id')->where('is_active', true)->firstOrFail();
    $row = Tripinvoice::where('deliverylog_id', $trip->id)->where('is_loaded', false)->first();
    if (! $row) {
        $row = Tripinvoice::where('deliverylog_id', $trip->id)->firstOrFail();
        $row->update(['is_loaded' => false]);
    }

    Livewire::test(ScanApp::class)
        ->call('open', 'load')->call('pick', $trip->id)
        ->call('scan', $row->invoice)->assertSet('status', 'success')->assertSee('Loaded on the truck')
        ->call('scan', 'NOPE-123')->assertSet('status', 'danger')->assertSee('Keep it aside, scan next');

    expect($row->fresh()->is_loaded)->toBeTruthy();
});

it('does not open a container or trip that is not yours, or a scan your account does not have', function () {
    $user = scanUser('company@example.com');
    $this->actingAs($user);
    $otherTrip = Deliverylog::where('logistichub_id', '!=', $user->logistichub_id)->firstOrFail();

    Livewire::test(ScanApp::class)
        ->call('open', 'unload')->assertSet('screen', 'home')
        ->call('open', 'hub_load')->assertSet('screen', 'pick')
        ->call('pick', $otherTrip->id)->assertSet('screen', 'pick')->assertNotified('That one is not open for you any more.');
});

it('installs as its own app', function () {
    $this->get('/pwa/scan/manifest.webmanifest')->assertOk()->assertJsonPath('short_name', 'Scan')->assertJsonPath('scope', '/scan');
    $this->get('/scan/login')->assertOk()->assertSee('Load and unload, box by box.')->assertSee('/pwa/scan/manifest"', false);
});

it('receives a warehouse transfer and adds the box to this warehouse', function () {
    $user = scanUser('warehouse@example.com');
    $this->actingAs($user);
    $row = Whtripinvoice::firstOrFail();
    $row->update(['is_loaded' => true, 'is_unloaded' => false]);
    $trip = Whdeliverylog::findOrFail($row->whdeliverylog_id);
    $trip->update(['warehouse_id' => $user->warehouse_id]);
    $invoice = Invoice::findOrFail($row->invoice_id);
    $invoice->update(['warehouse_id' => null]);

    Livewire::test(ScanApp::class)
        ->call('open', 'wh_unload')->call('pick', $trip->id)
        ->call('scan', $invoice->invoice)->assertSet('status', 'success')->assertSee('Received · added to inventory');

    expect($row->fresh()->is_unloaded)->toBeTruthy()
        ->and($invoice->fresh()->warehouse_id)->toBe($user->warehouse_id);
});

it('hides finished and closed containers, with a link to show them', function () {
    $user = scanUser('warehouse@example.com');
    $this->actingAs($user);
    $base = Container::where('warehouse_id', $user->warehouse_id)->firstOrFail();
    $open = $base->replicate()->fill(['container_no' => 'OPEN0000001', 'is_unloaded' => false, 'is_active' => true]);
    $open->save();
    $full = $base->replicate()->fill(['container_no' => 'FULL0000001', 'is_unloaded' => false, 'is_active' => true]);
    $full->save();
    $closed = $base->replicate()->fill(['container_no' => 'SHUT0000001', 'is_unloaded' => false, 'is_active' => false]);
    $closed->save();
    $box = Invoice::where('container_id', $base->id)->firstOrFail();
    $box->replicate()->fill(['invoice' => 'OPENBOX1', 'container_id' => $open->id, 'is_verified' => false])->save();
    $box->replicate()->fill(['invoice' => 'FULLBOX1', 'container_id' => $full->id, 'is_verified' => true])->save();
    $box->replicate()->fill(['invoice' => 'SHUTBOX1', 'container_id' => $closed->id, 'is_verified' => false])->save();

    Livewire::test(ScanApp::class)
        ->assertSee('waiting')
        ->call('open', 'unload')
        ->assertSee('OPEN0000001')->assertDontSee('FULL0000001')->assertDontSee('SHUT0000001')
        ->assertSee('Show finished')
        ->call('toggleFinished')
        ->assertSee('FULL0000001')->assertSee('SHUT0000001')->assertSee('· closed')->assertSee('Hide finished')
        ->call('pick', $full->id)->assertSet('screen', 'scan'); // still openable to re-check
});
DISPATCH_FILE_END_13

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
