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
