#!/usr/bin/env bash
#
# Dispatch System — Part 34: Which one? in every scan
# Only the files changed in this step; the rest of your project is left as it is.
#
#   cd ~/Desktop/Project/DispatchSystem
#   bash ~/Desktop/Project/part34-which-one.sh

set -euo pipefail
[ -f artisan ] || { echo "Run this from inside your DispatchSystem project folder (the one with 'artisan')."; exit 1; }

STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="../DispatchSystem-backup-$STAMP.tar.gz"
echo "▶ Backing up the project to $BACKUP"
tar -czf "$BACKUP" --exclude=vendor --exclude=node_modules --exclude=storage/logs .

echo "▶ Writing 29 files"

# ---------------------------------------------------------------- app/Filament/Concerns/BypassesTripRules.php
mkdir -p 'app/Filament/Concerns'
cat > 'app/Filament/Concerns/BypassesTripRules.php' <<'DISPATCH_FILE_END_0'
<?php

namespace App\Filament\Concerns;

use App\Models\Invoice;
use App\Support\Trips\TripRules;
use Illuminate\Support\Facades\Auth;

/**
 * "Load it anyway" on a scan station: free, with a reason, or ask the office (trip rules).
 * Needs $early / $wrongHub / $forceLoad, the scan() method and the selected trip in data.deliverylog_id.
 */
trait BypassesTripRules
{
    /** ['rule', 'code', 'need' => reason|office] while the reason buttons show. */
    public ?array $bypass = null;

    protected function tripKind(): string
    {
        return 'delivery';
    }

    protected function bypassContext(string $code): array
    {
        $tripId = (int) ($this->data['deliverylog_id'] ?? 0) ?: null;
        $model = $this->tripKind() === 'transfer' ? \App\Models\Whdeliverylog::class : \App\Models\Deliverylog::class;

        return ['kind' => $this->tripKind(), 'trip_id' => $tripId, 'trip_number' => $tripId ? $model::whereKey($tripId)->value('trip_number') : null,
            'invoice_id' => $this->boxShown($code) ?? \App\Support\Boxes\SameNumber::best($code)?->id, 'box' => $code];
    }

    /** The box on the result card, when it has this number (two boxes can share one, board 58). */
    protected function boxShown(string $code): ?int
    {
        return $this->lastInvoiceId && \App\Models\Invoice::whereKey($this->lastInvoiceId)->value('invoice') === $code ? $this->lastInvoiceId : null;
    }

    public function loadAnyway(): void
    {
        $code = $this->early['code'] ?? $this->wrongHub['code'] ?? null;
        if (! $code) {
            return;
        }
        $rule = TripRules::ruleOf($this->early ?? null, $this->wrongHub ?? null);
        $ctx = $this->bypassContext($code);
        $need = TripRules::need($rule, Auth::user(), $ctx['trip_id'], $ctx['invoice_id']);
        if ($need === 'free') {
            $this->forceScan($code);

            return;
        }
        $this->bypass = ['rule' => $rule, 'code' => $code, 'need' => $need];
    }

    public function bypassWith(string $reason): void
    {
        if (! $this->bypass || ! in_array($reason, TripRules::reasons(), true) || $this->bypass['need'] !== 'reason') {
            return;
        }
        $b = $this->bypass;
        TripRules::record($b['rule'], Auth::user(), $reason, $this->bypassContext($b['code']));
        $this->bypass = null;
        $this->forceScan($b['code']);
    }

    public function askOffice(?string $reason = null): void
    {
        if (! $this->bypass) {
            return;
        }
        $b = $this->bypass;
        TripRules::ask($b['rule'], Auth::user(), $reason, $this->bypassContext($b['code']));
        $this->bypass = null;
        $this->early = null;
        $this->wrongHub = null;
        $this->scanResult('warning', "Asked the office about {$b['code']}. Keep it aside: when they approve, scan it again.", (($id = $this->boxShown($b['code'])) ? \App\Models\Invoice::find($id) : \App\Support\Boxes\SameNumber::best($b['code'])));
    }

    public function cancelBypass(): void
    {
        $this->bypass = null;
    }

    protected function forceScan(string $code): void
    {
        $this->forceLoad = true;
        $pin = $this->boxShown($code); // the same box the crew was told about
        $pin ? $this->scanPinned($code, $pin) : $this->scan($code);
        $this->forceLoad = false;
    }

    /** Skip the check: forced now, or the office approved this box on this trip. */
    protected function skips(string $rule, ?int $tripId, ?int $invoiceId): bool
    {
        return $this->forceLoad || TripRules::isApproved($rule, $tripId, $invoiceId);
    }
}
DISPATCH_FILE_END_0

# ---------------------------------------------------------------- app/Filament/Concerns/ScansInvoices.php
mkdir -p 'app/Filament/Concerns'
cat > 'app/Filament/Concerns/ScansInvoices.php' <<'DISPATCH_FILE_END_1'
<?php

namespace App\Filament\Concerns;

use App\Models\Invoice;
use App\Support\InvoiceLookup;
use Filament\Notifications\Notification;
use Illuminate\Support\Collection;

/**
 * Shared behaviour for the scan stations (load truck, unload container …).
 *
 * The page's form holds the selection (trip / container) in $data; the
 * <x-barcode-scanner method="scan" /> component calls scan() with each code.
 */
trait ScansInvoices
{
    use TakesBoxPhotos;

    public ?array $data = [];

    /** id of the last scanned invoice, its outcome and a short message */
    public ?int $lastInvoiceId = null;

    public ?string $lastStatus = null;

    public ?string $lastMessage = null;

    /** Board 58: two boxes with the scanned number still to do here: ['code' => …, 'options' => [SameNumber::choice …]]. */
    public ?array $which = null;

    /** The box picked in Which one? (invoice id), used by the next handleScan() only. */
    public ?int $pinInvoice = null;

    /** Handle one scanned / typed code. */
    abstract protected function handleScan(string $code): void;

    public function scan(string $code): void
    {
        $code = InvoiceLookup::normalize($code);

        if ($code === '') {
            return;
        }

        $selectionField = $this->selectionField();

        if ($selectionField && blank($this->data[$selectionField] ?? null)) {
            $this->scanResult('warning', 'Select '.$this->selectionLabel().' first, then scan.', notify: true);

            return;
        }

        $this->which = null;
        $this->handleScan($code);
    }

    /** Which one? → the receiver was picked: scan that box. */
    public function chooseWhich(int $invoiceId): void
    {
        $w = $this->which;
        if (! $w || ! collect($w['options'] ?? [])->contains('id', $invoiceId)) {
            return;
        }
        $this->scanPinned($w['code'], $invoiceId);
    }

    /** Scan as if this exact box was scanned (Which one? on the Scan app). */
    public function scanPinned(string $code, int $invoiceId): void
    {
        $this->pinInvoice = $invoiceId;
        try {
            $this->scan($code);
        } finally {
            $this->pinInvoice = null;
        }
    }

    public function cancelWhich(): void
    {
        $this->which = null;
        $this->lastStatus = null;
        $this->lastMessage = null;
    }

    /**
     * Board 58: the row to use for this scan. Two or more still to do with this number: ask (returns false).
     * A picked box (pinInvoice) wins; one left to do: that one; none left: the first (for "already done").
     *
     * @param  callable(mixed): ?Invoice  $invoiceOf
     * @param  callable(mixed): bool  $done
     */
    protected function whichRow(string $code, Collection $rows, callable $invoiceOf, callable $done): mixed
    {
        if ($rows->isEmpty()) {
            return null;
        }
        if ($this->pinInvoice && ($hit = $rows->first(fn ($r) => (int) $invoiceOf($r)?->getKey() === $this->pinInvoice))) {
            return $hit;
        }
        $open = $rows->reject(fn ($r) => $done($r))->values();
        if ($open->count() > 1) {
            $this->askWhich($code, $open->map($invoiceOf)->filter());

            return false;
        }

        return $open->first() ?? $rows->first();
    }

    protected function askWhich(string $code, Collection $invoices): void
    {
        $invoices = \Illuminate\Database\Eloquent\Collection::make($invoices->values()->all())->loadMissing('container:id,container_no,batch_no');
        $this->which = ['code' => $code, 'options' => $invoices->map(fn (Invoice $i) => \App\Support\Boxes\SameNumber::choice($i))->values()->all()];
        $this->lastStatus = 'warning';
        $this->lastMessage = $invoices->count()." boxes have number {$code}. Which one? Look at the receiver on the sticker.";
        $this->lastInvoiceId = null;
        $this->dispatch('scan-result', status: 'which');
    }

    /** " · 1 of 2 · Ailene Gacita" after a pick among boxes with one number. */
    protected function whichSuffix(int $done, int $total, ?Invoice $invoice): string
    {
        return $total > 1 ? " · {$done} of {$total}".($invoice?->receiver_name ? ' · '.\Illuminate\Support\Str::title(\Illuminate\Support\Str::lower($invoice->receiver_name)) : '') : '';
    }

    public function stationHeading(): string
    {
        return 'Scan boxes onto the truck';
    }

    public function stationDescription(): string
    {
        return 'Pick the trip, then scan every box as it is loaded.';
    }

    public function stationIcon(): string
    {
        return 'heroicon-o-arrow-up-tray';
    }

    public function progressLabel(): string
    {
        return 'Boxes loaded on this trip';
    }

    /** Name of the form field that must be chosen before scanning (null = none). */
    protected function selectionField(): ?string
    {
        return null;
    }

    protected function selectionLabel(): string
    {
        return 'an option';
    }

    protected function scanResult(string $status, string $message, ?Invoice $invoice = null, bool $notify = true): void
    {
        $this->lastStatus = $status;
        $this->lastMessage = $message;
        $this->lastInvoiceId = $invoice?->getKey();
        $this->photoAfterScan($status);

        if ($notify) {
            Notification::make()
                ->title($message)
                ->status($status)
                ->duration($status === 'success' ? 2500 : 6000)
                ->send();
        }

        $this->dispatch('scan-result', status: $status);
    }

    public function lastInvoice(): ?Invoice
    {
        return $this->lastInvoiceId ? Invoice::with('consolidator', 'routearea')->find($this->lastInvoiceId) : null;
    }

    /**
     * Other boxes from the same sender to the same receiver in the same container,
     * so the crew can see at a glance whether the whole household is on the truck.
     *
     * @param  callable(Invoice): array{trip: ?string, done: bool}  $describe
     */
    protected function householdRows(?Invoice $invoice, callable $describe): array
    {
        if (! $invoice) {
            return [];
        }

        return Invoice::query()
            ->where('container_id', $invoice->container_id)
            ->where('receiver_name', $invoice->receiver_name)
            ->where('sender_name', $invoice->sender_name)
            ->orderBy('invoice')
            ->get()
            ->map(fn (Invoice $box) => ['invoice' => $box->invoice, 'box' => $box->boxtype] + $describe($box))
            ->all();
    }

    /** Newest invoices with this number (the code is already normalised by scan()). */
    protected function invoicesMatching(string $code): Collection
    {
        // boxes not delivered first (two boxes can share a number, board 57)
        return Invoice::query()->where('invoice', $code)->orderByRaw('coalesce(is_delivered, 0) asc')->orderByDesc('id')->get();
    }
}
DISPATCH_FILE_END_1

# ---------------------------------------------------------------- app/Filament/Imports/InvoiceImporter.php
mkdir -p 'app/Filament/Imports'
cat > 'app/Filament/Imports/InvoiceImporter.php' <<'DISPATCH_FILE_END_2'
<?php

namespace App\Filament\Imports;


use App\Models\Invoice;
use App\Models\Container;
use Filament\Actions\Imports\Importer;
use Filament\Actions\Imports\ImportColumn;
use Filament\Actions\Imports\Models\Import;
use Filament\Resources\RelationManagers\RelationManager;

class InvoiceImporter extends Importer
{
    protected static ?string $model = Invoice::class;

    public static function getColumns(): array
    {
        return [
            // ImportColumn::make('container_id'),

//    ->castStateUsing(function (float $state): ?float {
//         if (blank($state)) {
//             return null;
//         }

//         return 3;
//     }),
            ImportColumn::make('invoice')
            ->requiredMapping(),
            ImportColumn::make('batchno')
             ->requiredMapping()
                ->rules(['max:255']),
            ImportColumn::make('sender_name')
                ->requiredMapping()
                ->rules(['required', 'max:255']),
            ImportColumn::make('receiver_name')
                ->requiredMapping()
                ->rules(['required', 'max:255']),
            ImportColumn::make('receiver_address')
                ->requiredMapping()
                ->rules(['required', 'max:255']),
            ImportColumn::make('receiver_province')
                ->requiredMapping()
                ->rules(['required', 'max:255']),
            ImportColumn::make('receiver_city')
                ->requiredMapping()
                ->rules(['required', 'max:255']),
            ImportColumn::make('receiver_barangay')
                ->requiredMapping()
                ->rules(['required', 'max:255']),
            ImportColumn::make('receiver_mobile_no')
                ->requiredMapping()
                ->rules(['required', 'max:255']),
            ImportColumn::make('receiver_home_no')
                ->requiredMapping(),
            ImportColumn::make('boxtype')
                ->requiredMapping(),

            ImportColumn::make('routearea_id')
                ->requiredMapping(),
             ImportColumn::make('location_code')
                ->requiredMapping()
            //     ->rules(['required', 'max:255']),
            // ImportColumn::make('routearea')
            //     ->numeric()
            //     ->rules(['integer']),
            // ImportColumn::make('is_verified')
            //     ->boolean()
            //     ->rules(['required', 'boolean']),
            // ImportColumn::make('is_delivered')

            //     ->boolean()
            //     ->rules(['required', 'boolean']),
            // ImportColumn::make('is_assigned')

            //     ->boolean()
            //     ->rules(['required', 'boolean']),
        ];
    }



    public function resolveRecord(): ?Invoice
    {

        // return Invoice::firstOrNew([
        //     // Update existing records, matching them by `$this->data['column_name']`
        //     // 'email' => $this->data['email'],
        // ],[
        //     'container_id' => 3,
        // ]);
        // dd($this->data['boxtype']);





        // the same box twice (same number, receiver and sender in this container): a copied row, skip it (board 58).
        // Same number with another receiver is a real second box: it is saved, and the scans ask Which one?
        if (Invoice::where('container_id', $this->options['container_id'])->where('invoice', trim((string) ($this->data['invoice'] ?? '')))
            ->where('receiver_name', trim((string) ($this->data['receiver_name'] ?? '')))->where('sender_name', trim((string) ($this->data['sender_name'] ?? '')))->exists()) {
            return null;
        }

        return new Invoice([
            'container_id' =>   $this->options['container_id'],
            'warehouse_id' =>   $this->options['warehouse_id'],

        ]);
        // return new Invoice();
    }


    public static function getCompletedNotificationBody(Import $import): string
    {
        $body = 'Your invoice import has completed and ' . number_format($import->successful_rows) . ' ' . str('row')->plural($import->successful_rows) . ' imported.';

        if ($failedRowsCount = $import->getFailedRowsCount()) {
            $body .= ' ' . number_format($failedRowsCount) . ' ' . str('row')->plural($failedRowsCount) . ' failed to import.';
        }

        return $body;
    }

}
DISPATCH_FILE_END_2

# ---------------------------------------------------------------- app/Filament/Resources/ContainerResource/RelationManagers/InvoicesRelationManager.php
mkdir -p 'app/Filament/Resources/ContainerResource/RelationManagers'
cat > 'app/Filament/Resources/ContainerResource/RelationManagers/InvoicesRelationManager.php' <<'DISPATCH_FILE_END_3'
<?php

namespace App\Filament\Resources\ContainerResource\RelationManagers;

use App\Filament\Exports\InvoiceExporter;
use App\Filament\Imports\InvoiceImporter;
use App\Models\Consolidator;
use App\Models\Container;
use Filament\Actions\Action;
use Filament\Actions\ActionGroup;
use Filament\Actions\BulkAction;
use Filament\Actions\BulkActionGroup;
use Filament\Actions\CreateAction;
use Filament\Actions\DeleteAction;
use Filament\Actions\DeleteBulkAction;
use Filament\Actions\EditAction;
use Filament\Actions\ExportBulkAction;
use Filament\Actions\ImportAction;
use Filament\Forms\Components\Select;
use Filament\Forms\Components\TextInput;
use Filament\Notifications\Notification;
use Filament\Resources\RelationManagers\RelationManager;
use Filament\Schemas\Components\Callout;
use Filament\Schemas\Schema;
use Filament\Support\Enums\Size;
use Filament\Support\Icons\Heroicon;
use Filament\Tables\Columns\IconColumn;
use Filament\Tables\Columns\TextColumn;
use Filament\Tables\Filters\SelectFilter;
use Filament\Tables\Table;
use Illuminate\Support\Collection;
use Illuminate\Support\Facades\Auth;

class InvoicesRelationManager extends RelationManager
{
    protected static string $relationship = 'invoices';

    public function form(Schema $schema): Schema
    {
        return $schema
            ->components([
                TextInput::make('invoice')
                  //  ->unique()
                    ->label('Invoice Number')
                    ->required(),
                TextInput::make('sender_name')
                    ->label('Sender')
                    ->required(),
                TextInput::make('receiver_name')
                    ->label('Receiver')
                    ->required(),
                TextInput::make('receiver_address')
                    ->label('Receiver Address')
                    ->required(),
                TextInput::make('receiver_province')
                    ->label('Receiver Province')
                    ->required(),
                TextInput::make('receiver_city')
                    ->label('Receiver City')
                    ->required(),
                TextInput::make('receiver_barangay')
                    ->label('Receiver Barangay')
                    ->required(),
                TextInput::make('receiver_mobile_no')
                    ->label('Mobile Number')
                    ->required(),
                TextInput::make('receiver_home_no')
                    ->label('Hombe Number')
                    ->required(),
                TextInput::make('boxtype')
                    ->label('Type of Boxes')
                    ->required(),
                Select::make('location_code')
                    ->label('Consolidator')
                    ->relationship('consolidator', 'company_name')
                    ->required(),
                Select::make('routearea_id')
                    ->relationship(name: 'routearea', titleAttribute: 'code')
                    ->label('Route Area'),

            ]);
    }

    public function table(Table $table): Table
    {
        return $table
            ->defaultSort('created_at', 'desc')
            // board 58: one number on 2 rows of this container (different receivers): the crew will be asked Which one?
            ->description(fn () => \App\Support\Boxes\SameNumber::inContainer((int) $this->getOwnerRecord()->getKey()))
            ->columns([
                TextColumn::make('company')
                    ->label('Company')
                    ->getStateUsing(function ($record) {
                        return Consolidator::nameForCode($record->location_code);
                    }),
                TextColumn::make('invoice')
                    ->searchable(isIndividual: true)
                    ->sortable()
                    ->label('Invoice'),
                TextColumn::make('is_priority')
                    ->label('Priority')
                    // ->badge()
                    ->formatStateUsing(fn ($state) => $state ? 'PRIORITY' : null)
                    ->color(fn ($state) => $state ? 'success' : null),
                TextColumn::make('sender_name')
                    ->label('Sender'),
                TextColumn::make('receiver_name')
                    ->label('Receiver'),
                TextColumn::make('receiver_address')
                    ->label('Address'),
                TextColumn::make('receiver_province')
                    ->label('Province'),
                TextColumn::make('receiver_city')
                    ->label('City'),
                TextColumn::make('receiver_barangay')
                    ->label('Barangay'),
                TextColumn::make('receiver_mobile_no')
                    ->label('Mobile No'),
                TextColumn::make('receiver_home_no')
                    ->label('Home No')
                    ->toggleable(isToggledHiddenByDefault: true),
                TextColumn::make('routearea.code')
                    ->label('Area'),
                TextColumn::make('boxtype'),
                IconColumn::make('is_verified')
                    ->label('Verified')
                    ->boolean()
                    ->toggleable(isToggledHiddenByDefault: true),
                IconColumn::make('is_delivered')
                    ->label('Deliverd')
                    ->boolean()
                    ->toggleable(isToggledHiddenByDefault: true),
                IconColumn::make('is_assigned')
                    ->label('Assigned')
                    ->boolean()
                    ->toggleable(isToggledHiddenByDefault: true),
                TextColumn::make('user.full_name')
                    ->label('Created By')
                    ->toggleable(isToggledHiddenByDefault: true),
            ])
            ->filters([
                SelectFilter::make('is_verified')
                    ->label('Is Verified')
                    ->options([
                        1 => 'Yes',
                        0 => 'No',
                    ])->default(0),
                SelectFilter::make('routearea_id')->label('Route Area'),
                SelectFilter::make('location_code')
                    ->options(function () {
                        return Consolidator::all()->pluck('company_name', 'code');
                    })
                    ->label('Consolidator'),
            ])->deferFilters(false)
            ->headerActions([
                ActionGroup::make([
                    CreateAction::make()
                        ->Icon('heroicon-o-plus')
                        ->color('primary')
                        ->mutateDataUsing(function (array $data): array {
                            $data['user_id'] = Auth::user()->id;

                            return $data;
                        })
                        ->slideOver()
                        ->modalHeading('Create Invoice'),
                    Action::make('dowload')
                        ->label('Download Invoice')
                        ->color('info')
                        ->Icon('heroicon-o-arrow-down-on-square')
                        ->disabled(),
                    ImportAction::make()
                        ->visible(function () {
                            return ! $this->getOwnerRecord()->is_unloaded;
                        })
                        ->importer(InvoiceImporter::class)
                        ->label('Upload Invoice')
                        ->color('warning')
                        ->Icon('heroicon-o-arrow-up-on-square')
                        ->options(['container_id' => $this->getOwnerRecord()->getKey(),
                            'warehouse_id' => $this->getOwnerRecord()->warehouse_id]),

                    // Optional: Add any logic to be executed after importing
                ])->size(Size::Small)
                    ->label('Menu')
                    ->color('info')
                    ->button(),
            ])
            ->recordActions([
                ActionGroup::make([
                    EditAction::make()
                        ->color('primary')
                        ->slideOver(),
                    DeleteAction::make(),

                ]),
                // ->button()
                // ->color('info')
                // ->size(Size::Small)
                // ->label('Menu')
            ])
            ->toolbarActions([
                BulkActionGroup::make([
                    BulkAction::make('move')
                        ->label('Move to Container')
                        ->icon(Heroicon::ArrowTopRightOnSquare)
                        ->color('primary')
                        ->requiresConfirmation()
                        ->schema([
                            Callout::make('Instrucitons')
                                ->description('Please activate the container first before selecting it. Only active containers are available for selection')
                                ->info(),
                            Select::make('target_container_id')
                                ->label('Target Container')
                                ->options(function () {
                                    return Container::where('consolidator_id', $this->getOwnerRecord()->consolidator_id)
                                        ->where('is_active', true)
                                        ->pluck('container_no', 'id');
                                })
                                ->required(),
                        ])
                        ->action(function (Collection $records, $data) {

                            $container_data = Container::where('id', $data['target_container_id'])->first();

                            foreach ($records as $record) {
                                $record->update(
                                    [
                                        'container_id' => $data['target_container_id'],
                                        'batchno' => $container_data->batch_no,
                                    ]
                                );
                            }
                            Notification::make()
                                ->title('Invoices moved successfully')
                                ->success()
                                ->send();
                        }),
                    ExportBulkAction::make()
                        ->exporter(InvoiceExporter::class)
                        ->color('info')
                        ->icon('heroicon-o-document-arrow-up')
                        ->label('Export Invoices'),
                    DeleteBulkAction::make(),
                    BulkAction::make('is_priority')
                        ->label('Mark as Priority')
                        ->icon(Heroicon::ExclamationTriangle)
                        ->color('warning')
                        ->requiresConfirmation()
                        ->action(function (Collection $records) {
                            foreach ($records as $record) {
                                $record->update(['is_priority' => true]);
                            }
                        })
                        ->color('success'),
                ]),
            ]);
    }
}
DISPATCH_FILE_END_3

# ---------------------------------------------------------------- app/Filament/Scan/Pages/ScanApp.php
mkdir -p 'app/Filament/Scan/Pages'
cat > 'app/Filament/Scan/Pages/ScanApp.php' <<'DISPATCH_FILE_END_4'
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
            $target = ($this->targetInfo['id'] ?? null) === $this->choice ? $this->targetInfo : $station->appChoices()->firstWhere('id', $this->choice);
            $extras = $this->extrasReady || $this->screen === 'done';
            $loadNext = $extras && $this->screen === 'scan' && method_exists($station, 'loadNext') ? $station->loadNext() : null;
            $team = $extras && method_exists($station, 'team') ? $station->team() : [];
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
DISPATCH_FILE_END_4

# ---------------------------------------------------------------- app/Filament/Shared/LoadTripPage.php
mkdir -p 'app/Filament/Shared'
cat > 'app/Filament/Shared/LoadTripPage.php' <<'DISPATCH_FILE_END_5'
<?php

namespace App\Filament\Shared;

use App\Filament\Concerns\ScansInvoices;
use App\Models\Deliverylog;
use App\Models\Invoice;
use Filament\Notifications\Notification;
use App\Models\Tripinvoice;
use App\Models\Boxes\SetSplit;
use App\Models\User;
use App\Services\TripAssignment;
use App\Support\Boxes\BoxSets;
use App\Support\Maps\LoadOrder;
use App\Support\Maps\TripSorter;
use Filament\Forms\Components\Select;
use Filament\Pages\Page;
use Filament\Schemas\Schema;
use Filament\Support\Icons\Heroicon;
use Illuminate\Database\Eloquent\Builder;
use Illuminate\Support\Collection;
use Illuminate\Support\Facades\Auth;

/**
 * Scan station: crew scans each box as it goes onto the truck of a trip.
 *
 * Used by the admin hub (Scanload), the warehouse hub (Hubloaded) and partner
 * hubs (LoadTruck, which loads boxes handed over to the hub's own trips).
 */
abstract class LoadTripPage extends Page
{
    use ScansInvoices;
    use \App\Filament\Concerns\BypassesTripRules;

    protected string $view = 'filament.pages.scanload';

    protected static string|\BackedEnum|null $navigationIcon = Heroicon::OutlinedArrowUpTray;

    /** Partner-hub mode: invoices are linked via deliveryloghub_id / is_loaded_hub. */
    protected static bool $atHub = false;

    /** Set by "Load it anyway" after a "too early" warning. */
    public bool $forceLoad = false;

    /** The last box that was too early to load (see LoadOrder). */
    public ?array $early = null;

    /** Where the box just loaded goes: ['zone' => 'front', 'stop' => 7]. */
    public ?array $spot = null;

    /** The box is for another hub than the trip goes to. */
    public ?array $wrongHub = null;

    /** The box's set on this truck: "Maria Santos · 2 of 3 · still to load X-103 (C)". */
    public ?array $setInfo = null;

    public function mount(): void
    {
        $this->form->fill();
    }

    protected function tripColumn(): string
    {
        return static::$atHub ? 'deliveryloghub_id' : 'deliverylog_id';
    }

    protected function loadedColumn(): string
    {
        return static::$atHub ? 'is_loaded_hub' : 'is_loaded';
    }

    protected function tripOptionsQuery(): Builder
    {
        return Deliverylog::query()
            ->with('destination:id,hub_name')
            ->where('logistichub_id', Auth::user()->logistichub_id)
            ->whereNotNull('truck_id')
            ->where('is_active', true)
            ->latest('id');
    }

    public function form(Schema $schema): Schema
    {
        return $schema
            ->statePath('data')
            ->components([
                Select::make('deliverylog_id')
                    ->label('Trip')
                    ->placeholder('Choose the trip you are loading')
                    ->searchable()
                    ->live()
                    ->required()
                    ->afterStateUpdated(fn () => $this->reset('lastInvoiceId', 'lastStatus', 'lastMessage'))
                    ->options(fn () => $this->tripOptionsQuery()
                        ->get()
                        ->mapWithKeys(fn (Deliverylog $trip) => [
                            $trip->id => $trip->trip_number.($trip->destination ? ' → '.$trip->destination->hub_name : ''),
                        ])),
            ]);
    }

    protected function selectionField(): ?string
    {
        return 'deliverylog_id';
    }

    protected function selectionLabel(): string
    {
        return 'a trip';
    }

    /** The selected trip, re-checked against what this user may load. */
    protected function selectedTrip(): ?Deliverylog
    {
        return $this->tripOptionsQuery()->find($this->data['deliverylog_id'] ?? null);
    }

    protected function handleScan(string $code): void
    {
        $trip = $this->selectedTrip();

        if (! $trip) {
            $this->scanResult('danger', 'That trip is no longer open for loading.');

            return;
        }

        // board 58: two boxes with this number on the trip still to load → Which one? (the receiver on the sticker)
        $sameRows = Tripinvoice::with('invdata')->where($this->tripColumn(), $trip->id)->where('invoice', $code)->orderBy('id')->get();
        $tripinvoice = $this->whichRow($code, $sameRows, fn ($r) => $r->invdata, fn ($r) => (bool) $r->{$this->loadedColumn()});
        if ($tripinvoice === false) {
            return;
        }
        $sameOnTrip = $sameRows->count();

        $this->bypass = null;
        $box = $tripinvoice?->invdata ?? \App\Support\Boxes\SameNumber::best($code, Auth::user()?->warehouse_id);
        // Truck full: the box does not fit in the truck's space (only for trucks with a space set).
        if ($box && ! static::$atHub && ! $tripinvoice?->{$this->loadedColumn()} && ($full = \App\Support\Trips\TripSpace::overFull($trip, $box))
            && ! $this->skips('truck_full', $trip->id, $box->id)) {
            $this->early = null;
            $this->wrongHub = ['kind' => 'full', 'code' => $code, 'for' => $full['used'].' of '.$full['cap'].' space used', 'section' => $box->whSection?->code ?? '—',
                'color' => $box->whSection?->color, 'trip' => $trip->trip_number, 'space' => $full['space'], 'province' => $box->receiver_province];
            $this->scanResult('warning', "Truck full: {$code} does not fit ({$full['used']} of {$full['cap']} space used).", $box);

            return;
        }

        // Trip planned by city: a waiting box of one of its cities joins the trip now.
        $cityTrip = ! static::$atHub && \App\Support\Trips\CityTrips::isCityTrip($trip);
        if (! $tripinvoice && $cityTrip) {
            [$joined, $why] = \App\Support\Trips\CityTrips::join($trip, $code, $box ? $this->skips('topup_other', $trip->id, $box->id) : $this->forceLoad,
                $box ? $this->skips('direct_hub', $trip->id, $box->id) : false);
            if ($joined) {
                $tripinvoice = $joined;
            } elseif ($why === 'other-city') {
                $inv = \App\Support\Boxes\SameNumber::best($code);
                $place = \Illuminate\Support\Str::title(trim($inv?->receiver_city.', '.$inv?->receiver_province, ', '));
                $this->early = null;
                $this->wrongHub = ['kind' => 'city', 'code' => $code, 'for' => $place, 'section' => $inv?->whSection?->code ?? '—', 'color' => $inv?->whSection?->color,
                    'trip' => \App\Models\TripCity::where('deliverylog_id', $trip->id)->pluck('city')->join(', ')];
                $this->forceLoad = false;
                $this->scanResult('warning', "Other city: {$code} is for {$place}. Trip {$trip->trip_number} goes to {$this->wrongHub['trip']}.", $inv);

                return;
            } elseif (is_string($why) && str_starts_with($why, 'hub:')) {
                // the box goes to a partner hub, or is ours while this trip goes to a hub
                $inv = \App\Support\Boxes\SameNumber::best($code);
                $hubId = (int) substr($why, 4);
                $place = \Illuminate\Support\Str::title(trim($inv?->receiver_city.', '.$inv?->receiver_province, ', '));
                $goes = $hubId ? \App\Support\Hubs\HubAreas::name($hubId) : 'our own trucks (direct to the customer)';
                $this->early = null;
                $this->wrongHub = ['kind' => 'hub', 'code' => $code, 'for' => $place, 'home' => $goes, 'section' => $inv?->whSection?->code ?? '—', 'color' => $inv?->whSection?->color,
                    'trip' => $trip->trip_number];
                $this->forceLoad = false;
                $this->scanResult('warning', "Not for this trip: {$code} ({$place}) goes ".($hubId ? "to {$goes}" : 'with our own trucks').'.', $inv);

                return;
            } elseif ($why) {
                $this->scanResult('danger', $why, $this->invoicesMatching($code)->first());

                return;
            }
        }

        if (! $tripinvoice && static::$atHub && $box && \App\Support\Hubs\HubAreas::ready()
            && ($other = \App\Support\Hubs\HubAreas::hubOf($box)) && $other !== (int) Auth::user()?->logistichub_id) {
            // a box of another hub's area came to this hub by mistake
            $mine = \App\Support\Hubs\HubAreas::name((int) Auth::user()?->logistichub_id);
            $place = \Illuminate\Support\Str::title(trim($box->receiver_city.', '.$box->receiver_province, ', '));
            $this->scanResult('danger', "Not for {$mine}: {$code} is for ".\App\Support\Hubs\HubAreas::name($other)." ({$place}). Not loaded: put it aside and tell the office.", $box);

            return;
        }

        if (! $tripinvoice) {
            $elsewhere = Tripinvoice::with(['deliverylog:id,trip_number', 'invdata'])
                ->where('invoice', $code)
                ->where(fn ($q) => $q->where('is_delivered', false)->orWhereNull('is_delivered'))
                ->latest('id')
                ->first();

            $this->scanResult(
                'danger',
                $elsewhere
                    ? "{$code} belongs to trip {$elsewhere->deliverylog?->trip_number}, not {$trip->trip_number}."
                    : "{$code} is not on trip {$trip->trip_number}.",
                $elsewhere?->invdata ?? $this->invoicesMatching($code)->first(),
            );

            return;
        }

        if (static::$atHub && \App\Support\Shipping\Shipments::ready() && ($sea = \App\Support\Shipping\Shipments::stillAtSea($tripinvoice))) {
            $this->scanResult('danger', "{$code} is still on sea shipment {$sea->code}".($sea->eta ? ' (arriving about '.$sea->eta->format('M j').')' : '').'. Receive the container first (Scan app → Receive container).', $tripinvoice->invdata);

            return;
        }

        if ($tripinvoice->{$this->loadedColumn()}) {
            $who = $tripinvoice->loaded_by && $tripinvoice->loaded_by !== Auth::id() ? User::find($tripinvoice->loaded_by)?->first_name : null;
            $when = $tripinvoice->loaded_at ? \Illuminate\Support\Carbon::parse($tripinvoice->loaded_at)->format('g:i A') : null;
            $this->scanResult('warning', $sameOnTrip > 1 ? "Already loaded: all {$sameOnTrip} boxes with number {$code} are on the truck. Leave this one." : "{$code} was already loaded".($who ? " by {$who}" : '').($when ? " at {$when}" : '').'. Not counted again.', $tripinvoice->invdata);

            return;
        }

        $this->early = null;
        $this->spot = null;
        $this->wrongHub = null;
        $this->setInfo = null;
        if (! $this->skips('wrong_hub', $trip->id, $tripinvoice->invoice_id) && ($wrong = $this->wrongHubFor($trip, $tripinvoice))) {
            $this->wrongHub = $wrong;
            $this->scanResult('warning', "Wrong hub: {$code} is for {$wrong['for']} (section {$wrong['section']}). This trip goes to {$wrong['trip']}.", $tripinvoice->invdata);

            return;
        }
        if (! $this->skips('load_order', $trip->id, $tripinvoice->invoice_id) && ! $cityTrip && ($early = LoadOrder::tooEarly($trip, $tripinvoice, static::$atHub))) {
            $this->early = $early;
            $this->scanResult('warning', "Too early: {$code} is for stop {$early['stop']}".($early['place'] ? " ({$early['place']})" : '').'. It goes in later, nearer the door. Load stop '.$early['nextStop'].' first.', $tripinvoice->invdata);

            return;
        }
        $this->forceLoad = false;

        app(TripAssignment::class)->markLoaded($tripinvoice, atHub: static::$atHub);
        $tripinvoice->forceFill(['loaded_by' => Auth::id(), 'loaded_at' => now()])->saveQuietly();
        $this->spot = TripSorter::zoneMap($trip)[$tripinvoice->id] ?? null;
        // One container, more hubs: the hub that unloads last goes deep inside.
        if (! $this->spot && ! static::$atHub && \App\Support\Shipping\Shipments::ready()) {
            $this->spot = \App\Support\Shipping\Shipments::loadZone($trip->id);
        }
        if ($tripinvoice->invdata) {
            $this->setInfo = BoxSets::onTrip($tripinvoice->invdata, $trip, $this->tripColumn(), $this->loadedColumn());
        }

        $done = $sameOnTrip > 1 ? Tripinvoice::where($this->tripColumn(), $trip->id)->where('invoice', $code)->where($this->loadedColumn(), true)->count() : 0;
        $this->scanResult('success', "{$code} loaded".$this->whichSuffix($done, $sameOnTrip, $tripinvoice->invdata).'.', $tripinvoice->invdata);
    }

    /** The box's section is for another partner hub than the one this trip goes to. */
    protected function wrongHubFor(Deliverylog $trip, Tripinvoice $tripinvoice): ?array
    {
        $section = $tripinvoice->invdata?->whSection;
        $to = static::$atHub ? null : $trip->assigned_to;
        if (! $section || ! $section->logistichub_id || ! $to || (int) $section->logistichub_id === (int) $to) {
            return null;
        }

        return ['code' => $tripinvoice->invoice, 'for' => $section->name ?: $section->goesTo(), 'section' => $section->code, 'color' => $section->color,
            'trip' => $trip->destination?->hub_name ?? 'another hub'];
    }

    /**
     * Trip by city, every waiting box of its cities loaded, and room left: the best nearby city to top up with.
     *
     * @return array{room: int, key: string, city: string, province: string, boxes: int, days: int, section: ?string}|null
     */
    public function cityTopUp(): ?array
    {
        $trip = $this->selectedTrip();
        if (! $trip || static::$atHub || $trip->is_lock || ! \App\Support\Trips\CityTrips::isCityTrip($trip)) {
            return null;
        }
        $mine = \App\Models\TripCity::where('deliverylog_id', $trip->id)->get();
        $keys = $mine->map(fn ($c) => \Illuminate\Support\Str::lower((string) $c->province).'|'.$c->city_key)->flip();
        $ct = new \App\Support\Trips\CityTrips(Auth::user());
        $places = $ct->places();
        if ($places->contains(fn ($p) => isset($keys[$p['key']])) || ! Tripinvoice::where('deliverylog_id', $trip->id)->where('is_loaded', true)->exists()) {
            return null; // still boxes of its own cities to load
        }
        $cap = \App\Support\Trips\TripSpace::capacity($trip) ?? \App\Support\TruckSpace::capacity($trip->truck);
        $room = (int) floor($cap - \App\Support\Trips\TripSpace::used($trip));
        if ($room < 5) {
            return null;
        }
        $covered = $ct->covered();
        $prov = \Illuminate\Support\Str::lower((string) $mine->first()?->province);
        $best = $places->reject(fn ($p) => $p['unclear'] || isset($keys[$p['key']]) || isset($covered[$p['key']]) || $p['space'] > $room)
            ->sortBy(fn ($p) => [\Illuminate\Support\Str::lower($p['province']) === $prov ? 0 : 1, -$p['days'], -$p['boxes']])->first();
        if (! $best) {
            return null;
        }
        $section = Invoice::where('is_verified', true)->where('is_assigned', false)->where('receiver_city', 'like', '%'.\Illuminate\Support\Str::before($best['city'], ' ').'%')
            ->whereNotNull('wh_section_id')->with('whSection')->first()?->whSection?->code;

        return ['room' => $room, 'key' => $best['key'], 'city' => $best['city'], 'province' => $best['province'], 'boxes' => $best['boxes'], 'days' => $best['days'], 'section' => $section,
            'same' => \Illuminate\Support\Str::lower($best['province']) === $prov];
    }

    /** Add the suggested city: its boxes join when scanned. */
    public function addTopUpCity(string $key): void
    {
        $trip = $this->selectedTrip();
        $top = $this->cityTopUp();
        if (! $trip || ! $top || $top['key'] !== $key) {
            Notification::make()->title('That top-up is not possible any more.')->warning()->send();

            return;
        }
        \App\Models\TripCity::create(['deliverylog_id' => $trip->id, 'province' => $top['province'], 'city' => $top['city'],
            'city_key' => \Illuminate\Support\Str::after($key, '|'), 'planned_boxes' => $top['boxes']]);
        Notification::make()->title($top['city'].' added to '.$trip->trip_number.': scan its '.$top['boxes'].' boxes'.($top['section'] ? ' (section '.$top['section'].')' : ''))->success()->send();
    }

    /** Customers whose boxes are not all on the truck, for the Done screen. */
    public function openSets(): array
    {
        $trip = $this->selectedTrip();

        return $trip ? BoxSets::openOnTrip($trip, $this->tripColumn(), $this->loadedColumn()) : [];
    }

    /** Why a box of a set stays behind. */
    public function recordSplit(int $invoiceId, string $reason): bool
    {
        $trip = $this->selectedTrip();
        if (! $trip || ! array_key_exists($reason, SetSplit::REASONS)) {
            return false;
        }
        $ok = collect($this->openSets())->pluck('missing')->flatten(1)->contains('id', $invoiceId);
        if (! $ok) {
            return false;
        }
        $need = \App\Support\Trips\TripRules::need('split_set', Auth::user(), $trip->id, $invoiceId);
        $ctx = ['trip_id' => $trip->id, 'trip_number' => $trip->trip_number, 'invoice_id' => $invoiceId, 'box' => Invoice::whereKey($invoiceId)->value('invoice'), 'data' => ['split' => $reason]];
        if ($need === 'office') {
            \App\Support\Trips\TripRules::ask('split_set', Auth::user(), SetSplit::REASONS[$reason], $ctx);

            return true;
        }
        if ($need === 'reason' && ! SetSplit::where('invoice_id', $invoiceId)->where('deliverylog_id', $trip->id)->exists()) {
            \App\Support\Trips\TripRules::record('split_set', Auth::user(), SetSplit::REASONS[$reason], $ctx);
        }
        $split = SetSplit::updateOrCreate(['invoice_id' => $invoiceId, 'deliverylog_id' => $trip->id],
            ['reason' => $reason, 'user_id' => Auth::id(), 'set_key' => Invoice::whereKey($invoiceId)->value('set_key')]);
        if ($split->wasRecentlyCreated) {
            BoxSets::textRestFollows($split, $trip, $this->tripColumn(), $this->loadedColumn());
        }

        return true;
    }

    /** Who loaded how many boxes on this trip. */
    public function team(): array
    {
        $id = $this->data['deliverylog_id'] ?? null;
        if (! $id) {
            return [];
        }
        $counts = Tripinvoice::where($this->tripColumn(), $id)->where($this->loadedColumn(), true)->whereNotNull('loaded_by')
            ->selectRaw('loaded_by, count(*) n')->groupBy('loaded_by')->pluck('n', 'loaded_by');
        $names = User::whereIn('id', $counts->keys())->pluck('first_name', 'id');

        return $counts->sortDesc()->map(fn ($n, $uid) => ['name' => (int) $uid === Auth::id() ? 'You' : ($names[$uid] ?? '?'), 'n' => (int) $n, 'me' => (int) $uid === Auth::id()])->values()->all();
    }


    /** What to load next on the selected trip (null when the trip has no sorted stops). */
    public function loadNext(): ?array
    {
        $trip = $this->selectedTrip();

        return $trip ? LoadOrder::next($trip, static::$atHub) : null;
    }

    /** @return array{loaded: int, total: int} */
    public function progress(): array
    {
        $tripId = $this->data['deliverylog_id'] ?? null;

        if (! $tripId) {
            return ['loaded' => 0, 'total' => 0];
        }

        $query = Tripinvoice::where($this->tripColumn(), $tripId);

        return [
            'loaded' => (clone $query)->where($this->loadedColumn(), true)->count(),
            'total' => $query->count(),
            'last' => (clone $query)->where($this->loadedColumn(), true)->max('updated_at'),
        ];
    }

    /**
     * Progress of many trips in one database question (the Scan app trip list).
     *
     * @param  list<int>  $ids
     * @return array<int, array{loaded: int, total: int}>
     */
    public function progressMany(array $ids): array
    {
        if (! $ids) {
            return [];
        }
        $col = $this->tripColumn();
        $loaded = $this->loadedColumn();

        return Tripinvoice::whereIn($col, $ids)->selectRaw("{$col} as t, count(*) as total, sum(case when {$loaded} = 1 then 1 else 0 end) as loaded")
            ->groupBy($col)->toBase()->get()
            ->mapWithKeys(fn ($r) => [(int) $r->t => ['loaded' => (int) $r->loaded, 'total' => (int) $r->total]])->all();
    }

    public function household(): array
    {
        $tripId = (int) ($this->data['deliverylog_id'] ?? 0);

        return $this->householdRows($this->lastInvoice(), function (Invoice $box) use ($tripId): array {
            $onTrip = Tripinvoice::with('deliverylog:id,trip_number')->where('invoice_id', $box->id)->latest('id')->first();

            return [
                'trip' => $onTrip?->deliverylog?->trip_number,
                'done' => (bool) ($onTrip?->{$this->loadedColumn()} && (int) $onTrip->{$this->tripColumn()} === $tripId),
            ];
        });
    }

    public function photoStep(): ?string
    {
        return static::$atHub ? 'hub_load' : 'load';
    }

    public function photoContext(): array
    {
        return [
            'deliverylog_id' => $this->data['deliverylog_id'] ?? null,
            'warehouse_id' => Auth::user()?->warehouse_id,
            'logistichub_id' => Auth::user()?->logistichub_id,
        ];
    }

    public function appChoices(): Collection
    {
        return $this->tripOptionsQuery()->latest('id')->limit(60)->get()
            ->map(fn (Deliverylog $t) => ['id' => $t->id, 'name' => 'Trip '.$t->trip_number, 'active' => (bool) ($t->is_active ?? true),
                'sub' => $t->destination?->hub_name ? 'To '.$t->destination->hub_name : ($t->departure_date ? 'Leaves '.$t->departure_date : null)]);
    }
}
DISPATCH_FILE_END_5

# ---------------------------------------------------------------- app/Filament/Shared/PickStation.php
mkdir -p 'app/Filament/Shared'
cat > 'app/Filament/Shared/PickStation.php' <<'DISPATCH_FILE_END_6'
<?php

namespace App\Filament\Shared;

use App\Filament\Concerns\ScansInvoices;
use App\Models\Deliverylog;
use App\Models\User;
use App\Support\Trips\Picking;
use Filament\Pages\Page;
use Illuminate\Support\Collection;
use Illuminate\Support\Facades\Auth;
use Illuminate\Support\Facades\DB;

/** Scan app · Pick boxes: take each box of the trip from its section before Load truck (board 49). */
class PickStation extends Page
{
    use ScansInvoices;

    protected string $view = 'filament.pages.scaninvoice';

    protected static bool $shouldRegisterNavigation = false;

    /** The last result for the phone: title, why, tone, undo row. */
    public ?array $pick = null;

    protected function selectionField(): ?string
    {
        return 'deliverylog_id';
    }

    protected function selectionLabel(): string
    {
        return 'a trip';
    }

    public function trip(): ?Deliverylog
    {
        return Deliverylog::with('truck:id,plate_no', 'destination:id,hub_name')->where('logistichub_id', Auth::user()?->logistichub_id)
            ->find((int) ($this->data['deliverylog_id'] ?? 0));
    }

    protected function handleScan(string $code): void
    {
        $trip = $this->trip();
        $u = Auth::user();
        if (! $trip || ! $u instanceof User || ! Picking::isPicker($trip, $u)) {
            $this->pick = ['title' => 'This trip is not yours', 'why' => 'Take the trip first, or ask the office to add you.', 'tone' => 'bad', 'undo' => null, 'code' => $code];
            $this->scanResult('danger', $this->pick['title'], notify: false);

            return;
        }
        $r = Picking::scan($trip, $u, $code, $this->pinInvoice);
        if ($r['status'] === 'which') {
            $this->pick = null;
            $this->askWhich($code, $r['boxes']);

            return;
        }
        $this->pick = ['title' => $r['title'], 'why' => $r['why'], 'tone' => $r['tone'], 'undo' => $r['undo'], 'code' => $code,
            'section' => $r['invoice']?->whSection?->code, 'spot' => $r['invoice']?->whSpot?->code];
        $this->scanResult($r['status'], $r['title'].' · '.$r['why'], $r['invoice'], notify: false);
    }

    public function progress(): array
    {
        $trip = $this->trip();
        if (! $trip) {
            return ['loaded' => 0, 'total' => 0];
        }
        $p = Picking::progress($trip);

        return ['loaded' => $p['picked'], 'total' => $p['total']];
    }

    /** My trips and trips with no picker yet, of my warehouse or hub. */
    public function appChoices(): Collection
    {
        $u = Auth::user();
        $hub = (int) $u?->logistichub_id;
        if (! $hub || ! Picking::ready()) {
            return collect();
        }
        $trips = Picking::trips($hub);
        $pickers = DB::table('trip_pickers')->whereIn('deliverylog_id', $trips->pluck('id'))->get()->groupBy('deliverylog_id');

        return $trips->map(function (Deliverylog $t) use ($pickers, $u) {
            $ps = collect($pickers[$t->id] ?? []);
            $mine = $ps->contains('user_id', $u->id);
            if (! $mine && $ps->isNotEmpty()) {
                return null;
            }

            return ['id' => $t->id, 'name' => $t->trip_number, 'active' => true, 'mine' => $mine,
                'sub' => collect([$t->destination?->hub_name ? 'To '.$t->destination->hub_name : null, $t->truck?->plate_no, $mine && $ps->count() > 1 ? 'with '.User::whereIn('id', $ps->pluck('user_id')->reject(fn ($i) => (int) $i === $u->id))->pluck('first_name')->join(', ') : null])->filter()->join(' · ')];
        })->filter()->values();
    }

    /** Who picked what on this trip (the chips on the phone). */
    public function team(): array
    {
        $trip = $this->trip();
        if (! $trip) {
            return [];
        }
        $counts = Picking::rows($trip)->whereNotNull('picked_by')->selectRaw('picked_by, count(*) n')->groupBy('picked_by')->pluck('n', 'picked_by');
        $names = User::whereIn('id', $counts->keys())->pluck('first_name', 'id');

        return $counts->sortDesc()->map(fn ($n, $uid) => ['name' => (int) $uid === Auth::id() ? 'You' : ($names[$uid] ?? '?'), 'n' => (int) $n, 'me' => (int) $uid === Auth::id()])->values()->all();
    }

    public function groups(): array
    {
        $trip = $this->trip();

        return $trip ? Picking::groups($trip) : [];
    }

    public function household(): array
    {
        return [];
    }

    public function photoStep(): ?string
    {
        return null;
    }

    public function photoContext(): array
    {
        return [];
    }
}
DISPATCH_FILE_END_6

# ---------------------------------------------------------------- app/Filament/Shared/ReturnBoxesPage.php
mkdir -p 'app/Filament/Shared'
cat > 'app/Filament/Shared/ReturnBoxesPage.php' <<'DISPATCH_FILE_END_7'
<?php

namespace App\Filament\Shared;

use App\Filament\Concerns\ScansInvoices;
use App\Models\Deliverylog;
use App\Models\Tripinvoice;
use App\Services\TripAssignment;
use Filament\Forms\Components\Select;
use Filament\Pages\Page;
use Filament\Schemas\Schema;
use Filament\Support\Icons\Heroicon;
use Illuminate\Database\Eloquent\Builder;
use Illuminate\Support\Collection;
use Illuminate\Support\Facades\Auth;

/**
 * Scan station: when a truck comes back, staff scan every undelivered box off it.
 * Each box leaves the trip and goes back to the list of boxes waiting for a trip,
 * flagged "Returned", with the driver's reason kept.
 */
abstract class ReturnBoxesPage extends Page
{
    use ScansInvoices;

    protected string $view = 'filament.pages.scanload';

    protected static string|\BackedEnum|null $navigationIcon = Heroicon::OutlinedArrowUturnLeft;

    protected static ?string $navigationLabel = 'Return Boxes';

    protected static ?string $title = 'Return Boxes';

    /** Partner hub mode: boxes on the hub's own trips (deliveryloghub_id). */
    protected static bool $atHub = false;

    /** How many boxes were returned on this screen since it was opened. */
    public int $returnedCount = 0;

    public function mount(): void
    {
        $this->form->fill();
    }

    protected function tripColumn(): string
    {
        return static::$atHub ? 'deliveryloghub_id' : 'deliverylog_id';
    }

    /** Trips of this hub that still have undelivered boxes on them (open or already closed). */
    protected function tripOptionsQuery(): Builder
    {
        return Deliverylog::query()
            ->where('logistichub_id', Auth::user()->logistichub_id)
            ->whereHas(static::$atHub ? 'hubTripinvoices' : 'tripinvoices', fn (Builder $query) => $query->where('is_delivered', false))
            ->latest('id');
    }

    public function form(Schema $schema): Schema
    {
        return $schema
            ->statePath('data')
            ->components([
                Select::make('deliverylog_id')
                    ->label('Trip')
                    ->placeholder('Choose the trip that came back')
                    ->searchable()
                    ->live()
                    ->required()
                    ->afterStateUpdated(fn () => $this->reset('lastInvoiceId', 'lastStatus', 'lastMessage', 'returnedCount'))
                    ->options(fn () => $this->tripOptionsQuery()
                        ->withCount([(static::$atHub ? 'hubTripinvoices' : 'tripinvoices').' as left_count' => fn (Builder $query) => $query->where('is_delivered', false)])
                        ->get()
                        ->mapWithKeys(fn (Deliverylog $trip) => [
                            $trip->id => "{$trip->trip_number} · {$trip->left_count} not delivered",
                        ])),
            ]);
    }

    protected function selectionField(): ?string
    {
        return 'deliverylog_id';
    }

    protected function selectionLabel(): string
    {
        return 'a trip';
    }

    public function stationHeading(): string
    {
        return 'Return undelivered boxes';
    }

    public function stationDescription(): string
    {
        return 'Pick the trip that came back, then scan each box that was not delivered. It goes back to “Assign invoices” for the next trip.';
    }

    public function stationIcon(): string
    {
        return 'heroicon-o-arrow-uturn-left';
    }

    public function progressLabel(): string
    {
        return 'Undelivered boxes returned';
    }

    protected function handleScan(string $code): void
    {
        $trip = $this->tripOptionsQuery()->find($this->data['deliverylog_id'] ?? null);

        if (! $trip) {
            $this->scanResult('warning', 'Every box on that trip is delivered or already returned.');

            return;
        }

        // board 58: two boxes with this number still on the truck → Which one? (the receiver on the sticker)
        $box = $this->whichRow($code, Tripinvoice::with('invdata')->where($this->tripColumn(), $trip->id)->where('invoice', $code)->orderBy('id')->get(),
            fn ($r) => $r->invdata, fn ($r) => (bool) $r->is_delivered || (bool) $r->invdata?->is_returned);
        if ($box === false) {
            return;
        }

        if (! $box) {
            $invoice = $this->invoicesMatching($code)->first();

            $this->scanResult(
                $invoice?->is_returned ? 'warning' : 'danger',
                $invoice?->is_returned ? "{$code} was already returned." : "{$code} is not on trip {$trip->trip_number}.",
                $invoice,
            );

            return;
        }

        if ($box->is_delivered) {
            $this->scanResult('danger', "{$code} was delivered — keep it out of the warehouse stock.", $box->invdata);

            return;
        }

        $invoice = $box->invdata;
        $service = app(TripAssignment::class);
        static::$atHub ? $service->returnToHubInventory($box) : $service->returnToInventory($box);

        $this->returnedCount++;
        $this->scanResult('success', "{$code} returned to inventory.", $invoice);
    }

    /** @return array{loaded: int, total: int} */
    public function progress(): array
    {
        $tripId = $this->data['deliverylog_id'] ?? null;

        if (! $tripId) {
            return ['loaded' => 0, 'total' => 0];
        }

        $stillOnTruck = Tripinvoice::where($this->tripColumn(), $tripId)->where('is_delivered', false)->count();

        return ['loaded' => $this->returnedCount, 'total' => $this->returnedCount + $stillOnTruck];
    }

    /** The driver's reason for the last scanned box, shown on the result card. */
    public function lastReason(): ?string
    {
        $attempt = $this->lastInvoice()?->latestDeliveryAttempt;

        return $attempt ? $attempt->reason->getLabel().($attempt->note ? " — “{$attempt->note}”" : '') : null;
    }

    public function household(): array
    {
        return [];
    }

    public function photoStep(): ?string
    {
        return 'return';
    }

    public function photoContext(): array
    {
        return [
            'deliverylog_id' => $this->data['deliverylog_id'] ?? null,
            'warehouse_id' => Auth::user()?->warehouse_id,
            'logistichub_id' => Auth::user()?->logistichub_id,
        ];
    }

    public function appChoices(): Collection
    {
        // closed trips can still have boxes to return, so they always count as open here
        return $this->tripOptionsQuery()->limit(60)->get()
            ->map(fn ($t) => ['id' => $t->id, 'name' => 'Trip '.$t->trip_number, 'active' => true, 'sub' => $t->departure_date ? 'Left '.$t->departure_date : null]);
    }
}
DISPATCH_FILE_END_7

# ---------------------------------------------------------------- app/Filament/Shared/SectionCountStation.php
mkdir -p 'app/Filament/Shared'
cat > 'app/Filament/Shared/SectionCountStation.php' <<'DISPATCH_FILE_END_8'
<?php

namespace App\Filament\Shared;

use App\Filament\Concerns\ScansInvoices;
use App\Models\Boxes\WhCountScan;
use App\Models\Boxes\WhSection;
use App\Models\User;
use App\Support\Boxes\SectionCount;
use App\Support\Boxes\Sections;
use Filament\Pages\Page;
use Illuminate\Support\Collection;
use Illuminate\Support\Facades\Auth;

/** Scan app · Count a section: scan the boxes on it; boxes from elsewhere are moved here. */
class SectionCountStation extends Page
{
    use ScansInvoices;

    protected string $view = 'filament.pages.scaninvoice';

    protected static bool $shouldRegisterNavigation = false;

    public ?array $route = null;

    protected function selectionField(): ?string
    {
        return 'wh_section_id';
    }

    protected function selectionLabel(): string
    {
        return 'a section';
    }

    protected function section(): ?WhSection
    {
        return Sections::of(Auth::user()?->warehouse_id)->firstWhere('id', (int) ($this->data['wh_section_id'] ?? 0));
    }

    protected function handleScan(string $code): void
    {
        $s = $this->section();
        if (! $s) {
            $this->scanResult('danger', 'That section is not in your warehouse.');

            return;
        }
        if (str_starts_with($code, 'SEC-')) {
            $this->scanResult('warning', 'That is a section label. Scan the boxes on this section.');

            return;
        }
        $r = SectionCount::scan(SectionCount::open($s), $code, Auth::user()?->warehouse_id, $this->pinInvoice);
        if ($r['status'] === 'which') {
            $this->askWhich($code, $r['boxes']);

            return;
        }
        $this->route = Sections::tile($s);
        $this->scanResult($r['status'], $r['message'], $r['invoice']);
    }

    public function progress(): array
    {
        $s = $this->section();
        if (! $s) {
            return ['loaded' => 0, 'total' => 0];
        }
        $c = SectionCount::current($s);
        if (! $c) {
            return ['loaded' => 0, 'total' => SectionCount::expected($s)->count()];
        }
        $r = SectionCount::result($c);

        return ['loaded' => $r['found'], 'total' => max($r['expected'], $r['found'])];
    }

    /** Done screen: what is missing, and close the count. */
    public function countResult(): ?array
    {
        $s = $this->section();

        $c = $s ? SectionCount::current($s) : null;

        return $c ? SectionCount::result($c) + ['code' => $s->code] : null;
    }

    public function closeCount(): ?array
    {
        $s = $this->section();

        $c = $s ? SectionCount::current($s) : null;

        return $c ? SectionCount::finish($c) : null;
    }

    public function team(): array
    {
        $s = $this->section();
        if (! $s) {
            return [];
        }
        $c = SectionCount::current($s);
        if (! $c) {
            return [];
        }
        $counts = WhCountScan::where('wh_count_id', $c->id)->whereNotNull('user_id')->selectRaw('user_id, count(*) n')->groupBy('user_id')->pluck('n', 'user_id');
        $names = User::whereIn('id', $counts->keys())->pluck('first_name', 'id');

        return $counts->sortDesc()->map(fn ($n, $uid) => ['name' => (int) $uid === Auth::id() ? 'You' : ($names[$uid] ?? '?'), 'n' => (int) $n, 'me' => (int) $uid === Auth::id()])->values()->all();
    }

    public function household(): array
    {
        return [];
    }

    public function photoStep(): ?string
    {
        return null;
    }

    public function photoContext(): array
    {
        return [];
    }

    public function appChoices(): Collection
    {
        return Sections::of(Auth::user()?->warehouse_id)->map(fn (WhSection $s) => [
            'id' => $s->id, 'name' => 'Section '.$s->code.' · '.$s->name, 'active' => true,
            'sub' => SectionCount::expected($s)->count().' boxes here',
        ])->values();
    }
}
DISPATCH_FILE_END_8

# ---------------------------------------------------------------- app/Filament/Shared/Shipping/ReturnReceiveStation.php
mkdir -p 'app/Filament/Shared/Shipping'
cat > 'app/Filament/Shared/Shipping/ReturnReceiveStation.php' <<'DISPATCH_FILE_END_9'
<?php

namespace App\Filament\Shared\Shipping;

use App\Filament\Concerns\ScansInvoices;
use App\Models\Shipping\ReturnShipment;
use App\Support\Boxes\Sections;
use App\Support\Shipping\Returns;
use Filament\Pages\Page;
use Illuminate\Support\Collection;
use Illuminate\Support\Facades\Auth;

/** Scan app · Receive returns: the warehouse scans in the boxes of a return shipment. */
class ReturnReceiveStation extends Page
{
    use ScansInvoices;

    protected string $view = 'filament.pages.scaninvoice';

    protected static bool $shouldRegisterNavigation = false;

    public ?array $route = null;

    protected function selectionField(): ?string
    {
        return 'return_shipment_id';
    }

    protected function selectionLabel(): string
    {
        return 'a return shipment';
    }

    protected function shipment(): ?ReturnShipment
    {
        return ReturnShipment::with('hub:id,hub_name')->where('status', 'sent')->find($this->data['return_shipment_id'] ?? null);
    }

    protected function handleScan(string $code): void
    {
        $rs = $this->shipment();
        if (! $rs) {
            $this->scanResult('danger', 'That return shipment is not open for receiving.');

            return;
        }
        $r = Returns::receive($rs, $code, Auth::user()?->warehouse_id, $this->pinInvoice);
        if ($r['status'] === 'which') {
            $this->askWhich($code, $r['boxes']);

            return;
        }
        $this->route = Sections::tile($r['box']?->invoice?->whSection);
        $this->scanResult($r['status'], $r['message'], $r['box']?->invoice);
    }

    public function progress(): array
    {
        $rs = $this->shipment();
        if (! $rs) {
            return ['loaded' => 0, 'total' => 0];
        }
        $c = Returns::counts($rs);

        return ['loaded' => $c['back'], 'total' => $c['total']];
    }

    public function household(): array
    {
        return [];
    }

    public function photoStep(): ?string
    {
        return null;
    }

    public function photoContext(): array
    {
        return [];
    }

    public function appChoices(): Collection
    {
        return ReturnShipment::with('hub:id,hub_name')->where('status', 'sent')->latest('id')->limit(30)->get()
            ->map(fn ($rs) => ['id' => $rs->id, 'name' => $rs->code.' from '.($rs->hub?->hub_name ?? ''), 'active' => true,
                'sub' => collect([$rs->van_no ? 'Van '.$rs->van_no : null, $rs->eta ? 'ETA '.$rs->eta->format('M j') : null])->filter()->join(' · ') ?: null]);
    }
}
DISPATCH_FILE_END_9

# ---------------------------------------------------------------- app/Filament/Shared/Shipping/ShipmentScanStation.php
mkdir -p 'app/Filament/Shared/Shipping'
cat > 'app/Filament/Shared/Shipping/ShipmentScanStation.php' <<'DISPATCH_FILE_END_10'
<?php

namespace App\Filament\Shared\Shipping;

use App\Filament\Concerns\PlacesOnHubTrips;
use App\Filament\Concerns\ScansInvoices;
use App\Models\Shipping\SeaShipment;
use App\Models\Shipping\SeaShipmentScan;
use App\Models\Tripinvoice;
use App\Models\User;
use App\Support\Shipping\Shipments;
use App\Support\Tracking\Tracker;
use Filament\Pages\Page;
use Illuminate\Database\Eloquent\Builder;
use Illuminate\Support\Carbon;
use Illuminate\Support\Collection;
use Illuminate\Support\Facades\Auth;

/**
 * Scan station for a sea shipment, used by the Scan app: Port check (the boxes handed over at
 * the port) or Receive (the partner hub scans the container in).
 */
abstract class ShipmentScanStation extends Page
{
    use PlacesOnHubTrips;
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
    abstract protected function shipments(): Builder;

    protected function selected(): ?SeaShipment
    {
        return $this->shipments()->find($this->data['sea_shipment_id'] ?? null);
    }

    /** Receive: the trips of this hub's stop. Port check: every trip in the container. */
    protected function myTripIds(SeaShipment $s): array
    {
        if (static::$step !== 'received') {
            return Shipments::tripIds($s);
        }
        $stop = Shipments::stopFor($s, (int) Auth::user()?->logistichub_id) ?? Shipments::currentStop($s);

        return $stop ? [(int) $stop->deliverylog_id] : [];
    }

    protected function handleScan(string $code): void
    {
        $this->setInfo = null;
        $this->route = null;
        $this->hubTrip = null;
        $s = $this->selected();
        if (! $s) {
            $this->scanResult('danger', 'That shipment is not open for this scan any more.');

            return;
        }
        // two boxes with this number in the shipment: the one not scanned yet first (board 57)
        $rows = Tripinvoice::with('invdata.whSection')->whereIn('deliverylog_id', $this->myTripIds($s))->where('invoice', $code)->latest('id')->get();
        $got = $rows->isEmpty() ? collect() : SeaShipmentScan::where('sea_shipment_id', $s->id)->whereIn('invoice_id', $rows->pluck('invoice_id'))->where('step', static::$step)->pluck('invoice_id');
        $row = $this->whichRow($code, $rows->sortBy('id')->values(), fn ($r) => $r->invdata, fn ($r) => $got->contains($r->invoice_id)); // board 58
        if ($row === false) {
            return;
        }
        $same = $rows->count();
        if (! $row) {
            $other = $this->invoicesMatching($code)->first();
            // One container, more hubs: the box is for another stop.
            $theirs = Tripinvoice::whereIn('deliverylog_id', Shipments::tripIds($s))->where('invoice', $code)->latest('id')->first();
            $stop = $theirs ? Shipments::stopOf($s, (int) $theirs->deliverylog_id) : null;
            if ($stop && $stop->received_at) {
                $this->scanResult('warning', "{$code} was already received at ".($stop->hub?->hub_name ?? 'the hub before').'. Not counted again.', $other);
            } elseif ($stop) {
                $this->route = ['kind' => 'wrong', 'code' => '→', 'name' => 'For '.($stop->hub?->hub_name ?? 'the next hub').': leave it in the container', 'color' => '#7a4fb0', 'why' => 'Stop '.$stop->stop.'. Not counted, not missing.'];
                $this->scanResult('warning', "{$code} is for ".($stop->hub?->hub_name ?? 'the next hub').': leave it in the container.', $other);
            } else {
                $this->scanResult('danger', "{$code} is not in shipment {$s->code}.", $other);
            }

            return;
        }
        if (static::$step === 'port' && ! $row->is_loaded) {
            $this->scanResult('warning', "{$code} was never scanned onto trip {$s->trip?->trip_number} at the warehouse. Check where it came from.", $row->invdata);

            return;
        }
        $prev = SeaShipmentScan::where('sea_shipment_id', $s->id)->where('invoice_id', $row->invoice_id)->where('step', static::$step)->first();
        if ($prev) {
            $who = $prev->user_id && $prev->user_id !== Auth::id() ? User::find($prev->user_id)?->first_name : null;
            $this->scanResult('warning', $same > 1 ? "Already scanned: all {$same} boxes with number {$code}. Leave this one." : "{$code} was already scanned".($who ? " by {$who}" : '').($prev->created_at ? ' at '.Carbon::parse($prev->created_at)->format('g:i A') : '').'. Not counted again.', $row->invdata);

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
        // received at the partner hub: the box goes on the hub's trip of its city (board 45d)
        $placed = static::$step === 'received' ? $this->placeOnHubTrip($row) : null;
        $this->scanResult('success', "{$code} ".(static::$step === 'port' ? 'handed over at the port' : 'received').$this->whichSuffix($got->count() + 1, $same, $row->invdata).'.'.($placed ? ' → '.$placed['trip'] : ''), $row->invdata);
    }

    public function progress(): array
    {
        $s = $this->selected();
        if (! $s) {
            return ['loaded' => 0, 'total' => 0];
        }

        return [
            'loaded' => SeaShipmentScan::where('sea_shipment_id', $s->id)->where('step', static::$step)
                ->whereIn('invoice_id', Tripinvoice::whereIn('deliverylog_id', $this->myTripIds($s))->select('invoice_id'))->count(),
            'total' => Tripinvoice::whereIn('deliverylog_id', $this->myTripIds($s))->where('is_loaded', true)->count(),
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
        $stop = $s ? (Shipments::stopFor($s, (int) Auth::user()?->logistichub_id) ?? Shipments::currentStop($s)) : null;

        return ['deliverylog_id' => $stop?->deliverylog_id ?? $s?->deliverylog_id, 'logistichub_id' => $stop?->logistichub_id ?? $s?->logistichub_id];
    }

    /** Receive container, Done screen: received, missing, and Finish receiving. */
    public function receiveResult(): ?array
    {
        $s = static::$step === 'received' ? $this->selected() : null;
        if (! $s) {
            return null;
        }
        $p = $this->progress();
        $missing = Tripinvoice::whereIn('deliverylog_id', $this->myTripIds($s))->where('is_loaded', true)
            ->whereNotIn('invoice_id', SeaShipmentScan::where('sea_shipment_id', $s->id)->where('step', 'received')->select('invoice_id'))->limit(30)->pluck('invoice');
        $stop = Shipments::stopFor($s, (int) Auth::user()?->logistichub_id) ?? Shipments::currentStop($s);
        $next = Shipments::stops($s)->first(fn ($x) => $stop && $x->stop > $stop->stop && ! $x->received_at);

        return ['got' => $p['loaded'], 'of' => $p['total'], 'finished' => $s->status === 'received' || (bool) $stop?->received_at,
            'next' => $next?->hub?->hub_name,
            'missing' => $missing->map(fn ($code) => ['code' => $code, 'sub' => 'Not scanned off the container'])->all()];
    }

    public function finishReceiving(): ?int
    {
        $s = static::$step === 'received' ? $this->selected() : null;

        return $s ? Shipments::finishReceiving($s, null, Shipments::stopFor($s, (int) Auth::user()?->logistichub_id) ? (int) Auth::user()?->logistichub_id : null) : null;
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
DISPATCH_FILE_END_10

# ---------------------------------------------------------------- app/Filament/Shared/Shipping/TruckReceiveStation.php
mkdir -p 'app/Filament/Shared/Shipping'
cat > 'app/Filament/Shared/Shipping/TruckReceiveStation.php' <<'DISPATCH_FILE_END_11'
<?php

namespace App\Filament\Shared\Shipping;

use App\Filament\Concerns\PlacesOnHubTrips;
use App\Filament\Concerns\ScansInvoices;
use App\Models\Deliverylog;
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
    use PlacesOnHubTrips;
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
        $this->hubTrip = null;
        $trip = $this->selected();
        $hub = $this->hubId();
        if (! $trip) {
            $this->scanResult('danger', 'Pick the truck that arrived first.');

            return;
        }
        // two boxes with this number on the truck: the one not received yet first (board 57)
        $rows = Tripinvoice::with('invdata.whSection')->where('deliverylog_id', $trip->id)->where('logistichub_id', $hub)->where('invoice', $code)->latest('id')->get();
        $got = $rows->isEmpty() ? collect() : TruckReceiptScan::where('deliverylog_id', $trip->id)->whereIn('invoice_id', $rows->pluck('invoice_id'))->pluck('invoice_id');
        $row = $this->whichRow($code, $rows->sortBy('id')->values(), fn ($r) => $r->invdata, fn ($r) => $got->contains($r->invoice_id)); // board 58
        if ($row === false) {
            return;
        }
        $same = $rows->count();
        if (! $row) {
            $other = Tripinvoice::where('invoice', $code)->latest('id')->first();
            $sea = $other ? Shipments::forTrip((int) $other->deliverylog_id) : null;
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
            $this->scanResult('warning', $same > 1 ? "Already received: all {$same} boxes with number {$code}. Leave this one." : "{$code} was already received".($who ? " by {$who}" : '').($prev->created_at ? ' at '.Carbon::parse($prev->created_at)->format('g:i A') : '').'. Not counted again.', $row->invdata);

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
        // the box goes on the hub's open trip of its city: full → a new hub trip (Add anyway offered)
        $placed = $this->placeOnHubTrip($row);
        $this->scanResult('success', "{$code} received at your hub".$this->whichSuffix($got->count() + 1, $same, $row->invdata).'.'.($placed ? ' → '.$placed['trip'] : '').($wasLoaded ? '' : ' It was not scanned onto the truck in Manila.'), $row->invdata);
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
DISPATCH_FILE_END_11

# ---------------------------------------------------------------- app/Filament/Shared/Shipping/WrongHubPage.php
mkdir -p 'app/Filament/Shared/Shipping'
cat > 'app/Filament/Shared/Shipping/WrongHubPage.php' <<'DISPATCH_FILE_END_12'
<?php

namespace App\Filament\Shared\Shipping;

use App\Models\Shipping\WrongHubBox;
use App\Support\Shipping\Shipments;
use App\Support\Shipping\WrongHub;
use App\Support\Tracking\Tracker;
use BackedEnum;
use Filament\Facades\Filament;
use Filament\Notifications\Notification;
use Filament\Pages\Page;
use Filament\Support\Icons\Heroicon;
use Illuminate\Support\Facades\Auth;
use Livewire\Attributes\Url;

/** Wrong hub & returns: boxes at a partner hub that are not theirs, or go back. Partner hub and Admin. */
abstract class WrongHubPage extends Page
{
    protected string $view = 'filament.shipping.wrong-hub';

    protected static string|BackedEnum|null $navigationIcon = Heroicon::OutlinedArrowUturnLeft;

    protected static ?string $navigationLabel = 'Wrong hub & returns';

    protected static ?string $title = 'Wrong hub & returns';

    protected static ?string $slug = 'wrong-hub';

    /** Warehouse panel: the boxes coming back to the warehouse, from every hub (view only). */
    protected static bool $comingBack = false;

    #[Url]
    public string $tab = 'list';

    public string $code = '';

    public string $reason = 'refused';

    public string $note = '';

    public static function canAccess(): bool
    {
        return Shipments::ready() && Tracker::hubFor(Auth::user(), Filament::getCurrentPanel()?->getId()) !== false;
    }

    protected function hub(): ?int
    {
        if (static::$comingBack) {
            return null;
        }
        $h = Tracker::hubFor(Auth::user(), Filament::getCurrentPanel()?->getId());

        return is_int($h) ? $h : null;
    }

    protected function find(int $id): ?WrongHubBox
    {
        return WrongHubBox::with('correctHub', 'tripinvoice')->when($this->hub(), fn ($q, $h) => $q->where('logistichub_id', $h))->find($id);
    }

    /** Board 58: two boxes at the hub with this number → Which one? */
    public ?array $which = null;

    public function chooseWhich(int $invoiceId): void
    {
        if ($this->which && collect($this->which['options'])->contains('id', $invoiceId)) {
            $this->addBox($invoiceId);
        }
    }

    public function cancelWhich(): void
    {
        $this->which = null;
    }

    public function addBox(?int $pin = null): void
    {
        abort_if(static::$comingBack, 403);
        $hub = $this->hub() ?? (int) Auth::user()?->logistichub_id;
        $this->validate(['code' => 'required|string|max:40', 'reason' => 'required|in:'.implode(',', array_keys(WrongHubBox::REASONS))]);
        $code = mb_strtoupper(trim($this->code));
        $this->which = null;
        $open = WrongHub::candidates($hub, $code);
        if (! $pin && $open->count() > 1) {
            $this->which = ['code' => $code, 'options' => $open->pluck('invdata')->filter()->map(fn ($i) => \App\Support\Boxes\SameNumber::choice($i))->values()->all()];

            return;
        }
        $w = WrongHub::add($hub, $code, $this->reason, trim($this->note) ?: null, $pin);
        if (! $w) {
            $this->addError('code', 'That box is not at your hub (or it is already delivered).');

            return;
        }
        $this->reset('code', 'note');
        Notification::make()->title($w->invoice?->invoice.' added')->success()->send();
    }

    public function sendToHub(int $id): void
    {
        abort_if(static::$comingBack, 403);
        $w = $this->find($id);
        if ($w && $w->status === 'waiting' && WrongHub::sendToHub($w)) {
            Notification::make()->title('Handed over to '.$w->correctHub?->hub_name)->success()->send();
        }
    }

    /** Put the box on this hub's return shipment to the warehouse. */
    public function sendBack(int $id): void
    {
        abort_if(static::$comingBack, 403);
        $w = $this->find($id);
        if ($w && $w->status === 'waiting') {
            $rs = \App\Support\Shipping\Returns::add($w);
            Notification::make()->title($w->invoice?->invoice.' is on return shipment '.$rs->code)->body('Send the return shipment when it is ready (tab Return shipment).')->success()->send();
        }
    }

    public function takeOff(int $id): void
    {
        abort_if(static::$comingBack, 403);
        $w = $this->find($id);
        if ($w) {
            \App\Support\Shipping\Returns::remove($w);
        }
    }

    public array $rf = ['van_no' => '', 'seal_no' => '', 'vessel' => '', 'bl_no' => '', 'eta' => '', 'cost' => '', 'note' => ''];

    protected function openReturn(): ?\App\Models\Shipping\ReturnShipment
    {
        $hub = $this->hub() ?? (int) Auth::user()?->logistichub_id;

        return \App\Models\Shipping\ReturnShipment::where('logistichub_id', $hub)->where('status', 'preparing')->latest('id')->first();
    }

    public function saveReturn(): void
    {
        abort_if(static::$comingBack, 403);
        $rs = $this->openReturn();
        if (! $rs) {
            return;
        }
        $this->rf['cost'] = str_replace([',', '₱', ' '], '', (string) $this->rf['cost']);
        $this->validate(['rf.van_no' => 'nullable|string|max:20', 'rf.seal_no' => 'nullable|string|max:30', 'rf.vessel' => 'nullable|string|max:80',
            'rf.bl_no' => 'nullable|string|max:40', 'rf.eta' => 'nullable|date', 'rf.cost' => 'nullable|numeric|min:0', 'rf.note' => 'nullable|string|max:300']);
        $rs->update(collect($this->rf)->map(fn ($v) => $v === '' ? null : $v)->all());
        Notification::make()->title('Saved')->success()->send();
    }

    public function sendReturn(): void
    {
        abort_if(static::$comingBack, 403);
        $rs = $this->openReturn();
        if ($rs && \App\Support\Shipping\Returns::send($rs)) {
            Notification::make()->title($rs->code.' sent to the warehouse')->success()->send();
        }
    }

    /** Warehouse: every box was scanned in (Scan app → Receive returns). */
    public function finishReturn(int $id): void
    {
        abort_unless(static::$comingBack, 403);
        $rs = \App\Models\Shipping\ReturnShipment::where('status', 'sent')->find($id);
        if ($rs) {
            $made = \App\Support\Shipping\Returns::finish($rs);
            Notification::make()->title($rs->code.' received')->body($made ? $made.' missing: an Invoice Issue was opened for each.' : 'Every box arrived.')->success()->send();
        }
    }

    public function setHub(int $id, ?int $hubId): void
    {
        abort_if(static::$comingBack, 403);
        $w = $this->find($id);
        if ($w && $w->status === 'waiting') {
            $w->update(['correct_hub_id' => $hubId ?: null]);
        }
    }

    protected function getViewData(): array
    {
        $hub = $this->hub();
        $list = WrongHubBox::with(['invoice', 'correctHub', 'hub', 'shipment'])->when($hub, fn ($q) => $q->where('logistichub_id', $hub))
            ->orderByRaw("case when status = 'waiting' then 0 else 1 end")->latest('id')->limit(100)->get();

        $rows = $list->map(fn ($w) => ['w' => $w, 'tip' => WrongHub::suggestion($w)]);
        if (static::$comingBack) {
            $rows = $rows->filter(fn ($r) => in_array($r['w']->status, ['back', 'returning'], true) || ($r['w']->status === 'waiting' && $r['tip']['way'] === 'back'))->values();
        }
        $open = ! static::$comingBack && \App\Support\Shipping\Returns::ready() ? $this->openReturn() : null;
        if ($open && $this->tab === 'return' && ! array_filter($this->rf)) {
            foreach (array_keys($this->rf) as $k) {
                $this->rf[$k] = (string) ($k === 'eta' ? $open->eta?->toDateString() : $open->{$k});
            }
        }

        return [
            'comingBack' => static::$comingBack,
            'openReturn' => $open,
            'openBoxes' => $open ? $open->boxes()->with('invoice')->get() : collect(),
            'returns' => \App\Support\Shipping\Returns::ready() ? \App\Models\Shipping\ReturnShipment::with('hub:id,hub_name')->withCount('boxes')
                ->when(! static::$comingBack, fn ($q) => $q->where('logistichub_id', $this->hub() ?? (int) Auth::user()?->logistichub_id))
                ->when(static::$comingBack, fn ($q) => $q->whereIn('status', ['sent', 'received']))
                ->latest('id')->limit(20)->get()->map(fn ($rs) => ['rs' => $rs, 'c' => \App\Support\Shipping\Returns::counts($rs)]) : collect(),
            'list' => $rows,
            'report' => $this->tab === 'report' ? WrongHub::report($hub) : null,
            'reasons' => WrongHubBox::REASONS,
            'hubs' => \App\Models\Logistichub::where('is_company', true)->orderBy('hub_name')->pluck('hub_name', 'id'),
            'isAdmin' => $hub === null && ! static::$comingBack,
        ];
    }
}
DISPATCH_FILE_END_12

# ---------------------------------------------------------------- app/Filament/Shared/UnloadContainerPage.php
mkdir -p 'app/Filament/Shared'
cat > 'app/Filament/Shared/UnloadContainerPage.php' <<'DISPATCH_FILE_END_13'
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
                    ->directory('boxissue')
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
                    ->directory('unmanifested')
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
DISPATCH_FILE_END_13

# ---------------------------------------------------------------- app/Filament/Shared/WarehouseTripScanPage.php
mkdir -p 'app/Filament/Shared'
cat > 'app/Filament/Shared/WarehouseTripScanPage.php' <<'DISPATCH_FILE_END_14'
<?php

namespace App\Filament\Shared;

use App\Filament\Concerns\ScansInvoices;
use App\Models\Invoice;
use App\Models\Whtripinvoice;
use Filament\Forms\Components\Select;
use Filament\Pages\Page;
use Filament\Schemas\Schema;
use Illuminate\Database\Eloquent\Builder;
use Illuminate\Support\Collection;
use Illuminate\Support\Facades\Auth;
use Illuminate\Support\Facades\DB;

/**
 * Scan station for warehouse-to-warehouse trips.
 * Whloaded loads boxes at the origin, Whunloaded receives them at the destination.
 */
abstract class WarehouseTripScanPage extends Page
{
    use ScansInvoices;

    protected string $view = 'filament.pages.scanload';

    /** true = receiving at the destination warehouse, false = loading at the origin. */
    protected static bool $unloading = false;

    abstract protected function tripOptionsQuery(): Builder;

    use \App\Filament\Concerns\BypassesTripRules;

    /** "Load it anyway" after "Not for this warehouse". */
    public bool $forceLoad = false;

    public ?array $wrongHub = null;

    public ?array $early = null;

    protected function tripKind(): string
    {
        return 'transfer';
    }

    public function mount(): void
    {
        $this->form->fill();
    }

    public function form(Schema $schema): Schema
    {
        return $schema
            ->statePath('data')
            ->components([
                Select::make('deliverylog_id')
                    ->label('Trip')
                    ->placeholder(static::$unloading ? 'Choose the arriving trip' : 'Choose the trip you are loading')
                    ->searchable()
                    ->live()
                    ->required()
                    ->afterStateUpdated(fn () => $this->reset('lastInvoiceId', 'lastStatus', 'lastMessage'))
                    ->options(fn () => $this->tripOptionsQuery()->latest('id')->pluck('trip_number', 'id')),
            ]);
    }

    protected function selectionField(): ?string
    {
        return 'deliverylog_id';
    }

    protected function selectionLabel(): string
    {
        return 'a trip';
    }

    protected function doneColumn(): string
    {
        return static::$unloading ? 'is_unloaded' : 'is_loaded';
    }

    protected function handleScan(string $code): void
    {
        $trip = $this->tripOptionsQuery()->find($this->data['deliverylog_id'] ?? null);

        if (! $trip) {
            $this->scanResult('danger', 'That trip is not available any more.');

            return;
        }

        // two boxes with this number: the one on this trip and not done yet first (board 57)
        $matches = $this->invoicesMatching($code);
        $rows = $matches->isEmpty() ? collect() : Whtripinvoice::with('whdeliverylog:id,trip_number')->whereIn('invoice_id', $matches->pluck('id'))->latest('id')->get();
        // board 58: two boxes with this number on this trip still to do → Which one?
        $here = $rows->filter(fn ($r) => (int) $r->whdeliverylog_id === (int) $trip->id)->sortBy('id')->values();
        $row = $here->isNotEmpty()
            ? $this->whichRow($code, $here, fn ($r) => $matches->firstWhere('id', $r->invoice_id), fn ($r) => (bool) $r->{$this->doneColumn()})
            : $rows->first();
        if ($row === false) {
            return;
        }
        $invoice = $row ? $matches->firstWhere('id', $row->invoice_id) : $matches->first();

        if (! $row) {
            $this->scanResult('danger', "{$code} is not on any warehouse trip.", $invoice);

            return;
        }

        if ((int) $row->whdeliverylog_id !== (int) $trip->id) {
            $this->scanResult('danger', "{$code} belongs to trip {$row->whdeliverylog?->trip_number}, not {$trip->trip_number}.", $invoice);

            return;
        }

        // Two warehouses: only boxes that the destination warehouse delivers go on its transfer.
        $this->wrongHub = null;
        $this->bypass = null;
        if (! static::$unloading && ! $this->forceLoad && ! \App\Support\Trips\TripRules::isApproved('wrong_hub', $trip->id, $invoice->id)
            && ($home = \App\Support\Warehouses\Coverage::home($invoice)) && (int) $home !== (int) $trip->warehouse_id) {
            $dest = \App\Support\Warehouses\Coverage::name((int) $trip->warehouse_id);
            $place = \Illuminate\Support\Str::title(trim($invoice->receiver_city.', '.$invoice->receiver_province, ', '));
            $this->wrongHub = ['kind' => 'wh', 'code' => $code, 'for' => $place, 'section' => $invoice->whSection?->code ?? '—', 'color' => $invoice->whSection?->color,
                'trip' => $dest, 'home' => \App\Support\Warehouses\Coverage::name($home)];
            $this->scanResult('warning', "Not for {$dest}: {$code} is for {$place}, delivered from ".$this->wrongHub['home'].'.', $invoice);

            return;
        }
        $this->forceLoad = false;

        if (static::$unloading && ! $row->is_loaded) {
            $this->scanResult('warning', "{$code} was never scanned onto the truck. Check with the loading warehouse.", $invoice);

            return;
        }

        if ($row->{$this->doneColumn()}) {
            $who = ! static::$unloading && $row->loaded_by && $row->loaded_by !== Auth::id() ? \App\Models\User::find($row->loaded_by)?->first_name : null;
            $this->scanResult('warning', $here->count() > 1 ? "Already done: all {$here->count()} boxes with number {$code}. Leave this one." : "{$code} was already ".(static::$unloading ? 'received' : 'loaded').($who ? " by {$who}" : '').'. Not counted again.', $invoice);

            return;
        }

        DB::transaction(function () use ($row, $invoice, $trip): void {
            $row->update([$this->doneColumn() => true] + (static::$unloading ? [] : ['loaded_by' => Auth::id(), 'loaded_at' => now()]));

            // The box now physically sits in the destination warehouse.
            if (static::$unloading) {
                $invoice->update(['warehouse_id' => $trip->warehouse_id]);
            }
        });

        $this->scanResult('success', "{$code} ".(static::$unloading ? 'received' : 'loaded')
            .$this->whichSuffix($here->filter(fn ($r) => $r->{$this->doneColumn()} || $r->is($row))->count(), $here->count(), $invoice).'.', $invoice);
    }

    /** @return array{loaded: int, total: int} */
    public function progress(): array
    {
        $tripId = $this->data['deliverylog_id'] ?? null;

        if (! $tripId) {
            return ['loaded' => 0, 'total' => 0];
        }

        $query = Whtripinvoice::where('whdeliverylog_id', $tripId);

        return [
            'loaded' => (clone $query)->where($this->doneColumn(), true)->count(),
            'total' => $query->count(),
        ];
    }

    public function progressLabel(): string
    {
        return static::$unloading ? 'Boxes received from this trip' : 'Boxes loaded on this trip';
    }

    public function stationHeading(): string
    {
        return static::$unloading ? 'Receive boxes from the truck' : 'Scan boxes onto the truck';
    }

    public function stationDescription(): string
    {
        return static::$unloading
            ? 'Pick the arriving trip, then scan every box as it comes off.'
            : 'Pick the trip, then scan every box as it is loaded.';
    }

    public function stationIcon(): string
    {
        return static::$unloading ? 'heroicon-o-arrow-down-tray' : 'heroicon-o-arrow-up-tray';
    }

    public function household(): array
    {
        $tripId = (int) ($this->data['deliverylog_id'] ?? 0);

        return $this->householdRows($this->lastInvoice(), function (Invoice $box) use ($tripId): array {
            $row = Whtripinvoice::with('whdeliverylog:id,trip_number')->where('invoice_id', $box->id)->latest('id')->first();

            return [
                'trip' => $row?->whdeliverylog?->trip_number,
                'done' => (bool) ($row?->{$this->doneColumn()} && (int) $row->whdeliverylog_id === $tripId),
            ];
        });
    }

    public function photoStep(): ?string
    {
        return static::$unloading ? 'wh_unload' : 'wh_load';
    }

    public function photoContext(): array
    {
        return [
            'whdeliverylog_id' => $this->data['deliverylog_id'] ?? null,
            'warehouse_id' => Auth::user()?->warehouse_id,
            'logistichub_id' => Auth::user()?->logistichub_id,
        ];
    }

    public function appChoices(): Collection
    {
        return $this->tripOptionsQuery()->latest('id')->limit(60)->get()
            ->map(fn ($t) => ['id' => $t->id, 'name' => 'WH trip '.$t->trip_number, 'active' => (bool) ($t->is_active ?? true), 'sub' => $t->departure_date ? 'Leaves '.$t->departure_date : null]);
    }
}
DISPATCH_FILE_END_14

# ---------------------------------------------------------------- app/Support/Ai/ManifestReader.php
mkdir -p 'app/Support/Ai'
cat > 'app/Support/Ai/ManifestReader.php' <<'DISPATCH_FILE_END_15'
<?php

namespace App\Support\Ai;

use App\Models\Container;
use App\Models\Invoice;
use App\Models\Routearea;
use Illuminate\Support\Str;
use OpenSpout\Reader\CSV\Reader as CsvReader;
use OpenSpout\Reader\XLSX\Reader as XlsxReader;

/**
 * Reads a consolidator's manifest (PDF, Excel .xlsx, CSV or a photo) into rows of boxes.
 * The AI also cleans up addresses and picks the route area. Nothing is saved here.
 */
class ManifestReader
{
    public const COLUMNS = ['invoice', 'sender_name', 'receiver_name', 'receiver_address', 'receiver_barangay', 'receiver_city', 'receiver_province', 'receiver_mobile_no', 'receiver_home_no', 'boxtype', 'route_code'];

    public const ROWS_PER_CALL = 120;

    /**
     * @return array{rows: list<array<string, mixed>>, consolidator: ?string}
     */
    public function read(string $file, string $name, Container $container): array
    {
        @set_time_limit(0);
        config(['ai.timeout' => 600]);
        $ext = Str::lower(pathinfo($name, PATHINFO_EXTENSION));

        if (in_array($ext, ['xlsx', 'csv', 'txt'], true)) {
            $lines = $this->sheetLines($file, $ext);
            if (count($lines) < 2) {
                throw new AiUnavailable('The file looks empty.');
            }
            $header = array_shift($lines);
            $rows = [];
            $consolidator = null;
            foreach (array_chunk($lines, self::ROWS_PER_CALL) as $chunk) {
                $out = $this->ask([['type' => 'text', 'text' => "Manifest rows (first line is the header):\n".$header."\n".implode("\n", $chunk)]], 8000);
                $rows = array_merge($rows, $out['rows']);
                $consolidator ??= $out['consolidator'];
            }
        } elseif ($ext === 'pdf') {
            $block = ['type' => 'document', 'source' => ['type' => 'base64', 'media_type' => 'application/pdf', 'data' => base64_encode((string) file_get_contents($file))]];
            ['rows' => $rows, 'consolidator' => $consolidator] = $this->ask([$block, ['type' => 'text', 'text' => 'Read every box in this manifest.']], 32000);
        } elseif (in_array($ext, ['jpg', 'jpeg', 'png', 'webp'], true)) {
            $type = ['jpg' => 'image/jpeg', 'jpeg' => 'image/jpeg', 'png' => 'image/png', 'webp' => 'image/webp'][$ext];
            $block = ['type' => 'image', 'source' => ['type' => 'base64', 'media_type' => $type, 'data' => base64_encode((string) file_get_contents($file))]];
            ['rows' => $rows, 'consolidator' => $consolidator] = $this->ask([$block, ['type' => 'text', 'text' => 'Read every box in this manifest photo.']], 8000);
        } else {
            throw new AiUnavailable('Use a PDF, Excel (.xlsx), CSV or a photo (JPG/PNG). For old .xls files, open them in Excel and save as .xlsx.');
        }

        return ['rows' => $this->check($rows, $container), 'consolidator' => $consolidator];
    }

    /** @return list<string> one line per spreadsheet row, cells separated by " | " */
    protected function sheetLines(string $file, string $ext): array
    {
        $reader = $ext === 'xlsx' ? new XlsxReader : new CsvReader;
        $reader->open($file);
        $lines = [];
        foreach ($reader->getSheetIterator() as $sheet) {
            foreach ($sheet->getRowIterator() as $row) {
                $cells = array_map(fn ($v) => $v instanceof \DateTimeInterface ? $v->format('Y-m-d') : trim((string) $v), $row->toArray());
                if (implode('', $cells) !== '') {
                    $lines[] = implode(' | ', $cells);
                }
                if (count($lines) > 3000) {
                    break 2;
                }
            }
            break; // first sheet only
        }
        $reader->close();

        return $lines;
    }

    /** @return array{rows: list<array<string, mixed>>, consolidator: ?string} */
    protected function ask(array $content, int $maxTokens): array
    {
        $routes = Routearea::orderBy('code')->get(['code', 'description'])
            ->map(fn ($r) => $r->code.' = '.$r->description)->join('; ');

        $system = 'You read shipping manifests of balikbayan boxes going to the Philippines and turn them into data. '
            .'Return {"consolidator": name or null, "rows": [[invoice, sender_name, receiver_name, receiver_address, receiver_barangay, receiver_city, receiver_province, receiver_mobile_no, receiver_home_no, boxtype, route_code, fixed, problem], ...]}. '
            .'One row per box, in the order of the manifest. Keep the invoice/box number exactly as written. '
            .'Split the address into street part, barangay, city/municipality and province. Correct obvious misspellings and short forms of Philippine places '
            .'(e.g. "Lapu2" = "Lapu-Lapu City", "Mandaue Cty" = "Mandaue City", "brgy" = barangay). Write names and places in normal capitalization. '
            .'Phone: digits only, keep a leading 0 (e.g. 09171234567). '
            .'route_code: pick the best matching code from this list, or "" if none fits: '.($routes ?: '(no list)').'. '
            .'fixed: short note of what you corrected in the address, or "". problem: short note of anything missing or doubtful (no phone, no address, unreadable), or "". '
            .'Use "" for anything not in the manifest. Never invent data.';

        $out = Ai::json('manifest', $system, $content, 'smart', $maxTokens);
        $rows = [];
        foreach ((array) ($out['rows'] ?? []) as $r) {
            if (! is_array($r) || count($r) < 3) {
                continue;
            }
            $r = array_values($r);
            $rows[] = [
                'invoice' => trim((string) ($r[0] ?? '')), 'sender_name' => trim((string) ($r[1] ?? '')),
                'receiver_name' => trim((string) ($r[2] ?? '')), 'receiver_address' => trim((string) ($r[3] ?? '')),
                'receiver_barangay' => trim((string) ($r[4] ?? '')), 'receiver_city' => trim((string) ($r[5] ?? '')),
                'receiver_province' => trim((string) ($r[6] ?? '')), 'receiver_mobile_no' => preg_replace('/[^\d+]/', '', (string) ($r[7] ?? '')),
                'receiver_home_no' => trim((string) ($r[8] ?? '')), 'boxtype' => trim((string) ($r[9] ?? '')),
                'route_code' => trim((string) ($r[10] ?? '')), 'fixed' => trim((string) ($r[11] ?? '')), 'problem' => trim((string) ($r[12] ?? '')),
            ];
        }

        return ['rows' => $rows, 'consolidator' => ($out['consolidator'] ?? null) ?: null];
    }

    /** Mark duplicates and rows that can't be saved; pick which ones are ticked to save. */
    public function check(array $rows, Container $container): array
    {
        // two sender companies can use one number (board 58): only the same box twice is blocked
        $existing = Invoice::whereIn('invoice', array_column($rows, 'invoice'))->get(['invoice', 'container_id', 'receiver_name'])->groupBy('invoice');
        $who = fn ($n) => mb_strtolower(preg_replace('/\s+/', ' ', trim((string) $n)));
        $seen = [];
        foreach ($rows as $i => &$r) {
            $notes = [];
            $blocking = false;
            if ($r['invoice'] === '') {
                $notes[] = 'No box number';
                $blocking = true;
            } elseif (in_array($who($r['receiver_name']), $seen[$r['invoice']] ?? [], true)) {
                $notes[] = 'Listed twice in this file (a copied row)';
                $blocking = true;
            } elseif (($here = ($existing[$r['invoice']] ?? collect())->where('container_id', $container->id))->contains(fn ($x) => $who($x->receiver_name) === $who($r['receiver_name']))) {
                $notes[] = 'Already in this container';
                $blocking = true;
            } elseif (! empty($seen[$r['invoice']]) || $here->isNotEmpty()) {
                $notes[] = '⚠ Same number as another box in this container (other receiver): saved as 2 boxes';
            } elseif (isset($existing[$r['invoice']])) {
                $notes[] = 'Same number as a box in another container (other sender)';
            }
            if ($r['receiver_name'] === '' || $r['receiver_address'].$r['receiver_city'] === '') {
                $notes[] = 'No receiver or address';
                $blocking = true;
            }
            if ($r['receiver_mobile_no'] === '') {
                $notes[] = 'No phone';
            }
            if ($r['problem'] !== '' && ! in_array($r['problem'], $notes, true)) {
                $notes[] = $r['problem'];
            }
            $seen[$r['invoice']][] = $who($r['receiver_name']);
            $r['notes'] = implode(' · ', array_unique($notes));
            $r['blocking'] = $blocking;
            $r['save'] = ! $blocking;
            $r['n'] = $i + 1;
        }

        return array_values($rows);
    }

    /** Save the ticked rows into the container. Returns how many were added. */
    public function save(array $rows, Container $container, int $userId): int
    {
        $routes = Routearea::pluck('id', 'code');
        $consolidatorCode = (string) ($container->consolidator?->code ?? '');
        $added = 0;
        foreach ($rows as $r) {
            if (empty($r['save']) || ! empty($r['blocking'])
                || Invoice::where('container_id', $container->id)->where('invoice', $r['invoice'])->where('receiver_name', $r['receiver_name'])->exists()) {
                continue;
            }
            Invoice::create([
                'container_id' => $container->id,
                'warehouse_id' => $container->warehouse_id,
                'invoice' => $r['invoice'],
                'batchno' => $container->batch_no,
                'sender_name' => $r['sender_name'],
                'receiver_name' => $r['receiver_name'],
                'receiver_address' => $r['receiver_address'],
                'receiver_barangay' => $r['receiver_barangay'],
                'receiver_city' => $r['receiver_city'],
                'receiver_province' => $r['receiver_province'],
                'receiver_mobile_no' => $r['receiver_mobile_no'],
                'receiver_home_no' => $r['receiver_home_no'] ?: null,
                'boxtype' => (string) $r['boxtype'],
                'routearea_id' => $routes[$r['route_code']] ?? null,
                'location_code' => $consolidatorCode, // the consolidator's code, like the Excel upload
                'user_id' => $userId,
            ]);
            $added++;
        }

        return $added;
    }
}
DISPATCH_FILE_END_15

# ---------------------------------------------------------------- app/Support/Boxes/SameNumber.php
mkdir -p 'app/Support/Boxes'
cat > 'app/Support/Boxes/SameNumber.php' <<'DISPATCH_FILE_END_16'
<?php

namespace App\Support\Boxes;

use App\Models\Invoice;
use Illuminate\Support\Collection;
use Illuminate\Support\Facades\DB;

/**
 * One invoice number on two boxes (board 57). Each sender company numbers its own boxes, so two boxes can
 * share a number. A box is the number plus its container. Rules:
 * - a scan inside a container or a trip only looks there; two of them there: they are counted (1 of 2, 2 of 2);
 * - delivered boxes are left out of every other look-up;
 * - still two: the person picks the receiver's name (nothing is guessed).
 */
class SameNumber
{
    /** @var array<string, int> */
    protected static array $counts = [];

    /** How many boxes carry this number (delivered ones too), once per request. */
    public static function count(string $code): int
    {
        $key = spl_object_id(app()).':'.$code;

        return static::$counts[$key] ??= (int) Invoice::where('invoice', $code)->count();
    }

    /** @param  list<string>  $codes  numbers shared by two or more boxes, in one database question */
    public static function shared(array $codes): array
    {
        $codes = array_values(array_unique(array_filter($codes)));
        if (! $codes) {
            return [];
        }
        $rows = Invoice::query()->whereIn('invoice', $codes)->select('invoice', DB::raw('count(*) as n'))->groupBy('invoice')->pluck('n', 'invoice');
        foreach ($rows as $c => $n) {
            static::$counts[spl_object_id(app()).':'.$c] = (int) $n;
        }

        return $rows->filter(fn ($n) => $n > 1)->map(fn ($n) => (int) $n)->all();
    }

    /** Boxes with this number that are not delivered: this warehouse first, then the newest. */
    public static function active(string $code, ?int $warehouseId = null): Collection
    {
        return Invoice::query()->with('container:id,container_no,batch_no')->where('invoice', $code)
            ->where(fn ($q) => $q->where('is_delivered', false)->orWhereNull('is_delivered'))
            ->get()
            ->sortBy(fn (Invoice $i) => [$warehouseId && (int) $i->warehouse_id === $warehouseId ? 0 : 1, -$i->id])
            ->values();
    }

    /** The one box to use, or null when none or more than one is still open (then ask). */
    public static function only(string $code, ?int $warehouseId = null): ?Invoice
    {
        $open = static::active($code, $warehouseId);

        return $open->count() === 1 ? $open->first() : null;
    }

    /** All boxes with this number, open ones first (the newest first), for messages. */
    public static function best(string $code, ?int $warehouseId = null): ?Invoice
    {
        return static::active($code, $warehouseId)->first() ?? Invoice::where('invoice', $code)->latest('id')->first();
    }

    /** What to show on a "Which one?" choice: the receiver big, then where and from whom. */
    public static function choice(Invoice $i): array
    {
        $place = trim(collect([$i->receiver_city, $i->receiver_province])->filter()->map(fn ($p) => \Illuminate\Support\Str::title(\Illuminate\Support\Str::lower($p)))->join(', '));

        $nice = fn ($n) => $n ? \Illuminate\Support\Str::title(\Illuminate\Support\Str::lower(trim($n))) : null;

        return ['id' => $i->id, 'name' => $nice($i->receiver_name) ?: 'No name', 'place' => $place, 'sender' => $nice($i->sender_name),
            'container' => trim(($i->container?->container_no ?? '').($i->container?->batch_no ? ' · Batch '.$i->container->batch_no : ''))];
    }

    /** Container page warning: "⚠ 0113123 is on 2 rows of this container: Ailene Gacita, Rosa Mendoza." */
    public static function inContainer(int $containerId): ?string
    {
        $dupes = Invoice::where('container_id', $containerId)->select('invoice')->groupBy('invoice')->havingRaw('count(*) > 1')->limit(6)->pluck('invoice');
        if ($dupes->isEmpty()) {
            return null;
        }
        $names = Invoice::where('container_id', $containerId)->whereIn('invoice', $dupes)->orderBy('id')->get(['invoice', 'receiver_name'])->groupBy('invoice');

        return '⚠ '.$dupes->map(fn ($n) => "{$n} is on ".$names[$n]->count().' rows ('.$names[$n]->pluck('receiver_name')->map(fn ($r) => \Illuminate\Support\Str::title(\Illuminate\Support\Str::lower($r)))->join(', ').')')->join(' · ')
            .'. Different receivers: these are separate boxes, and every scan asks Which one?. Same receiver: delete the copied row.';
    }

    /** " · 1 of 2 with this number" when more than one box with this number is on the trip. */
    public static function suffix(int $done, int $total): string
    {
        return $total > 1 ? " · {$done} of {$total} with this number" : '';
    }
}
DISPATCH_FILE_END_16

# ---------------------------------------------------------------- app/Support/Boxes/SectionCount.php
mkdir -p 'app/Support/Boxes'
cat > 'app/Support/Boxes/SectionCount.php' <<'DISPATCH_FILE_END_17'
<?php

namespace App\Support\Boxes;

use App\Models\Boxes\WhCount;
use App\Models\Boxes\WhCountScan;
use App\Models\Boxes\WhSection;
use App\Models\Invoice;
use App\Models\Tripinvoice;
use App\Models\Whtripinvoice;
use Illuminate\Database\Eloquent\Builder;
use Illuminate\Support\Facades\Auth;
use Illuminate\Support\Facades\Schema;

/**
 * Count a section: scan every box on it. Boxes that belong elsewhere are moved here
 * (the system now says they are in this section). Missing boxes are listed at the end.
 */
class SectionCount
{
    public static function ready(): bool
    {
        return Schema::hasTable('wh_counts');
    }

    /** Boxes the system says are in this section now (not on a loaded truck, not delivered). */
    public static function expected(WhSection $s): Builder
    {
        return Invoice::query()->where('wh_section_id', $s->id)->where('is_verified', true)
            ->where(fn ($q) => $q->where('is_delivered', false)->orWhereNull('is_delivered'))
            ->whereNotIn('id', Tripinvoice::where('is_loaded', true)->select('invoice_id'))
            ->whereNotIn('id', Whtripinvoice::where('is_loaded', true)->where('is_unloaded', false)->select('invoice_id'));
    }

    /** The open count, if one was started. */
    public static function current(WhSection $s): ?WhCount
    {
        return WhCount::where('wh_section_id', $s->id)->whereNull('finished_at')->latest('id')->first();
    }

    /** The open count of the section (every phone joins the same one). */
    public static function open(WhSection $s): WhCount
    {
        return WhCount::where('wh_section_id', $s->id)->whereNull('finished_at')->latest('id')->first()
            ?? WhCount::create(['wh_section_id' => $s->id, 'user_id' => Auth::id()]);
    }

    /**
     * @return array{status: string, message: string, invoice: ?Invoice}
     */
    /** @param  int|null  $pin  the box (invoice id) picked in Which one? (board 58) */
    public static function scan(WhCount $count, string $code, ?int $warehouseId, ?int $pin = null): array
    {
        $s = $count->section;
        // two boxes can share a number (board 57/58): the one meant for this section, not delivered, first
        $all = Invoice::with('whSection:id,code')->where('invoice', $code)
            ->when($warehouseId, fn ($q) => $q->where(fn ($q) => $q->where('warehouse_id', $warehouseId)->orWhereNull('warehouse_id')))
            ->orderByRaw('case when wh_section_id = ? then 0 else 1 end', [$s->id])
            ->orderByRaw('coalesce(is_delivered, 0) asc')
            ->latest('id')->get();
        $counted = $all->isEmpty() ? collect() : WhCountScan::where('wh_count_id', $count->id)->whereIn('invoice_id', $all->pluck('id'))->pluck('invoice_id');
        $open = $all->filter(fn ($b) => ! $b->is_delivered && ! $counted->contains($b->id))->values();
        if (! $pin && $open->count() > 1) {
            return ['status' => 'which', 'message' => $open->count()." boxes have number {$code}. Which one?", 'invoice' => null, 'boxes' => $open];
        }
        $box = ($pin ? $all->firstWhere('id', $pin) : null) ?? $open->first() ?? $all->first();
        if (! $box) {
            return ['status' => 'danger', 'message' => "{$code} is not in this warehouse.", 'invoice' => null];
        }
        if ($box->is_delivered) {
            return ['status' => 'warning', 'message' => "{$code} was already delivered. Take it out and tell the office.", 'invoice' => $box];
        }
        if (Tripinvoice::where('invoice_id', $box->id)->where('is_loaded', true)->exists()) {
            $trip = Tripinvoice::with('deliverylog:id,trip_number')->where('invoice_id', $box->id)->where('is_loaded', true)->latest('id')->first();

            return ['status' => 'warning', 'message' => "{$code} is loaded on trip {$trip?->deliverylog?->trip_number}. It should be on the truck.", 'invoice' => $box];
        }
        $prev = WhCountScan::where('wh_count_id', $count->id)->where('invoice_id', $box->id)->first();
        if ($prev) {
            return ['status' => 'warning', 'message' => "{$code} was already counted. Not counted again.", 'invoice' => $box];
        }
        $from = $box->wh_section_id && (int) $box->wh_section_id !== (int) $s->id ? $box->whSection : null;
        WhCountScan::create(['wh_count_id' => $count->id, 'invoice_id' => $box->id, 'user_id' => Auth::id(), 'moved_from' => $from?->id ?? ($box->wh_section_id ? null : 0), 'created_at' => now()]);
        if ((int) $box->wh_section_id !== (int) $s->id) {
            $box->forceFill(['wh_section_id' => $s->id, 'sectioned_at' => now(), 'is_verified' => true])->save();

            return ['status' => 'success', 'message' => "{$code} moved to section {$s->code}".($from ? " (it was in {$from->code})" : '').'.', 'invoice' => $box];
        }

        return ['status' => 'success', 'message' => "{$code} counted in section {$s->code}.", 'invoice' => $box];
    }

    /** @return array{expected: int, found: int, missing: list<string>, moved: int} */
    public static function result(WhCount $count): array
    {
        $scanned = WhCountScan::where('wh_count_id', $count->id)->pluck('invoice_id')->all();
        $missing = static::expected($count->section)->whereNotIn('id', $scanned ?: [0])->orderBy('invoice')->pluck('invoice')->all();
        $moved = WhCountScan::where('wh_count_id', $count->id)->whereNotNull('moved_from')->count();

        return ['expected' => count($scanned) - $moved + count($missing), 'found' => count($scanned), 'missing' => $missing, 'moved' => $moved];
    }

    public static function finish(WhCount $count): array
    {
        $r = static::result($count);
        $count->update(['expected' => $r['expected'], 'found' => $r['found'], 'missing' => count($r['missing']), 'moved_in' => $r['moved'], 'finished_at' => now()]);

        return $r;
    }
}
DISPATCH_FILE_END_17

# ---------------------------------------------------------------- app/Support/Shipping/Returns.php
mkdir -p 'app/Support/Shipping'
cat > 'app/Support/Shipping/Returns.php' <<'DISPATCH_FILE_END_18'
<?php

namespace App\Support\Shipping;

use App\Models\Boxissue;
use App\Models\Invoiceissue;
use App\Models\Shipping\ReturnShipment;
use App\Models\Shipping\WrongHubBox;
use App\Models\Tripinvoice;
use App\Services\TripAssignment;
use App\Support\Boxes\Sections;
use Illuminate\Support\Facades\Auth;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Schema;

/**
 * Return shipments: the partner hub puts boxes on one (RET-0001), sends it, and the warehouse
 * scans each box in. Only then is the box back in the pool, in its section.
 */
class Returns
{
    public static function ready(): bool
    {
        return Schema::hasTable('return_shipments');
    }

    /** The return shipment the hub is filling now (made when needed). */
    public static function openFor(int $hubId): ReturnShipment
    {
        return ReturnShipment::where('logistichub_id', $hubId)->where('status', 'preparing')->latest('id')->first()
            ?? ReturnShipment::create(['code' => static::newCode(), 'logistichub_id' => $hubId, 'status' => 'preparing',
                'status_log' => [['status' => 'preparing', 'at' => now()->toIso8601String(), 'by' => Auth::id()]], 'created_by' => Auth::id()]);
    }

    public static function newCode(): string
    {
        $n = ReturnShipment::count() + 1;
        do {
            $code = 'RET-'.str_pad((string) $n++, 4, '0', STR_PAD_LEFT);
        } while (ReturnShipment::where('code', $code)->exists());

        return $code;
    }

    public static function add(WrongHubBox $w): ReturnShipment
    {
        $rs = static::openFor((int) $w->logistichub_id);
        $w->update(['status' => 'returning', 'return_shipment_id' => $rs->id, 'done_by' => Auth::id(), 'done_at' => now()]);

        return $rs;
    }

    public static function remove(WrongHubBox $w): bool
    {
        if ($w->status !== 'returning' || $w->returnShipment?->status !== 'preparing') {
            return false;
        }
        $w->update(['status' => 'waiting', 'return_shipment_id' => null, 'done_by' => null, 'done_at' => null]);

        return true;
    }

    public static function send(ReturnShipment $rs): bool
    {
        if ($rs->status !== 'preparing' || ! $rs->boxes()->exists()) {
            return false;
        }
        $log = (array) $rs->status_log;
        $log[] = ['status' => 'sent', 'at' => now()->toIso8601String(), 'by' => Auth::id()];
        $rs->update(['status' => 'sent', 'status_log' => $log]);

        return true;
    }

    /**
     * The warehouse scans a box in: off its trip, back in the pool (returned), into its section.
     *
     * @return array{status: string, message: string, box: ?WrongHubBox}
     */
    /** @param  int|null  $pin  the box (invoice id) picked in Which one? (board 58) */
    public static function receive(ReturnShipment $rs, string $code, ?int $warehouseId, ?int $pin = null): array
    {
        $all = WrongHubBox::with('invoice')->where('return_shipment_id', $rs->id)->whereHas('invoice', fn ($q) => $q->where('invoice', $code))->orderBy('id')->get();
        $open = $all->where('status', '!=', 'back')->values();
        if (! $pin && $open->count() > 1) {
            return ['status' => 'which', 'message' => $open->count()." boxes have number {$code}. Which one?", 'box' => null, 'boxes' => $open->pluck('invoice')->filter()->values()];
        }
        $w = ($pin ? $all->firstWhere('invoice_id', $pin) : null) ?? $open->first() ?? $all->first();
        if (! $w) {
            return ['status' => 'danger', 'message' => "{$code} is not on return shipment {$rs->code}.", 'box' => null];
        }
        if ($w->status === 'back') {
            return ['status' => 'warning', 'message' => "{$code} was already received. Not counted again.", 'box' => $w];
        }
        DB::transaction(function () use ($w, $warehouseId) {
            $row = $w->tripinvoice ?? Tripinvoice::where('invoice_id', $w->invoice_id)->latest('id')->first();
            if ($row) {
                if ($row->hub_assigned) {
                    app(TripAssignment::class)->removeFromHubTrip($row);
                }
                $row = $row->fresh();
                \App\Models\Invoice::whereKey($row->invoice_id)->update(['is_assigned' => false, 'is_returned' => true]);
                $row->delete(); // the box is back: no longer on the trip (even a locked one)
            }
            $inv = $w->invoice->fresh();
            $section = Sections::forInvoice($inv, $warehouseId);
            $inv->forceFill(['warehouse_id' => $warehouseId ?? $inv->warehouse_id, 'wh_section_id' => $section?->id, 'sectioned_at' => $section ? now() : null, 'is_verified' => true])->save();
            $w->update(['status' => 'back', 'tripinvoice_id' => null, 'received_by' => Auth::id(), 'received_at' => now()]);
        });

        return ['status' => 'success', 'message' => "{$code} is back at the warehouse.", 'box' => $w->fresh('invoice.whSection')];
    }

    /** Finish receiving: boxes not scanned in get an Invoice Issue each. */
    public static function finish(ReturnShipment $rs): int
    {
        $type = Boxissue::firstOrCreate(['issue_type' => 'Missing box']);
        $made = 0;
        foreach (WrongHubBox::with('invoice')->where('return_shipment_id', $rs->id)->where('status', 'returning')->get() as $w) {
            Invoiceissue::create(['invoice' => $w->invoice?->invoice, 'invoice_id' => $w->invoice_id, 'container_id' => $w->invoice?->container_id, 'boxissue_id' => $type->id,
                'remarks' => "Not in return shipment {$rs->code} from {$rs->hub?->hub_name} when it arrived.", 'user_id' => Auth::id()]);
            $made++;
        }
        $log = (array) $rs->status_log;
        $log[] = ['status' => 'received', 'at' => now()->toIso8601String(), 'by' => Auth::id()];
        $rs->update(['status' => 'received', 'status_log' => $log, 'warehouse_id' => $rs->warehouse_id ?? Auth::user()?->warehouse_id]);

        return $made;
    }

    /** @return array{total: int, back: int} */
    public static function counts(ReturnShipment $rs): array
    {
        $b = WrongHubBox::where('return_shipment_id', $rs->id)->get(['status']);

        return ['total' => $b->count(), 'back' => $b->where('status', 'back')->count()];
    }
}
DISPATCH_FILE_END_18

# ---------------------------------------------------------------- app/Support/Shipping/WrongHub.php
mkdir -p 'app/Support/Shipping'
cat > 'app/Support/Shipping/WrongHub.php' <<'DISPATCH_FILE_END_19'
<?php

namespace App\Support\Shipping;

use App\Models\Invoice;
use App\Models\Logistichub;
use App\Models\Shipping\WrongHubBox;
use App\Models\Tripinvoice;
use App\Services\TripAssignment;
use Illuminate\Support\Facades\Auth;
use Illuminate\Support\Facades\DB;
use Throwable;

/**
 * Boxes at a partner hub that are not theirs (wrong hub), or could not be delivered and go back.
 * A wrong-hub box can go straight to the right partner hub; the rest go back to the warehouse.
 */
class WrongHub
{
    /** "Send to Davao hub direct" or "Back to the warehouse". */
    public static function suggestion(WrongHubBox $w): array
    {
        $right = $w->correctHub;
        if ($w->reason === 'wrong_hub' && $right?->is_company && (int) $right->id !== (int) $w->logistichub_id) {
            return ['way' => 'hub', 'text' => 'Send to '.$right->hub_name.' direct', 'why' => 'Faster and cheaper than through the warehouse.'];
        }

        return ['way' => 'back', 'text' => 'Back to the warehouse', 'why' => $w->reason === 'wrong_hub' ? 'The box belongs to a Luzon area or the main hub.' : 'It goes back with the next shipment or truck to the warehouse.'];
    }

    /** Add a box the hub found (refused, moved, wrong address…). */
    public static function add(int $hubId, string $code, string $reason, ?string $note = null, ?int $pin = null): ?WrongHubBox
    {
        $row = static::candidates($hubId, $code)->when($pin, fn ($c) => $c->where('invoice_id', $pin))->first();
        if (! $row || ! array_key_exists($reason, WrongHubBox::REASONS)) {
            return null;
        }

        return WrongHubBox::firstOrCreate(['invoice_id' => $row->invoice_id, 'logistichub_id' => $hubId, 'status' => 'waiting'], [
            'tripinvoice_id' => $row->id, 'reason' => $reason, 'note' => $note ? mb_substr($note, 0, 300) : null,
            'correct_hub_id' => $row->invdata?->whSection?->logistichub_id, 'created_by' => Auth::id(),
        ]);
    }

    /** Boxes at the hub with this number, not delivered (two can share a number, board 58). */
    public static function candidates(int $hubId, string $code): \Illuminate\Support\Collection
    {
        return Tripinvoice::with('invdata.whSection', 'invdata.container:id,container_no,batch_no')->where('logistichub_id', $hubId)->where('invoice', $code)
            ->where(fn ($q) => $q->where('is_delivered', false)->orWhereNull('is_delivered'))->latest('id')->get();
    }

    /** Hand the box over to the right partner hub (like a main truck handing it over). */
    public static function sendToHub(WrongHubBox $w): bool
    {
        $row = $w->tripinvoice ?? Tripinvoice::where('invoice_id', $w->invoice_id)->where('logistichub_id', $w->logistichub_id)->latest('id')->first();
        $right = $w->correctHub;
        if (! $row || ! $right?->is_company) {
            return false;
        }
        DB::transaction(function () use ($row, $right, $w) {
            if ($row->hub_assigned) {
                app(TripAssignment::class)->removeFromHubTrip($row);
            }
            $row->update(['logistichub_id' => $right->id, 'hub_assigned' => false]);
            $w->update(['status' => 'sent_hub', 'done_by' => Auth::id(), 'done_at' => now()]);
        });

        return true;
    }

    /** Back to the warehouse: off the trip, back in the pool (marked returned). */
    public static function sendBack(WrongHubBox $w): bool
    {
        $row = $w->tripinvoice ?? Tripinvoice::where('invoice_id', $w->invoice_id)->where('logistichub_id', $w->logistichub_id)->latest('id')->first();
        if (! $row) {
            return false;
        }
        try {
            DB::transaction(function () use ($row, $w) {
                if ($row->hub_assigned) {
                    app(TripAssignment::class)->removeFromHubTrip($row);
                }
                app(TripAssignment::class)->removeFromDeliveryTrip($row->fresh(), returned: true);
                $w->update(['status' => 'back', 'done_by' => Auth::id(), 'done_at' => now(), 'tripinvoice_id' => null]);
            });
        } catch (Throwable $e) {
            report($e);

            return false;
        }

        return true;
    }

    /** This month, by reason and by consolidator. */
    public static function report(?int $hubId): array
    {
        $rows = WrongHubBox::with('invoice.consolidator')->when($hubId, fn ($q) => $q->where('logistichub_id', $hubId))
            ->where('created_at', '>=', now()->startOfMonth())->get();

        return [
            'total' => $rows->count(),
            'byReason' => $rows->groupBy('reason')->map->count()->sortDesc()->mapWithKeys(fn ($n, $k) => [WrongHubBox::REASONS[$k] ?? $k => $n])->all(),
            'byConsolidator' => $rows->groupBy(fn ($w) => $w->invoice?->consolidator?->company_name ?? 'Not known')->map->count()->sortDesc()->all(),
        ];
    }
}
DISPATCH_FILE_END_19

# ---------------------------------------------------------------- app/Support/Trips/Picking.php
mkdir -p 'app/Support/Trips'
cat > 'app/Support/Trips/Picking.php' <<'DISPATCH_FILE_END_20'
<?php

namespace App\Support\Trips;

use App\Models\Boxes\WhSection;
use App\Models\Deliverylog;
use App\Models\Invoice;
use App\Models\Tripinvoice;
use App\Models\User;
use App\Support\Ai\TripPlanner;
use Illuminate\Support\Collection;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Schema;
use Illuminate\Support\Str;

/**
 * Picking (board 49): before Load truck, pickers take each trip's boxes from the sections.
 *
 * - The office gives each trip its pickers (suggested: on shift today, free, the truck's crew first,
 *   about 1 picker for 40 boxes); a picker can Take a trip that has none.
 * - Pickers scan each box: picked, combo n of m, not for this trip, already picked, not found, undo.
 * - Many phones on one trip: everything is saved at once, so every phone sees the same list.
 * - Warehouse (and Admin): the hub's trips. Partner hub: its own trips.
 */
class Picking
{
    public const PER_PICKER = 40;

    public static function ready(): bool
    {
        static $ready = null;

        return $ready ??= Schema::hasTable('trip_pickers') && Schema::hasColumn('tripinvoices', 'picked_at');
    }

    /** A partner hub's own trip: its boxes are on deliveryloghub_id and loaded with is_loaded_hub. */
    public static function hubOwn(Deliverylog $trip): bool
    {
        static $memo = [];
        $k = spl_object_id(app()).':'.$trip->logistichub_id;

        return $memo[$k] ??= (bool) \App\Models\Logistichub::whereKey($trip->logistichub_id)->value('is_company');
    }

    /** The boxes of the trip that still need picking (not loaded yet). */
    public static function rows(Deliverylog $trip)
    {
        $hub = static::hubOwn($trip);

        $t = 'tripinvoices.';
        $loaded = $t.($hub ? 'is_loaded_hub' : 'is_loaded');

        return Tripinvoice::query()->where($t.($hub ? 'deliveryloghub_id' : 'deliverylog_id'), $trip->id)
            ->where(fn ($q) => $q->where($loaded, false)->orWhereNull($loaded))
            ->where(fn ($q) => $q->where($t.'is_delivered', false)->orWhereNull($t.'is_delivered'));
    }

    /** Trips of this hub to pick: open, not taken, with boxes not loaded. */
    public static function trips(?int $hubId): Collection
    {
        if (! static::ready()) {
            return collect();
        }
        $taken = Schema::hasColumn('deliverylogs', 'taken_at');

        return Deliverylog::with('truck:id,plate_no', 'destination:id,hub_name')->where('is_active', true)
            ->when($hubId, fn ($q) => $q->where('logistichub_id', $hubId), fn ($q) => $q->whereIn('logistichub_id', \App\Models\Logistichub::where(fn ($w) => $w->where('is_company', false)->orWhereNull('is_company'))->select('id')))
            ->when($taken, fn ($q) => $q->whereNull('taken_at'))
            ->where(fn ($q) => $q->whereExists(fn ($w) => $w->select(DB::raw(1))->from('tripinvoices')->whereColumn('tripinvoices.deliverylog_id', 'deliverylogs.id')
                ->where(fn ($x) => $x->where('is_loaded', false)->orWhereNull('is_loaded')))
                ->orWhereExists(fn ($w) => $w->select(DB::raw(1))->from('tripinvoices')->whereColumn('tripinvoices.deliveryloghub_id', 'deliverylogs.id')
                    ->where(fn ($x) => $x->where('is_loaded_hub', false)->orWhereNull('is_loaded_hub'))))
            ->orderBy('departure_date')->orderBy('id')->get();
    }

    /** @return array{total: int, picked: int, missing: int} */
    public static function progress(Deliverylog $trip): array
    {
        $r = static::rows($trip)->selectRaw('count(*) as total, sum(case when picked_at is not null then 1 else 0 end) as picked, sum(case when missing_at is not null and picked_at is null then 1 else 0 end) as missing')->first();

        return ['total' => (int) $r->total, 'picked' => (int) $r->picked, 'missing' => (int) $r->missing];
    }

    /** "C 12 · D 4": sections of the boxes not picked yet. */
    public static function sectionsText(Deliverylog $trip): string
    {
        $codes = static::rows($trip)->whereNull('tripinvoices.picked_at')->join('invoices as i', 'i.id', '=', 'tripinvoices.invoice_id')
            ->leftJoin('wh_sections as s', 's.id', '=', 'i.wh_section_id')->selectRaw('coalesce(s.code, ?) as c, count(*) as n', ['No section'])
            ->groupBy('c')->orderBy('c')->toBase()->get()->pluck('n', 'c');

        return $codes->map(fn ($n, $c) => $c.' '.$n)->join(' · ');
    }

    // ---------------------------------------------------------------- pickers

    /** People who can pick here: registered in this warehouse or partner hub. */
    public static function eligible(int $hubId): Collection
    {
        return User::where('logistichub_id', $hubId)->where(fn ($q) => $q->where('is_active', true)->orWhereNull('is_active'))
            ->whereHas('panelcategory', fn ($q) => $q->whereIn('code', ['whse', 'co']))->orderBy('first_name')->get();
    }

    public static function pickers(Deliverylog $trip): Collection
    {
        return User::whereIn('id', DB::table('trip_pickers')->where('deliverylog_id', $trip->id)->pluck('user_id'))->orderBy('first_name')->get();
    }

    public static function isPicker(Deliverylog $trip, User $u): bool
    {
        return DB::table('trip_pickers')->where('deliverylog_id', $trip->id)->where('user_id', $u->id)->exists();
    }

    public static function assign(Deliverylog $trip, array $userIds, ?User $by, string $how = 'office'): void
    {
        $ok = static::eligible((int) $trip->logistichub_id)->pluck('id')->intersect($userIds);
        foreach ($ok as $uid) {
            DB::table('trip_pickers')->updateOrInsert(['deliverylog_id' => $trip->id, 'user_id' => $uid], ['how' => $how, 'by_user_id' => $by?->id, 'created_at' => now(), 'updated_at' => now()]);
        }
        if ($ok->isNotEmpty()) {
            static::log($trip, $by, null, $how === 'took' ? 'took' : 'assigned', ($how === 'took' ? 'took the trip in the Scan app' : 'gave it to '.User::whereIn('id', $ok)->pluck('first_name')->join(' and ')).($how === 'suggested' ? ' (suggested)' : ''));
        }
    }

    public static function unassign(Deliverylog $trip, int $userId): void
    {
        DB::table('trip_pickers')->where('deliverylog_id', $trip->id)->where('user_id', $userId)->delete();
    }

    /** Take a trip with no picker yet (Scan app). */
    public static function take(Deliverylog $trip, User $u): bool
    {
        if (DB::table('trip_pickers')->where('deliverylog_id', $trip->id)->exists() || ! static::eligible((int) $trip->logistichub_id)->contains('id', $u->id)) {
            return false;
        }
        static::assign($trip, [$u->id], $u, 'took');

        return true;
    }

    /** Signed in today (on shift). */
    protected static function onShift(Collection $ids): array
    {
        if (! Schema::hasTable('sessions')) {
            return $ids->all();
        }

        return DB::table('sessions')->whereIn('user_id', $ids)->where('last_activity', '>=', today()->timestamp)->distinct()->pluck('user_id')->map(fn ($i) => (int) $i)->all();
    }

    /**
     * Suggested pickers: on shift today, not picking another trip, the truck's crew first; about 1 for 40 boxes.
     *
     * @return array{ids: list<int>, names: list<string>, why: string}
     */
    public static function suggest(Deliverylog $trip, ?Collection $busy = null): array
    {
        $all = static::eligible((int) $trip->logistichub_id);
        if ($all->isEmpty()) {
            return ['ids' => [], 'names' => [], 'why' => ''];
        }
        $boxes = static::rows($trip)->whereNull('picked_at')->count();
        $need = max(1, min(3, (int) ceil($boxes / self::PER_PICKER)));
        $busy ??= DB::table('trip_pickers')->join('deliverylogs as d', 'd.id', '=', 'trip_pickers.deliverylog_id')->where('d.is_active', true)
            ->where('d.id', '!=', $trip->id)->pluck('trip_pickers.user_id')->map(fn ($i) => (int) $i);
        $shift = static::onShift($all->pluck('id'));
        $crew = collect(Schema::hasTable('trip_crews') ? DB::table('trip_crews')->where('deliverylog_id', $trip->id)->pluck('user_id') : [])
            ->merge($trip->truck_id ? DB::table('truckcrews')->where('truck_id', $trip->truck_id)->pluck('crew') : [])->filter()->map(fn ($i) => (int) $i)->unique()->all();
        $ranked = $all->reject(fn ($u) => $busy->contains($u->id))
            ->sortBy(fn ($u) => [in_array($u->id, $crew, true) ? 0 : 1, in_array($u->id, $shift, true) ? 0 : 1, $u->first_name])->values();
        $pick = $ranked->take($need);
        $why = collect([
            $pick->every(fn ($u) => in_array($u->id, $shift, true)) ? 'on shift' : null,
            'free',
            $pick->contains(fn ($u) => in_array($u->id, $crew, true)) ? 'crew of '.($trip->truck?->plate_no ?? 'the truck') : null,
            $boxes.' '.Str::plural('box', $boxes).': '.$need.' '.Str::plural('picker', $need),
        ])->filter()->join(' · ');

        return ['ids' => $pick->pluck('id')->all(), 'names' => $pick->pluck('first_name')->all(), 'why' => $why];
    }

    // ---------------------------------------------------------------- the list on the phone

    /** Section and spot of each box, grouped: spot C1, C2…, then the section with no spot, in section order. */
    public static function groups(Deliverylog $trip): array
    {
        $rows = static::rows($trip)->with('invdata:id,invoice,receiver_name,receiver_mobile_no,receiver_city,receiver_province,receiver_address,receiver_barangay,set_key,wh_section_id,wh_spot_id')->get();
        $secs = WhSection::query()->whereIn('id', $rows->pluck('invdata.wh_section_id')->filter()->unique())->get()->keyBy('id');
        $spots = Schema::hasTable('wh_spots') ? \App\Models\Boxes\WhSpot::whereIn('id', $rows->pluck('invdata.wh_spot_id')->filter()->unique())->get()->keyBy('id') : collect();
        $names = User::whereIn('id', $rows->pluck('picked_by')->merge($rows->pluck('missing_by'))->filter()->unique())->pluck('first_name', 'id');
        $combo = static::combos($rows);
        $groups = [];
        foreach ($rows as $r) {
            $inv = $r->invdata;
            $sec = $secs[$inv?->wh_section_id] ?? null;
            $spot = $spots[$inv?->wh_spot_id] ?? null;
            $city = Str::title(Str::lower((string) $inv?->receiver_city)) ?: 'No city';
            $key = $sec ? str_pad((string) $sec->sort, 5, '0', STR_PAD_LEFT).'|'.$sec->code.'|'.($spot ? '0'.str_pad((string) $spot->sort, 4, '0', STR_PAD_LEFT) : '9') : '99999|~|'.$city;
            $groups[$key] ??= ['name' => $spot ? 'Spot '.$spot->code.' · section '.$sec->code : ($sec ? 'Section '.$sec->code.' · '.($sec->name ?: $sec->goesTo()).($spots->isNotEmpty() && $sec->use_spots ? ' · no spot' : '') : 'No section · '.$city),
                'color' => $sec?->color ?? '#6b7b88', 'boxes' => []];
            $groups[$key]['boxes'][] = ['id' => $r->id, 'code' => $r->invoice, 'name' => $inv?->receiver_name, 'combo' => ($combo[$r->id] ?? 0) > 1,
                'picked' => (bool) $r->picked_at, 'by' => $names[$r->picked_by] ?? null, 'byId' => $r->picked_by,
                'missing' => ! $r->picked_at && $r->missing_at, 'missBy' => $names[$r->missing_by] ?? null];
        }
        ksort($groups);

        return array_values(array_map(function ($g) {
            $done = collect($g['boxes'])->where('picked', true)->count();

            return $g + ['done' => $done, 'total' => count($g['boxes'])];
        }, $groups));
    }

    /** Combo size of each row (one receiver, or one set). */
    protected static function combos(Collection $rows): array
    {
        $key = fn ($r) => $r->invdata ? ($r->invdata->set_key ?: TripPlanner::receiverKey($r->invdata)) : 'x'.$r->id;
        $sizes = $rows->groupBy($key)->map->count();

        return $rows->mapWithKeys(fn ($r) => [$r->id => $sizes[$key($r)] ?? 1])->all();
    }

    // ---------------------------------------------------------------- scanning

    /**
     * A picker scanned a box.
     *
     * @return array{status: string, title: string, why: string, invoice: ?Invoice, undo: ?int, tone: string}
     */
    /** @param  int|null  $pin  the box (invoice id) picked in Which one? (board 58) */
    public static function scan(Deliverylog $trip, User $u, string $code, ?int $pin = null): array
    {
        $code = trim($code);
        // board 58: two boxes with this number on the trip not picked yet → ask Which one?
        $all = static::rows($trip)->with('invdata')->where('invoice', $code)->get()->sortBy(fn ($r) => [$r->picked_at ? 1 : 0, $r->id])->values();
        $open = $all->whereNull('picked_at');
        if (! $pin && $open->count() > 1) {
            return ['status' => 'which', 'tone' => 'warn', 'invoice' => null, 'undo' => null, 'boxes' => $open->pluck('invdata')->filter()->values(),
                'title' => $open->count().' boxes have number '.$code, 'why' => 'Which one? Look at the receiver on the sticker.'];
        }
        $row = ($pin ? $all->first(fn ($r) => (int) $r->invoice_id === $pin) : null) ?? $all->first();
        $same = $all->count();
        if (! $row) {
            $any = Tripinvoice::with('invdata')->where('invoice', $code)->where(fn ($q) => $q->where('is_delivered', false)->orWhereNull('is_delivered'))->latest('id')->first();
            $other = $any ? Deliverylog::whereKey($any->deliveryloghub_id ?: $any->deliverylog_id)->value('trip_number') : null;
            $inv = $any?->invdata ?? \App\Support\Boxes\SameNumber::best($code);
            $sec = $inv?->whSection;
            static::log($trip, $u, $code, 'wrong', $other ? 'is for '.$other : 'not on this trip');

            return ['status' => 'danger', 'tone' => 'bad', 'title' => '✕ Not for '.$trip->trip_number.' · put it back', 'invoice' => $inv, 'undo' => null,
                'why' => ($other ? 'It is for '.$other.'. ' : 'It is not on this trip. ').($sec ? 'Put it back in section '.$sec->code.'.' : 'Put it back where it was.').' Nothing changed.'];
        }
        if ($row->picked_at && $same > 1) {
            return ['status' => 'warning', 'tone' => 'warn', 'invoice' => $row->invdata, 'undo' => null,
                'title' => "Already picked: all {$same} with this number", 'why' => "This trip has {$same} boxes with number {$code} and all are picked. Leave this one."];
        }
        if ($row->picked_at) {
            $who = (int) $row->picked_by === $u->id ? null : User::whereKey($row->picked_by)->value('first_name');

            return ['status' => 'warning', 'tone' => 'warn', 'invoice' => $row->invdata, 'undo' => null,
                'title' => $who ? 'Already picked by '.$who : 'You already picked this', 'why' => $who ? $who.' has it. Leave this one.' : 'Scanned twice: counted once.'];
        }
        $row->forceFill(['picked_at' => now(), 'picked_by' => $u->id, 'missing_at' => null, 'missing_by' => null])->save();
        static::log($trip, $u, $code, 'picked');

        // combo: the rest of one receiver or one set, and where they are
        $inv = $row->invdata;
        $sib = $inv ? static::rows($trip)->with('invdata.whSection', 'invdata.whSpot')->whereKeyNot($row->id)->get()
            ->filter(fn ($r) => $r->invdata && (($inv->set_key && $r->invdata->set_key === $inv->set_key) || TripPlanner::receiverKey($r->invdata) === TripPlanner::receiverKey($inv))) : collect();
        $left = $sib->whereNull('picked_at');
        $p = static::progress($trip);
        $all = $p['picked'] >= $p['total'];
        if ($left->isNotEmpty()) {
            $size = $sib->count() + 1;

            return ['status' => 'success', 'tone' => 'warn', 'invoice' => $inv, 'undo' => $row->id,
                'title' => 'Picked · combo '.($size - $left->count()).' of '.$size,
                'why' => ($inv->receiver_name ?: 'Same receiver').': '.$left->count().' more · '.$left->map(fn ($r) => $r->invoice.' in '.($r->invdata?->whSpot?->code ?? ($r->invdata?->whSection ? 'section '.$r->invdata->whSection->code : 'no section')))->join(', ')];
        }

        if ($same > 1) {
            $done = static::rows($trip)->where('invoice', $code)->whereNotNull('picked_at')->count();

            return ['status' => 'success', 'tone' => $done < $same ? 'warn' : 'ok', 'invoice' => $inv, 'undo' => $row->id,
                'title' => "Picked · {$done} of {$same}".($inv?->receiver_name ? ' · '.\Illuminate\Support\Str::title(\Illuminate\Support\Str::lower($inv->receiver_name)) : ''),
                'why' => $done < $same ? "Another box has number {$code} on this trip: pick it too." : "All {$same} boxes with number {$code} are picked."];
        }

        return ['status' => 'success', 'tone' => 'ok', 'invoice' => $inv, 'undo' => $row->id,
            'title' => $sib->isNotEmpty() ? 'Picked · combo complete ('.($sib->count() + 1).')' : 'Picked ✓',
            'why' => $all ? 'All '.$p['total'].' boxes picked · go to Load truck.' : $p['picked'].' of '.$p['total'].' picked'];
    }

    /** Picked by mistake: back on the list. */
    public static function undo(Deliverylog $trip, int $rowId, User $u): bool
    {
        $row = static::rows($trip)->whereKey($rowId)->whereNotNull('picked_at')->first();
        if (! $row) {
            return false;
        }
        $row->forceFill(['picked_at' => null, 'picked_by' => null])->save();
        static::log($trip, $u, $row->invoice, 'undone', 'picked by mistake');

        return true;
    }

    /** Not in its section: the office sees it; the others keep picking. */
    public static function notFound(Deliverylog $trip, int $rowId, User $u): bool
    {
        $row = static::rows($trip)->with('invdata.whSection')->whereKey($rowId)->whereNull('picked_at')->first();
        if (! $row) {
            return false;
        }
        $row->forceFill(['missing_at' => now(), 'missing_by' => $u->id])->save();
        static::log($trip, $u, $row->invoice, 'not_found', 'not in '.($row->invdata?->whSection ? 'section '.$row->invdata->whSection->code : 'its place'));

        return true;
    }

    public static function log(Deliverylog $trip, ?User $u, ?string $invoice, string $what, ?string $note = null): void
    {
        DB::table('pick_logs')->insert(['deliverylog_id' => $trip->id, 'user_id' => $u?->id, 'invoice' => $invoice, 'what' => $what, 'note' => $note ? Str::limit($note, 250) : null, 'created_at' => now()]);
    }

    /** The latest lines for these trips: "8:12 AM · Ben · 80501 picked". */
    public static function recent(Collection $tripIds, int $n = 8): Collection
    {
        $rows = DB::table('pick_logs')->whereIn('deliverylog_id', $tripIds)->orderByDesc('id')->limit($n)->get();
        $names = User::whereIn('id', $rows->pluck('user_id')->filter()->unique())->pluck('first_name', 'id');
        $trips = Deliverylog::whereIn('id', $rows->pluck('deliverylog_id')->unique())->pluck('trip_number', 'id');

        return $rows->map(fn ($r) => ['t' => \Illuminate\Support\Carbon::parse($r->created_at)->format('g:i A'),
            'm' => ($trips[$r->deliverylog_id] ?? '').' · '.($names[$r->user_id] ?? 'Office').' · '.match ($r->what) {
                'picked' => $r->invoice.' picked', 'undone' => $r->invoice.' undone ('.$r->note.')', 'not_found' => $r->invoice.' not found, '.$r->note,
                'wrong' => $r->invoice.' scanned: '.$r->note, default => $r->note,
            }]);
    }
}
DISPATCH_FILE_END_20

# ---------------------------------------------------------------- resources/css/filament/admin/theme.css
mkdir -p 'resources/css/filament/admin'
cat > 'resources/css/filament/admin/theme.css' <<'DISPATCH_FILE_END_21'
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
DISPATCH_FILE_END_21

# ---------------------------------------------------------------- resources/views/filament/pages/scaninvoice.blade.php
mkdir -p 'resources/views/filament/pages'
cat > 'resources/views/filament/pages/scaninvoice.blade.php' <<'DISPATCH_FILE_END_22'
<x-filament-panels::page>
    @php($progress = $this->progress())

    <x-scan.station :heading="$this->stationHeading()" :description="$this->stationDescription()" :icon="$this->stationIcon()">
        <x-slot name="form">
            {{ $this->form }}

            <x-barcode-scanner method="scan" continuous :cooldown="1500" />
        </x-slot>

        <x-slot name="progress">
            @if ($this->data['container_id'] ?? null)
                <x-scan.progress :loaded="$progress['loaded']" :total="$progress['total']" :label="$this->progressLabel()"
                    :last="$progress['last'] ?? null" :issues="$progress['issues'] ?? 0" :unmanifested="$progress['unmanifested'] ?? 0"
                    done-text="Every box on the manifest is scanned." />
            @endif
        </x-slot>

        <x-slot name="result">
            @if ($this->which)
                @include('filament.partials.which-box', ['which' => $this->which, 'choose' => 'chooseWhich', 'cancel' => 'cancelWhich'])
            @endif
            @unless ($this->which)
            <x-scan.result :invoice="$this->lastInvoice()" :status="$lastStatus" :title="$lastMessage">
                <div class="ds-result__actions">
                    {{ $this->reportIssueAction }}
                </div>
            </x-scan.result>
            @endunless

            @if ($route)
                <div class="ds-ws__result" style="--c: {{ $route['color'] ?? '#1d6fb8' }}">
                    <strong>{{ ($route['kind'] ?? '') === 'truck' ? '🚚' : $route['code'] }}</strong>
                    <span><b>{{ ($route['kind'] ?? '') === 'truck' ? 'Truck '.$route['trip'].' → '.$route['name'] : 'Section '.$route['code'].' · '.$route['name'] }}</b>
                        @if ($setInfo)<small>{{ $setInfo['name'] }} · box {{ $setInfo['n'] }} of {{ $setInfo['of'] }} · {{ $setInfo['text'] }}</small>@endif
                        @if (! empty($route['why']))<small>{{ $route['why'] }}</small>@endif</span>
                </div>
            @endif

            @if (property_exists($this, 'hubTrip') && $this->hubTrip)
                @php($ht = $this->hubTrip)
                <div @class(['ds-ws__trip', 'is-new' => $ht['kind'] === 'new', 'is-anyway' => $ht['kind'] === 'anyway'])>
                    <b class="ds-ws__to">→ {{ $ht['kind'] === 'new' ? 'new trip ' : '' }}{{ $ht['trip'] }}</b>
                    <small>{{ $ht['why'] }}</small>
                    @if ($ht['kind'] === 'new' && ! empty($ht['full']))
                        <button type="button" wire:click="hubAnyway" wire:loading.attr="disabled">Add anyway to {{ $ht['full']['number'] }}</button>
                    @endif
                </div>
            @endif

            @if ($missingCode)
                <div class="ds-result__actions">
                    {{ $this->unmanifestedAction }}
                </div>
            @endif
            @include('filament.partials.scan-photo')
        </x-slot>

        <x-slot name="aside">
            <x-scan.household :rows="$this->household()" done-label="verified" />
        </x-slot>
    </x-scan.station>

</x-filament-panels::page>
DISPATCH_FILE_END_22

# ---------------------------------------------------------------- resources/views/filament/pages/scanload.blade.php
mkdir -p 'resources/views/filament/pages'
cat > 'resources/views/filament/pages/scanload.blade.php' <<'DISPATCH_FILE_END_23'
<x-filament-panels::page>
    @php($progress = $this->progress())

    <x-scan.station :heading="$this->stationHeading()" :description="$this->stationDescription()" :icon="$this->stationIcon()">
        <x-slot name="form">
            {{ $this->form }}

            <x-barcode-scanner method="scan" continuous :cooldown="1500" />
        </x-slot>

        <x-slot name="progress">
            @if ($this->data['deliverylog_id'] ?? null)
                @if (method_exists($this, 'loadNext') && ($next = $this->loadNext()))
                    @include('filament.partials.load-next', ['next' => $next])
                @endif
                <x-scan.progress :loaded="$progress['loaded']" :total="$progress['total']" :label="$this->progressLabel()" :last="$progress['last'] ?? null" />
            @endif
        </x-slot>

        <x-slot name="result">
            @if ($this->which)
                @include('filament.partials.which-box', ['which' => $this->which, 'choose' => 'chooseWhich', 'cancel' => 'cancelWhich'])
            @endif
            @unless ($this->which)
            <x-scan.result
                :invoice="$this->lastInvoice()"
                :status="$lastStatus"
                :title="$lastMessage"
                :meta="method_exists($this, 'lastReason') ? ['Driver said' => $this->lastReason()] : []"
            />
            @endunless
            @if (($fu = (property_exists($this, 'wrongHub') ? $this->wrongHub : null)) && ($fu['kind'] ?? null) === 'full')
                <div class="ds-ld__early is-full"><strong>Truck full · {{ $fu['code'] }} does not fit</strong><span>{{ $fu['for'] }}. Put it back{{ $fu['section'] !== '—' ? ' in section '.$fu['section'] : '' }}.</span><x-filament::button size="sm" color="gray" wire:click="loadAnyway">It still fits · load anyway</x-filament::button></div>
            @endif
            @if (($wx = (property_exists($this, 'wrongHub') ? $this->wrongHub : null)) && ($wx['kind'] ?? null) === 'wh')
                <div class="ds-ld__early is-full"><strong>Not for {{ $wx['trip'] }} · {{ $wx['code'] }} is for {{ $wx['for'] }}</strong><span>Delivered from {{ $wx['home'] }}: it stays here.</span><x-filament::button size="sm" color="gray" wire:click="loadAnyway">The office says load it</x-filament::button></div>
            @endif
            @if (($wh2 = (property_exists($this, 'wrongHub') ? $this->wrongHub : null)) && ($wh2['kind'] ?? null) === 'hub')
                <div class="ds-ld__early is-full"><strong>Not for this trip · {{ $wh2['code'] }} ({{ $wh2['for'] }})</strong><span>It goes {{ str_contains($wh2['home'], 'own trucks') ? 'with '.$wh2['home'] : 'to '.$wh2['home'] }}. Put it back{{ $wh2['section'] !== '—' ? ' in section '.$wh2['section'] : '' }}.</span><x-filament::button size="sm" color="gray" wire:click="loadAnyway">Deliver it on this trip anyway</x-filament::button></div>
            @endif
            @if (property_exists($this, 'bypass') && $this->bypass)
                <div class="ds-ld__bypass">
                    @if ($this->bypass['need'] === 'office')
                        <strong>{{ \App\Support\Trips\TripRules::RULES[$this->bypass['rule']][0] }}: office only</strong><span>Ask the office to allow {{ $this->bypass['code'] }}.</span>
                        <span class="ds-ld__reasons"><x-filament::button size="sm" wire:click="askOffice">Ask the office</x-filament::button><x-filament::button size="sm" color="gray" wire:click="cancelBypass">Cancel</x-filament::button></span>
                    @else
                        <strong>Why? (the office sees this)</strong>
                        <span class="ds-ld__reasons">@foreach (\App\Support\Trips\TripRules::reasons() as $r)<x-filament::button size="sm" color="gray" wire:click="bypassWith(@js($r))">{{ $r }}</x-filament::button>@endforeach<x-filament::button size="sm" color="gray" outlined wire:click="cancelBypass">Cancel</x-filament::button></span>
                    @endif
                </div>
            @endif
            @if (method_exists($this, 'cityTopUp') && ! $this->lastStatus && ($ctu = $this->cityTopUp()))
                <div class="ds-ld__citytop"><strong>✦ Room for {{ $ctu['room'] }} more boxes</strong><span>{{ $ctu['same'] ? 'Same way' : 'Next province' }}: {{ $ctu['city'] }}, {{ $ctu['province'] }} · {{ $ctu['boxes'] }} boxes{{ $ctu['section'] ? ' · section '.$ctu['section'] : '' }}</span><x-filament::button size="sm" wire:click="addTopUpCity(@js($ctu['key']))">Add {{ $ctu['city'] }} to this trip</x-filament::button></div>
            @endif
            @if (($oc = (property_exists($this, 'wrongHub') ? $this->wrongHub : null)) && ($oc['kind'] ?? null) === 'city')
                <div class="ds-ld__early"><strong>Other city · {{ $oc['code'] }} is for {{ $oc['for'] }}</strong><span>This trip goes to {{ $oc['trip'] }}. Put it back in section {{ $oc['section'] }}.</span><x-filament::button size="sm" color="gray" wire:click="loadAnyway">Add it to this trip anyway</x-filament::button></div>
            @endif
            @if ($early = (property_exists($this, 'early') ? $this->early : null))
                <div class="ds-ld__early"><strong>Too early · stop {{ $early['stop'] }} goes in at the {{ $early['zone'] === 'back' ? 'door' : 'middle' }}</strong><span>Put it aside and load stop {{ $early['nextStop'] }} first.</span><x-filament::button size="sm" color="gray" wire:click="loadAnyway">Load it anyway</x-filament::button></div>
            @endif
            @include('filament.partials.scan-photo')
        </x-slot>

        <x-slot name="aside">
            <x-scan.household :rows="$this->household()" done-label="on this trip" />
        </x-slot>
    </x-scan.station>
</x-filament-panels::page>
DISPATCH_FILE_END_23

# ---------------------------------------------------------------- resources/views/filament/partials/which-box.blade.php
mkdir -p 'resources/views/filament/partials'
cat > 'resources/views/filament/partials/which-box.blade.php' <<'DISPATCH_FILE_END_24'
{{-- Board 58: two boxes with the scanned number still to do. Pick the receiver on the sticker. --}}
@php($opts = $which['options'] ?? [])
@if ($phone ?? false)
    <div class="ds-sa__sheet ds-which" wire:key="which-{{ $which['code'] }}-{{ count($opts) }}">
        <span class="ds-sa__grab"></span>
        <div class="ds-which__head"><span>{{ count($opts) }}</span><span><strong>{{ count($opts) }} boxes have number {{ $which['code'] }}</strong><small>Which one? Look at the receiver on the sticker.</small></span></div>
        @foreach ($opts as $w)
            <button type="button" class="ds-which__opt" wire:click="{{ $choose }}({{ $w['id'] }})" wire:key="wo-{{ $w['id'] }}">
                <span><strong>{{ $w['name'] }}</strong>@if ($w['place'])<small>{{ $w['place'] }}</small>@endif @if ($w['sender'])<em>from {{ $w['sender'] }}</em>@endif</span><b>›</b>
            </button>
        @endforeach
        <button type="button" class="ds-sa__secondary" wire:click="{{ $cancel }}">Not this box · scan again</button>
    </div>
@else
    <div class="ds-which-desk" wire:key="which-{{ $which['code'] }}-{{ count($opts) }}"
        x-data x-on:keydown.window="if (['INPUT', 'TEXTAREA', 'SELECT'].includes($event.target.tagName)) return; const n = parseInt($event.key); const o = @js(array_column($opts, 'id')); if (n >= 1 && n <= o.length) { $wire.{{ $choose }}(o[n - 1]); } else if ($event.key === 'Escape') { $wire.{{ $cancel }}(); }">
        <div class="ds-which-desk__head"><span>{{ count($opts) }}</span><span><strong>{{ count($opts) }} boxes have number {{ $which['code'] }} · Which one?</strong><small>Look at the receiver on the sticker.</small></span></div>
        <div class="ds-which-desk__grid">
            @foreach ($opts as $i => $w)
                <button type="button" class="ds-which-desk__opt" wire:click="{{ $choose }}({{ $w['id'] }})" wire:key="wd-{{ $w['id'] }}">
                    <kbd>{{ $i + 1 }}</kbd><strong>{{ $w['name'] }}</strong>@if ($w['place'])<small>{{ $w['place'] }}</small>@endif @if ($w['sender'])<em>from {{ $w['sender'] }}</em>@endif
                </button>
            @endforeach
        </div>
        <small class="ds-which-desk__hint">Click the name, or press {{ count($opts) > 2 ? '1 to '.count($opts) : '1 or 2' }} on the keyboard. Esc: not this box.</small>
    </div>
@endif
DISPATCH_FILE_END_24

# ---------------------------------------------------------------- resources/views/filament/scan/app.blade.php
mkdir -p 'resources/views/filament/scan'
cat > 'resources/views/filament/scan/app.blade.php' <<'DISPATCH_FILE_END_25'
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

            @if (! $homeReady)
                <span class="hidden" wire:init="loadHome"></span>
            @endif
            @if ($resume)
                <button type="button" class="ds-sh__resume" wire:click="continueLast">
                    <span class="ds-sh__ring" style="--p: {{ $resume['pct'] }}"><b>{{ $resume['pct'] }}%</b></span>
                    <span class="ds-sh__resumetext"><small>Continue · {{ $resume['label'] }}</small><strong>{{ $resume['name'] }}</strong><small>{{ $resume['done'] }} of {{ $resume['total'] }} done · {{ $resume['total'] - $resume['done'] }} left</small></span>
                    <span class="ds-sh__go">Continue ›</span>
                </button>
            @endif
            <div class="ds-sh__stats">
                <span><b>{{ number_format($today['scans']) }}</b><small>scanned today</small></span>
                <span><b>{{ number_format($today['photos']) }}</b><small>photos</small></span>
                <span @class(['is-bad' => $today['problems'] > 0])><b>{{ $today['problems'] }}</b><small>{{ \Illuminate\Support\Str::plural('problem', $today['problems']) }}</small></span>
            </div>
            @if ($modes)
                @php
                    $tiles = collect($modes)->map(fn ($m, $key) => $m + ['key' => $key, 'n' => (int) ($waiting[$key] ?? 0)] + \App\Support\ScanModes::look($key));
                    $groups = $tiles->groupBy('group');
                    $groupOrder = ['Daily work', 'Between warehouses', 'Port and hubs', 'In the warehouse'];
                    $groups = $groups->sortBy(fn ($g, $name) => array_search($name, $groupOrder, true));
                @endphp
                @foreach ($groups as $name => $group)
                    <p class="ds-sa__label">{{ $name }}</p>
                    <div class="ds-sh__grid">
                        @foreach ($group->sortBy(fn ($t) => $homeReady && $t['n'] > 0 ? 0 : 1) as $t)
                            <button type="button" @class(['ds-sh__tile', 'is-done' => $homeReady && ! $t['n']]) style="--c: {{ $t['color'] }}" wire:click="open('{{ $t['key'] }}')" wire:key="tile-{{ $t['key'] }}">
                                <span class="ds-sh__chip">@include('filament.scan.icon', ['name' => $t['icon']])</span>
                                <strong>{{ $t['label'] }}</strong>
                                <small>{{ $t['sub'] }}</small>
                                <span @class(['ds-sh__badge', 'is-wait' => ! $homeReady, 'is-on' => $homeReady && $t['n']])>{{ ! $homeReady ? '···' : ($t['n'] ? $t['n'].' to do' : '✓') }}</span>
                            </button>
                        @endforeach
                    </div>
                @endforeach
            @else
                <div class="ds-sa__note">Your account can't scan here. Ask the office to set your account to Warehouse or Company.</div>
            @endif
            <div class="ds-sh__opening" wire:loading.flex wire:target="open,continueLast">
                <i></i><i></i><i></i><i></i><small>Opening…</small>
            </div>
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

            @if ($this->mode === 'pick')
                @php($mineList = $choices->where('mine', true)->values())
                @php($openList = $choices->where('mine', false)->values())
                <p class="ds-sa__label">My trips</p>
                @forelse ($mineList as $i => $c)
                    <button type="button" class="ds-pk__mine" wire:click="pick({{ $c['id'] }})" x-on:click="window.dsWarmCamera && window.dsWarmCamera()" wire:key="pm-{{ $c['id'] }}">
                        <span class="ds-pk__row"><b>{{ $c['name'] }}</b><em>Open ›</em></span>
                        @if ($c['sub'])<small>{{ $c['sub'] }}</small>@endif
                        <span class="ds-pk__bar"><i style="width: {{ $c['total'] ? round($c['done'] / $c['total'] * 100) : 0 }}%"></i></span>
                        <small class="is-num">{{ $c['done'] }} of {{ $c['total'] }} picked</small>
                    </button>
                @empty
                    <div class="ds-sa__note">No trip given to you yet. Take one below, or ask the office.</div>
                @endforelse
                <p class="ds-sa__label">No picker yet · your hub</p>
                @forelse ($openList as $c)
                    <div class="ds-pk__open" wire:key="po-{{ $c['id'] }}">
                        <span><b>{{ $c['name'] }}</b><small>{{ $c['total'] }} {{ \Illuminate\Support\Str::plural('box', $c['total']) }}{{ $c['sub'] ? ' · '.$c['sub'] : '' }}</small></span>
                        <button type="button" wire:click="takeTrip({{ $c['id'] }})" x-on:click="window.dsWarmCamera && window.dsWarmCamera()" wire:loading.attr="disabled">Take this trip</button>
                    </div>
                @empty
                    <div class="ds-sa__note">Every trip has a picker.</div>
                @endforelse
                <small class="ds-pk__foot">Trips of other people and trips already picked are not shown here.</small>
            @else
            @forelse ($choices as $i => $c)
                <button type="button" @class(['ds-sa__choice', 'is-finished' => $c['finished']]) style="animation-delay: {{ $i * 50 }}ms" wire:click="pick({{ $c['id'] }})" x-on:click="window.dsWarmCamera && window.dsWarmCamera(@js(\App\Support\ScanModes::scanner()['formats']))" wire:key="c-{{ $c['id'] }}">
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
            @endif

            @if ($finishedCount)
                <button type="button" class="ds-sa__more" wire:click="toggleFinished">
                    {{ $showFinished ? 'Hide finished' : 'Show finished ('.$finishedCount.')' }}
                </button>
            @endif
        </section>
    @endif

    {{-- ============================== scan ============================== --}}
    @if ($screen === 'scan' && $def)
        <section @class(['ds-sa__screen', 'ds-sa__scan', 'is-pick' => $this->mode === 'pick']) wire:key="scan-{{ $this->mode }}-{{ $choice }}">
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
                 x-data="barcodeScanner(@js(\App\Support\ScanModes::scanner()))">
                <video x-ref="video" playsinline muted autoplay></video>
                <div class="ds-sa__frame" x-bind:class="{ 'is-hit': flash }"><i></i><i></i><i></i><i></i><span x-show="scanning" class="ds-sa__sweep"></span></div>
                <p class="ds-sa__camtext" x-show="loading" x-cloak>Starting camera…</p>
                <p class="ds-sa__camtext is-error" x-show="error" x-text="error" x-cloak></p>
                <p class="ds-sa__camtext is-hint" x-show="hint && ! error" x-text="hint" x-cloak></p>
                @include('filament.scan.cam-extras', ['uploads' => true])

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
                        <button type="button" class="ds-sa__round" x-show="scanning && cameras.length > 1" x-on:click.stop="listCameras(true).then(() => camList = ! camList)" x-bind:class="{ 'is-on': camList }" aria-label="Switch camera" x-cloak><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M4 8h3l2-3h6l2 3h3v11H4z"/><path d="M9.5 12.5a2.6 2.6 0 0 1 4.6-1.4M14.5 14a2.6 2.6 0 0 1-4.6 1.4"/><path d="m14.4 9.6-.1 1.7-1.6-.2M9.6 16.4l.1-1.7 1.6.2"/></svg></button>
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

            <span class="hidden" wire:key="pz-{{ $sessionScans }}-{{ $status ?? 'none' }}-{{ $paused ? 1 : 0 }}" x-init="$dispatch('ds-scanner', { paused: @js($paused) })"></span>
            @if (! $extrasReady)
                <div @class(['ds-sx__skel', 'hidden' => ! in_array($this->mode, ['load', 'hub_load'], true)]) wire:init="loadExtras"><i></i><i></i><i></i><small>Load next and space: coming… you can scan already</small></div>
            @endif

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

            @if (! $status && ! $bypass && $cityTopUp)
                <div class="ds-sx__citytop" wire:key="citytop-{{ $cityTopUp['key'] }}">
                    <b>✦ Room for {{ $cityTopUp['room'] }} more boxes</b>
                    <span>{{ $cityTopUp['same'] ? 'Same way' : 'Next province' }}: <b>{{ $cityTopUp['city'] }}, {{ $cityTopUp['province'] }}</b> · {{ $cityTopUp['boxes'] }} {{ Str::plural('box', $cityTopUp['boxes']) }}{{ $cityTopUp['days'] ? ', '.$cityTopUp['days'].' '.Str::plural('day', $cityTopUp['days']).' old' : '' }}.@if ($cityTopUp['section']) In section <b>{{ $cityTopUp['section'] }}</b>.@endif</span>
                    <button type="button" class="ds-sa__primary" wire:click="cityTopUpAdd(@js($cityTopUp['key']))">Scan them now</button>
                    <button type="button" class="ds-sa__secondary" wire:click="cityTopUpSkip">No thanks</button>
                </div>
            @endif

            @if ($which)
                @include('filament.partials.which-box', ['which' => $which, 'phone' => true, 'choose' => 'chooseBox', 'cancel' => 'skipBox'])
            @endif

            @if ($this->mode === 'pick')
                @php($allPicked = ($progress['total'] ?? 0) > 0 && ($progress['loaded'] ?? 0) >= $progress['total'])
                @php($nextGroup = collect($pickGroups)->first(fn ($g) => collect($g['boxes'])->contains(fn ($b) => ! $b['picked'] && ! $b['missing'])))
                @php($nextBox = $nextGroup ? collect($nextGroup['boxes'])->first(fn ($b) => ! $b['picked'] && ! $b['missing']) : null)
                @php($hereLeft = $nextGroup ? collect($nextGroup['boxes'])->filter(fn ($b) => ! $b['picked'] && ! $b['missing'])->count() : 0)
                @php($allLeft = max(0, ($progress['total'] ?? 0) - ($progress['loaded'] ?? 0)))
                {{-- board 55: the next box on the camera, a short message after each scan, the list in a pull-up sheet --}}
                @if ($nextBox)
                    <span class="ds-pk__next" wire:key="pk-next-{{ $nextBox['id'] }}">Next: {{ \Illuminate\Support\Str::before($nextGroup['name'], ' · ') }} · {{ $nextBox['code'] }}</span>
                @endif
                @if ($pickResult)
                    {{-- board 56: dark glass; Picked goes small after 4 s (📌 Keep holds it); yellow and red stay until OK or the next scan --}}
                    @php($tone = $pickResult['tone'])
                    <div class="ds-pk__msg" wire:key="pk-msg-{{ $pickSeq }}"
                         x-data="{ on: true, small: false, pinned: false, left: 4000, sticky: @js($tone !== 'ok') }"
                         x-init="window.dsResultSound && window.dsResultSound(@js($tone)); if (! sticky) { const t = setInterval(() => { if (pinned) return; left -= 250; if (left <= 0) { clearInterval(t); small = true; } }, 250); }">
                        <div @class(['ds-pk__toast', 'is-ok' => $tone === 'ok', 'is-warn' => $tone === 'warn', 'is-bad' => $tone === 'bad']) x-show="on && ! small" x-transition.opacity>
                            <span class="ds-pk__sign">{{ $tone === 'ok' ? '✓' : ($tone === 'bad' ? '✕' : '!') }}</span>
                            <span class="ds-pk__words"><b>{{ preg_replace('/^✕\s*/u', '', $pickResult['title']) }}</b><small>{{ $pickResult['code'] ? $pickResult['code'].' · ' : '' }}{{ $pickResult['why'] }}</small></span>
                            @if ($pickResult['undo'])
                                <button type="button" class="ds-pk__undo2" wire:click="undoPick({{ $pickResult['undo'] }})">↶ Undo</button>
                            @endif
                            @if ($tone !== 'ok')
                                <button type="button" class="ds-pk__ok" x-on:click="on = false">OK</button>
                            @endif
                        </div>
                        <div class="ds-pk__after" x-show="on && ! small">
                            <template x-if="! sticky && ! pinned"><span class="ds-pk__timer"><i x-bind:style="'width:' + (left / 40) + '%'"></i></span></template>
                            <small x-text="sticky ? 'Stays until the next scan or OK' : (pinned ? 'Kept on screen' : 'Goes small in 4 s')"></small>
                            <template x-if="! sticky"><button type="button" x-on:click="pinned = ! pinned" x-text="pinned ? 'Let it go' : '📌 Keep'"></button></template>
                        </div>
                        @if ($tone === 'ok')
                            <span class="ds-pk__last" x-show="on && small" x-cloak>
                                <b>Last: {{ $pickResult['code'] }} ✓</b>
                                @if ($pickResult['undo'])
                                    <button type="button" wire:click="undoPick({{ $pickResult['undo'] }})">↶ Undo</button>
                                @endif
                            </span>
                        @endif
                    </div>
                @endif
                <div class="ds-pk__sheet2" x-data="{ open: false }" x-bind:class="{ 'is-open': open }" wire:key="pk-sheet" wire:poll.6s.visible>
                    <button type="button" class="ds-pk__peek" x-on:click="open = ! open">
                        <span class="ds-sa__grab"></span>
                        <span class="ds-pk__peekrow">
                            <span>
                                @if ($allPicked)
                                    <b>✓ All {{ $progress['total'] }} boxes picked</b><small>Bring them to the truck</small>
                                @elseif ($nextGroup)
                                    <b>Next: {{ $nextGroup['name'] }}</b><small>{{ $hereLeft }} {{ \Illuminate\Support\Str::plural('box', $hereLeft) }} here · {{ $allLeft }} left in all</small>
                                @else
                                    <b>{{ $allLeft }} left</b><small>The rest are marked not found</small>
                                @endif
                            </span>
                            <em x-text="open ? 'Hide ˅' : 'List ˄'">List ˄</em>
                        </span>
                        <span class="ds-pk__bar"><i style="width: {{ ($progress['total'] ?? 0) ? round(($progress['loaded'] ?? 0) / $progress['total'] * 100) : 0 }}%"></i></span>
                    </button>
                    @if ($allPicked)
                        <button type="button" class="ds-sa__primary ds-pk__goload" wire:click="goLoad">Go to Load truck</button>
                    @endif
                    <div class="ds-pk__list" x-show="open" x-cloak>
                        @foreach ($pickGroups as $g)
                            <div class="ds-pk__group" wire:key="pg-{{ md5($g['name']) }}">
                                <span class="ds-pk__gh"><b><i style="background: {{ $g['color'] }}"></i>{{ $g['name'] }}</b><small @class(['is-done' => $g['done'] >= $g['total']])>{{ $g['done'] }} of {{ $g['total'] }}</small></span>
                                <span class="ds-pk__boxes">
                                    @foreach ($g['boxes'] as $b)
                                        @if ($b['picked'])
                                            <span @class(['ds-pk__box', 'is-picked', 'is-mine' => $b['byId'] === auth()->id()]) title="Picked by {{ $b['by'] }}">✓ {{ $b['code'] }}<small>{{ $b['byId'] === auth()->id() ? 'you' : $b['by'] }}</small></span>
                                        @elseif ($b['missing'])
                                            <span class="ds-pk__box is-missing" title="Not found by {{ $b['missBy'] }}">? {{ $b['code'] }}<small>not found</small></span>
                                        @else
                                            <button type="button" @class(['ds-pk__box', 'is-combo' => $b['combo']]) wire:click="notFound({{ $b['id'] }})" wire:confirm="Can't find {{ $b['code'] }} in its place? Mark it not found.">{{ $b['code'] }}@if ($b['combo'])<small>combo</small>@endif</button>
                                        @endif
                                    @endforeach
                                </span>
                            </div>
                        @endforeach
                        <small class="ds-pk__foot">Scan each box you take. Tap a box you cannot find to mark it not found. Every phone on this trip sees the same list.</small>
                    </div>
                </div>
            @elseif ($bypass)
                <div class="ds-sa__sheet is-warn" wire:key="bypass-{{ $bypass['code'] }}">
                    <span class="ds-sa__grab"></span>
                    @if ($bypass['need'] === 'office')
                        <p class="ds-sa__msg"><b>{{ $bypass['title'] }}: office only.</b> Ask the office to allow {{ $bypass['code'] }}. Keep the box aside until they answer.</p>
                        <button type="button" class="ds-sa__primary" wire:click="askOffice">Ask the office</button>
                    @else
                        <span class="ds-sa__hit"><span><small class="ds-ld__kicker">{{ $bypass['title'] }} · load anyway</small><strong>{{ $bypass['code'] }}</strong></span></span>
                        <p class="ds-sa__msg"><b>Why? (the office sees this)</b></p>
                        <div class="ds-sx__reasons">@foreach ($bypassReasons as $r)<button type="button" wire:click="bypassWith(@js($r))">{{ $r }}</button>@endforeach</div>
                    @endif
                    <button type="button" class="ds-sa__secondary" wire:click="cancelBypass">Cancel</button>
                </div>
            @elseif ($status === 'success' && $box)
                <div class="ds-sa__sheet is-ok" wire:key="ok-{{ $invoiceId }}-{{ $sessionScans }}">
                    <span class="ds-sa__grab"></span>
                    <div class="ds-sa__hit">
                        <span class="ds-sa__mark is-ok"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="3" stroke-linecap="round" stroke-linejoin="round"><path d="m5 12.5 4.5 4.5L19 7.5"/></svg></span>
                        <span><strong>{{ $box->invoice }}</strong><small>{{ $def['ok'] }}@if (preg_match('/ · (\d+) of (\d+)/', (string) $message, $sameM)) <b class="ds-which__of">{{ $sameM[1] }} of {{ $sameM[2] }} with this number</b>@endif</small></span>
                        @if ($boxSize && $boxSize['space'] != 1)<em class="ds-sa__size">{{ $boxSize['name'] }} · takes {{ \App\Support\BoxSizes::fmt($boxSize['space']) }} space</em>@elseif ($box->boxtype)<em>{{ $box->boxtype }}</em>@endif
                    </div>
                    @if ($this->mode === 'count')<p class="ds-sa__msg">{{ $message }}</p>@endif
                    @if ($route)
                        <div @class(['ds-sx__tile', 'is-truck' => ($route['kind'] ?? '') === 'truck']) style="--sx: {{ $route['color'] ?? '#1d6fb8' }}">
                            <small>{{ match ($route['kind'] ?? '') { 'truck' => 'Carry this box to', 'wrong' => 'Careful', default => 'Put this box in' } }}</small>
                            <strong>{{ ($route['kind'] ?? '') === 'truck' ? 'TRUCK' : $route['code'] }}</strong>
                            <span>{{ ($route['kind'] ?? '') === 'truck' ? $route['name'].(! empty($route['plate']) ? ' · '.$route['plate'] : '') : $route['name'] }}</span>
                            @if (($route['kind'] ?? '') === 'truck')<em>✓ Already loaded on trip {{ $route['trip'] }}. No need to scan it again.</em>@endif
                            @if (! empty($route['why']))<em>{{ $route['why'] }}</em>@endif
                            @if (! empty($route['pending']))<em>Then scan the QR on section {{ $route['code'] }}.</em>@endif
                            @if (! empty($route['spot']) && $route['spot'] !== 'skip')<em>✓ Spot {{ $route['spot'] }}</em>@elseif (($route['spot'] ?? null) === 'skip')<em>No spot · in section {{ $route['code'] }}</em>@endif
                        </div>
                        @if (! empty($route['spots']) && empty($route['spot']))
                            <span class="ds-sx__spoth">Spot? scan its QR, tap one, or skip</span>
                            <span class="ds-sx__spots">@foreach ($route['spots'] as $sp)<button type="button" wire:click="setSpot({{ $sp['id'] }})">{{ $sp['code'] }}</button>@endforeach</span>
                            <button type="button" class="ds-sx__skip" wire:click="setSpot">Skip · just section {{ $route['code'] }}</button>
                        @endif
                        @if (($route['kind'] ?? '') === 'truck')
                            <button type="button" class="ds-sx__link" wire:click="putInSection">Put in section instead</button>
                        @endif
                    @endif
                    @if ($hubTrip)
                        <div @class(['ds-ws__trip', 'is-new' => $hubTrip['kind'] === 'new', 'is-anyway' => $hubTrip['kind'] === 'anyway'])>
                            <small>{{ $hubTrip['kind'] === 'new' ? 'Trip full · goes on a new trip' : 'Goes on trip' }}</small>
                            <b class="ds-ws__to">→ {{ $hubTrip['trip'] }}</b>
                            <small>{{ $hubTrip['why'] }}</small>
                            @if ($hubTrip['kind'] === 'new' && ! empty($hubTrip['full']))
                                <button type="button" wire:click="hubAnyway" wire:loading.attr="disabled">Add anyway to {{ $hubTrip['full']['number'] }}</button>
                            @endif
                        </div>
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
                        <div class="ds-ld__spot is-{{ $spot['zone'] }}"><strong>{{ \App\Models\Maps\TripStop::ZONES[$spot['zone']] ?? '' }}</strong><span>{{ ! empty($spot['hub']) ? $spot['hub'].' (stop '.$spot['stop'].')' : 'Stop '.$spot['stop'] }} · {{ ['front' => 'deep inside, next to the cab', 'middle' => 'in the middle', 'back' => 'near the door'][$spot['zone']] ?? '' }}</span></div>
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

                        <div class="ds-sa__photos ds-snap" wire:ignore
                             x-data="{ rendered: @js($shots->pluck('id')->all()), inv: {{ (int) $box->id }}, code: @js($box->invoice), busy: false, msg: null,
                                mine() { return window.dsPhotos ? window.dsPhotos.of(this.inv).filter((i) => ! this.rendered.includes(i.serverId)) : [] },
                                info() { return { invoiceId: this.inv, code: this.code, condition: $wire.condition, note: $wire.note, url: @js(route('scan.box-photo')) } },
                                async here() {
                                    if (this.busy || ! window.dsScanner) return; this.busy = true; this.msg = null;
                                    const f = await window.dsScanner.snapPhoto();
                                    this.busy = false;
                                    if (! f) { this.msg = 'The camera is off. Use Camera app.'; return; }
                                    window.dsPhotos.add(f, this.info());
                                },
                                app() { window.dispatchEvent(new CustomEvent('ds-scanner', { detail: { release: true } })); this.$refs.file.value = ''; this.$refs.file.click() },
                                picked(e) { const f = e.target.files[0]; if (f) window.dsPhotos.add(f, this.info()) } }">
                            <input type="file" accept="image/*" capture="environment" x-ref="file" class="hidden" x-on:change="picked($event)">
                            @foreach ($shots as $shot)
                                <a href="{{ $shot->url() }}" target="_blank" class="ds-sa__shot"><img src="{{ $shot->url() }}" alt="Photo {{ $loop->iteration }}"><b class="is-done">✓</b></a>
                            @endforeach
                            <template x-for="it in mine()" :key="it.id">
                                <span class="ds-sa__shot" x-on:click="it.failed && window.dsPhotos.retry(it)"><img :src="it.thumb" alt="Photo"><b :class="{ 'is-done': it.done, 'is-bad': it.failed }" x-text="it.failed ? 'Retry' : (it.done ? '✓' : it.p + '%')"></b></span>
                            </template>
                            <button type="button" class="ds-snap__here" x-on:click="here()" x-bind:disabled="busy">📷 Take photo here</button>
                            <button type="button" class="ds-snap__app" x-on:click="app()">Camera app<small>close-up</small></button>
                            <p class="ds-snap__note" x-text="msg || (mine().length ? 'Uploads in the back. You can scan the next box now.' : (['damaged', 'wet', 'open'].includes($wire.condition) ? 'Damaged: take a photo. Camera app for a close-up with flash.' : 'Photo optional · Take photo here uses the camera that is already on.'))"></p>
                        </div>
                    @endif
                    <button type="button" @class(['ds-sa__primary', 'is-light' => $this->photosOn()]) wire:click="dismiss">Scan next box</button>
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
                        <span><small class="ds-ld__kicker">{{ ['city' => 'Other city', 'wh' => 'Not for '.($wrongHub['trip'] ?? ''), 'full' => 'Truck full', 'hub' => 'Not for this trip'][$wrongHub['kind'] ?? ''] ?? 'Wrong hub' }}</small><strong>{{ ($wrongHub['kind'] ?? null) === 'full' ? $wrongHub['code'].' does not fit' : $wrongHub['code'].' is for '.$wrongHub['for'] }}</strong></span>
                    </div>
                    @if (($wrongHub['kind'] ?? null) === 'full')
                        <p class="ds-sa__msg">{{ $wrongHub['for'] }}. This box takes {{ $wrongHub['space'] }} space: it waits for the next {{ $wrongHub['province'] }} trip. Put it back{{ $wrongHub['section'] !== '—' ? ' in section '.$wrongHub['section'] : '' }}.</p>
                        <button type="button" class="ds-sa__primary" wire:click="dismiss">OK, put it back</button>
                        <button type="button" class="ds-sa__secondary" wire:click="loadAnyway">It still fits · load anyway</button>
                    @elseif (($wrongHub['kind'] ?? null) === 'wh')
                        <p class="ds-sa__msg">{{ $wrongHub['for'] }} is delivered from {{ $wrongHub['home'] }}. Not loaded: it stays here{{ $wrongHub['section'] !== '—' ? ', section '.$wrongHub['section'] : '' }}.</p>
                        <button type="button" class="ds-sa__primary" wire:click="dismiss">OK, put it back</button>
                        <button type="button" class="ds-sa__secondary" wire:click="loadAnyway">The office says load it</button>
                    @elseif (($wrongHub['kind'] ?? null) === 'hub')
                        <p class="ds-sa__msg">{{ $wrongHub['for'] }} goes {{ str_contains($wrongHub['home'], 'own trucks') ? 'with '.$wrongHub['home'] : 'to '.$wrongHub['home'] }}. Not loaded on {{ $wrongHub['trip'] }}: put it back{{ $wrongHub['section'] !== '—' ? ' in section '.$wrongHub['section'] : '' }}.</p>
                        <button type="button" class="ds-sa__primary" wire:click="dismiss">OK, put it back</button>
                        <button type="button" class="ds-sa__secondary" wire:click="loadAnyway">Deliver it on this trip anyway</button>
                    @elseif (($wrongHub['kind'] ?? null) === 'city')
                        <p class="ds-sa__msg">This trip goes to {{ $wrongHub['trip'] }}. Not loaded. Put it back in section {{ $wrongHub['section'] }}; it goes on a trip to its own city.</p>
                        <button type="button" class="ds-sa__primary" wire:click="dismiss">OK, put it back</button>
                        <button type="button" class="ds-sa__secondary" wire:click="loadAnyway">Add it to this trip anyway</button>
                    @else
                    <p class="ds-sa__msg">This trip goes to {{ $wrongHub['trip'] }}. Not loaded. Put it back in section {{ $wrongHub['section'] }} and tell the office.</p>
                    <button type="button" class="ds-sa__primary" wire:click="dismiss">OK, put it back</button>
                    <button type="button" class="ds-sa__secondary" wire:click="loadAnyway">The office says load it</button>
                    @endif
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
                        <button type="button" class="ds-sa__secondary" wire:click="finishReceiving" wire:confirm="Finish receiving? Boxes not scanned get a Missing box issue each.">Finish receiving{{ ! empty($receiveResult['next']) ? ' · pass on to '.$receiveResult['next'] : '' }}</button>
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
DISPATCH_FILE_END_25

# ---------------------------------------------------------------- resources/views/filament/shipping/wrong-hub.blade.php
mkdir -p 'resources/views/filament/shipping'
cat > 'resources/views/filament/shipping/wrong-hub.blade.php' <<'DISPATCH_FILE_END_26'
<x-filament-panels::page>
<div class="ds-sp">
    <div class="ds-sp__filter">
        <button type="button" wire:click="$set('tab', 'list')" @class(['is-on' => $tab === 'list'])>List</button>
        <button type="button" wire:click="$set('tab', 'return')" @class(['is-on' => $tab === 'return'])>{{ $comingBack ? 'Return shipments' : 'Return shipment'.($openReturn ? ' · '.$openBoxes->count() : '') }}</button>
        <button type="button" wire:click="$set('tab', 'report')" @class(['is-on' => $tab === 'report'])>Report</button>
    </div>

    @if ($tab === 'list')
        @if ($comingBack)
            <p class="ds-board__muted">Boxes the partner hubs send back to the warehouse: returns, and wrong-hub boxes that belong here. "Back to the warehouse" means the box is in the pool again; it comes with the next shipment or truck.</p>
        @endif
        @unless ($isAdmin || $comingBack)
            <form wire:submit="addBox" class="ds-board__panel ds-sp__new">
                <h3>Add a box</h3>
                <div class="ds-sp__newrow">
                    <input type="text" wire:model="code" placeholder="Box number" aria-label="Box number">
                    <select wire:model="reason" aria-label="Why">@foreach ($reasons as $k => $l)<option value="{{ $k }}">{{ $l }}</option>@endforeach</select>
                    <input type="text" wire:model="note" placeholder="Note (optional)" maxlength="300" aria-label="Note">
                    <x-filament::button type="submit">Add</x-filament::button>
                </div>
                @error('code')<p class="ds-sp__err">{{ $message }}</p>@enderror
                @if ($which)
                    @include('filament.partials.which-box', ['which' => $which, 'choose' => 'chooseWhich', 'cancel' => 'cancelWhich'])
                @endif
                <p class="ds-board__muted">Wrong-hub boxes are added by themselves when you receive a container.</p>
            </form>
        @endunless

        <section class="ds-board__panel ds-sp__table">
            <div class="ds-sp__tr is-head"><span>Box</span><span>Why</span><span>Suggested way</span><span></span></div>
            @forelse ($list as $r)
                @php($w = $r['w'])
                <div class="ds-sp__tr" wire:key="wh-{{ $w->id }}">
                    <span><b>{{ $w->invoice?->invoice }} · {{ \Illuminate\Support\Str::title($w->invoice?->receiver_name) }}</b><small>{{ collect([$w->invoice?->receiver_city, $w->invoice?->receiver_province])->filter()->join(', ') }}{{ $isAdmin || $comingBack ? ' · at '.$w->hub?->hub_name : '' }}{{ $w->shipment ? ' · '.$w->shipment->code : '' }}</small></span>
                    <span><em @class(['ds-sp__tag', 'is-bad' => $w->reason === 'wrong_hub'])>{{ $reasons[$w->reason] ?? $w->reason }}</em>@if ($w->note)<small>“{{ $w->note }}”</small>@endif</span>
                    <span>
                        @if ($w->status === 'waiting')
                            <b>{{ $r['tip']['text'] }}</b><small>{{ $r['tip']['why'] }}</small>
                            @if ($w->reason === 'wrong_hub' && ! $comingBack)
                                <select wire:change="setHub({{ $w->id }}, $event.target.value)" aria-label="Right hub"><option value="">Right hub: not a partner hub</option>@foreach ($hubs as $hid => $hn)<option value="{{ $hid }}" @selected($w->correct_hub_id == $hid)>Right hub: {{ $hn }}</option>@endforeach</select>
                            @endif
                        @else
                            <b class="ds-sp__ok">✓ {{ \App\Models\Shipping\WrongHubBox::STATUS[$w->status] ?? $w->status }}</b><small>{{ $w->done_at?->format('M j, g:i A') }}{{ $w->status === 'sent_hub' ? ' · '.$w->correctHub?->hub_name : '' }}</small>
                        @endif
                    </span>
                    <span class="ds-sp__btns">
                        @if ($w->status === 'waiting' && ! $comingBack)
                            @if ($r['tip']['way'] === 'hub')<x-filament::button size="sm" wire:click="sendToHub({{ $w->id }})" wire:confirm="Hand {{ $w->invoice?->invoice }} over to {{ $w->correctHub?->hub_name }}?">Send to {{ $w->correctHub?->hub_name }}</x-filament::button>@endif
                            <x-filament::button size="sm" color="gray" wire:click="sendBack({{ $w->id }})">Back to warehouse</x-filament::button>
                        @endif
                    </span>
                </div>
            @empty
                <p class="ds-board__muted ds-sp__pad">Nothing here. 👍</p>
            @endforelse
        </section>
    @elseif ($tab === 'return')
        @if (! $comingBack)
            @if ($openReturn)
                <form wire:submit="saveReturn" class="ds-board__panel ds-sp__form">
                    <h3>{{ $openReturn->code }} · to the warehouse · {{ $openBoxes->count() }} {{ str('box')->plural($openBoxes->count()) }}</h3>
                    <div class="ds-sp__lines">
                        @foreach ($openBoxes as $b)
                            <span class="ds-sp__line"><b>{{ $b->invoice?->invoice }}</b> {{ \Illuminate\Support\Str::title($b->invoice?->receiver_name) }} · {{ $reasons[$b->reason] ?? $b->reason }} <button type="button" class="ds-sp__x" wire:click="takeOff({{ $b->id }})" aria-label="Take off">✕</button></span>
                        @endforeach
                    </div>
                    <div class="ds-sp__fields">
                        <label><span>Van no.</span><input type="text" wire:model="rf.van_no"></label>
                        <label><span>Seal no.</span><input type="text" wire:model="rf.seal_no"></label>
                        <label><span>Vessel / truck</span><input type="text" wire:model="rf.vessel"></label>
                        <label><span>BL / ticket no.</span><input type="text" wire:model="rf.bl_no"></label>
                        <label><span>Arrives (ETA)</span><input type="date" wire:model="rf.eta"></label>
                        <label><span>Cost ₱</span><input type="text" inputmode="decimal" wire:model="rf.cost"></label>
                        <label class="is-wide"><span>Note</span><input type="text" wire:model="rf.note" maxlength="300"></label>
                    </div>
                    <div class="ds-sp__acts"><x-filament::button type="submit" color="gray">Save</x-filament::button><x-filament::button type="button" wire:click="sendReturn" wire:confirm="Send {{ $openReturn->code }} to the warehouse?">Mark: Sent to the warehouse</x-filament::button></div>
                </form>
            @else
                <p class="ds-board__muted">No return shipment being filled. Press "Back to warehouse" on a box and it starts one.</p>
            @endif
        @endif
        <section class="ds-board__panel ds-sp__table">
            <div class="ds-sp__tr is-head"><span>Return shipment</span><span>Boxes</span><span>Status</span><span></span></div>
            @forelse ($returns as $r)
                <div class="ds-sp__tr" wire:key="rs-{{ $r['rs']->id }}">
                    <span><b>{{ $r['rs']->code }} · from {{ $r['rs']->hub?->hub_name }}</b><small>{{ collect([$r['rs']->van_no ? 'Van '.$r['rs']->van_no : null, $r['rs']->vessel, $r['rs']->eta ? 'ETA '.$r['rs']->eta->format('M j') : null])->filter()->join(' · ') }}</small></span>
                    <span class="num">{{ $r['c']['back'] }} / {{ $r['c']['total'] }} back</span>
                    <span>{{ \App\Models\Shipping\ReturnShipment::STATUS[$r['rs']->status] ?? $r['rs']->status }}</span>
                    <span class="ds-sp__btns">@if ($comingBack && $r['rs']->status === 'sent')<x-filament::button size="sm" color="success" wire:click="finishReturn({{ $r['rs']->id }})" wire:confirm="Finish receiving {{ $r['rs']->code }}? Boxes not scanned in get an Invoice Issue each.">Finish receiving</x-filament::button>@endif</span>
                </div>
            @empty
                <p class="ds-board__muted ds-sp__pad">No return shipments yet.</p>
            @endforelse
        </section>
        @if ($comingBack)<p class="ds-board__muted">Scan the boxes in with Scan app → Receive returns: each box goes back in the pool, in its section.</p>@endif
    @else
        <div class="ds-sp__grid">
            <section class="ds-board__panel ds-sp__box">
                <h3>By reason · {{ now()->format('F') }} · {{ $report['total'] }} {{ str('box')->plural($report['total']) }}</h3>
                @php($max = max(1, ...array_values($report['byReason'] ?: [1])))
                @forelse ($report['byReason'] as $k => $n)<span class="ds-sp__barrow"><span>{{ $k }}</span><i><b style="width: {{ round($n / $max * 100) }}%"></b></i><b class="num">{{ $n }}</b></span>@empty<p class="ds-board__muted">Nothing this month.</p>@endforelse
            </section>
            <section class="ds-board__panel ds-sp__box">
                <h3>By consolidator</h3>
                @php($max2 = max(1, ...array_values($report['byConsolidator'] ?: [1])))
                @forelse ($report['byConsolidator'] as $k => $n)<span class="ds-sp__barrow"><span>{{ $k }}</span><i><b style="width: {{ round($n / $max2 * 100) }}%"></b></i><b class="num">{{ $n }}</b></span>@empty<p class="ds-board__muted">Nothing this month.</p>@endforelse
                <p class="ds-board__muted">If one consolidator causes most of them (wrong addresses on the manifest), show them this, or charge the extra shipping back.</p>
            </section>
        </div>
    @endif
</div>
</x-filament-panels::page>
DISPATCH_FILE_END_26

# ---------------------------------------------------------------- tests/Feature/AiHelpersTest.php
mkdir -p 'tests/Feature'
cat > 'tests/Feature/AiHelpersTest.php' <<'DISPATCH_FILE_END_27'
<?php

use App\Enums\FailedDeliveryReason;
use App\Filament\Delivery\Pages\Dashboard;
use App\Filament\Pages\Ai\AiAlerts;
use App\Filament\Pages\Ai\AiAsk;
use App\Filament\Pages\Ai\AiManifest;
use App\Filament\Pages\Ai\AiPhotoCheck as AiPhotoCheckPage;
use App\Filament\Pages\Ai\AiRisky;
use App\Filament\Pages\AiSettings;
use App\Models\Ai\AiAlert;
use App\Models\Ai\AiChat;
use App\Models\Ai\AiPhotoCheck;
use App\Models\Ai\AiRiskMark;
use App\Models\Ai\AiSetting;
use App\Models\Ai\AiUsage;
use App\Models\Container;
use App\Models\DeliveryAttempt;
use App\Models\Deliverylog;
use App\Models\Invoice;
use App\Models\Invoiceissue;
use App\Models\Tripinvoice;
use App\Models\User;
use App\Services\TripAssignment;
use App\Support\Ai\Ai;
use App\Support\Ai\Alerts;
use App\Support\Ai\PhotoCheck;
use App\Support\Ai\Risk;
use App\Support\Photos\BoxPhotos;
use Database\Seeders\DemoSeeder;
use Filament\Facades\Filament;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Illuminate\Http\UploadedFile;
use Illuminate\Support\Facades\Cache;
use Illuminate\Support\Facades\Http;
use Illuminate\Support\Facades\Storage;
use Livewire\Livewire;

uses(RefreshDatabase::class);

/** A fake Claude answer. */
function claude(string $text, string $stop = 'end_turn', ?array $content = null): array
{
    return ['content' => $content ?? [['type' => 'text', 'text' => $text]], 'stop_reason' => $stop, 'usage' => ['input_tokens' => 1000, 'output_tokens' => 100]];
}

function aiOn(array $features, bool $key = true): void
{
    AiSetting::query()->delete();
    AiSetting::create(['api_key' => $key ? 'sk-ant-test-1234' : null, 'model_fast' => 'claude-haiku-5-5', 'model_smart' => 'claude-sonnet-5-5', 'monthly_limit' => 20, 'features' => $features]);
    Cache::forget('ai.settings');
}

beforeEach(function () {
    $this->seed(DemoSeeder::class);
    Storage::fake('public');
    Storage::fake('local');
    $this->admin = User::where('email', 'admin@example.com')->firstOrFail();
    $this->actingAs($this->admin);
    Filament::setCurrentPanel(Filament::getPanel('admin'));
});

it('saves the key encrypted, never shows it, and tests the connection', function () {
    Http::fake(['api.anthropic.com/*' => Http::response(claude('OK'))]);

    Livewire::test(AiSettings::class)
        ->set('apiKey', 'sk-ant-secret-9876')->set('enabled.photo_check', true)->set('limit', '15')
        ->call('save')->assertSee('Key saved · ends with 9876')->assertDontSee('sk-ant-secret-9876')
        ->call('test')->assertSet('testOk', true);

    $row = AiSetting::first();
    expect($row->api_key)->toBe('sk-ant-secret-9876')
        ->and(DB::table('ai_settings')->value('api_key'))->not->toContain('secret')
        ->and($row->features)->toBe(['photo_check'])
        ->and(AiUsage::where('feature', 'test')->count())->toBe(2);
    Http::assertSent(fn ($r) => $r->hasHeader('x-api-key', 'sk-ant-secret-9876') && $r['model'] === 'claude-haiku-5-5');
});

it('stays off without a key, when switched off, and when the monthly limit is reached', function () {
    aiOn(['photo_check'], key: false);
    expect(Ai::enabled('photo_check'))->toBeFalse()->and(Ai::whyOff('photo_check'))->toContain('Add the AI key');

    aiOn([]);
    expect(Ai::enabled('photo_check'))->toBeFalse();

    aiOn(['photo_check', 'alerts']);
    AiUsage::create(['feature' => 'x', 'model' => 'm', 'cost' => 25, 'created_at' => now()]);
    expect(Ai::enabled('photo_check'))->toBeFalse()->and(Ai::whyOff('photo_check'))->toContain('limit')
        ->and(Ai::enabled('alerts'))->toBeTrue(); // alerts need no key
});

it('checks a scan photo after it is taken and lets staff open an Invoice Issue', function () {
    aiOn(['photo_check']);
    Http::fake(['api.anthropic.com/*' => Http::response(claude('{"verdict":"damaged","confidence":91,"note":"Corner crushed, side caved in"}'))]);
    $invoice = Invoice::firstOrFail();

    $photo = BoxPhotos::store(UploadedFile::fake()->image('box.jpg', 800, 600), 'unload', $invoice, ['container_id' => $invoice->container_id], $this->admin, 'good');
    $check = AiPhotoCheck::where('box_photo_id', $photo->id)->sole();
    PhotoCheck::run($check);

    expect($check->fresh())->flagged->toBeTrue()->verdict->toBe('damaged')->confidence->toBe(91);

    Livewire::test(AiPhotoCheckPage::class)
        ->assertSee($invoice->invoice)->assertSee('Corner crushed')->assertSee('Damaged · open issue')
        ->call('pick', $check->id)->call('confirmDamaged')->assertSee('Invoice Issue opened');

    $issue = Invoiceissue::latest('id')->first();
    expect($issue->invoice)->toBe($invoice->invoice)->and($issue->attachment_pic)->toHaveCount(1)
        ->and($check->fresh()->decision)->toBe('damaged');
    Storage::disk('public')->assertExists($issue->attachment_pic[0]);
});

it('checks proof-of-delivery photos too', function () {
    aiOn(['photo_check']);
    Http::fake(['api.anthropic.com/*' => Http::response(claude('{"verdict":"blurry","confidence":80,"note":"Too dark to see the box"}'))]);
    $box = Tripinvoice::where('is_delivered', false)->firstOrFail();
    Storage::disk('public')->put($box->invoice.'/a.jpg', UploadedFile::fake()->image('a.jpg')->get());

    app(TripAssignment::class)->markDelivered($box, [$box->invoice.'/a.jpg'], $this->admin);
    PhotoCheck::run($c = AiPhotoCheck::where('tripinvoice_id', $box->id)->sole());

    expect($c->fresh())->source->toBe('delivery')->verdict->toBe('blurry')->flagged->toBeTrue();
});

it('does nothing with photos while the photo check is off', function () {
    aiOn([]);
    Http::fake();
    BoxPhotos::store(UploadedFile::fake()->image('box.jpg'), 'unload', Invoice::first(), [], $this->admin, 'good');
    expect(AiPhotoCheck::count())->toBe(0);
    Http::assertNothingSent();
});

it('answers staff questions using look-ups on your own data', function () {
    aiOn(['ask']);
    $invoice = Invoice::firstOrFail();
    Http::fakeSequence('api.anthropic.com/*')
        ->push(claude('', 'tool_use', [['type' => 'tool_use', 'id' => 't1', 'name' => 'find_boxes', 'input' => ['query' => $invoice->invoice]]]))
        ->push(claude("Box {$invoice->invoice} is in the warehouse."));

    Livewire::test(AiAsk::class)
        ->call('ask', "Where is box {$invoice->invoice}?")
        ->assertSee("Box {$invoice->invoice} is in the warehouse.");

    Http::assertSent(fn ($r) => collect($r['messages'])->contains(fn ($m) => is_array($m['content'])
        && ($m['content'][0]['type'] ?? '') === 'tool_result' && str_contains($m['content'][0]['content'], $invoice->invoice)));
});

it('reads a manifest, marks duplicates, and saves only the ticked boxes', function () {
    aiOn(['manifest']);
    $container = Container::where('is_unloaded', false)->firstOrFail();
    $old = Invoice::firstOrFail();
    $old->forceFill(['container_id' => $container->id])->saveQuietly();
    $existing = $old->invoice;
    Http::fake(['api.anthropic.com/*' => Http::response(claude(json_encode(['consolidator' => 'LBC Toronto', 'rows' => [
        ['NEW-1', 'Ana Cruz', 'Jose Ramos', 'Purok 3', 'Pusok', 'Lapu-Lapu City', 'Cebu', '09171234567', '', 'Jumbo', '', 'Lapu2 = Lapu-Lapu City', ''],
        ['NEW-2', 'Ana Cruz', 'Liza Gomez', 'Blk 4', 'Lahug', 'Cebu City', 'Cebu', '', '', 'Regular', '', '', 'No phone'],
        [$existing, 'X', $old->receiver_name, 'Z', 'B', 'C', 'P', '0917', '', '', '', '', ''],
        ['NEW-1', 'Ana Cruz', 'Jose Ramos', 'Purok 3', 'Pusok', 'Lapu-Lapu City', 'Cebu', '09171234567', '', 'Jumbo', '', '', ''],
    ]])))]);
    $csv = UploadedFile::fake()->createWithContent('manifest.csv', "Invoice,Sender,Receiver,Address\nNEW-1,Ana,Jose,Lapu2\n");

    $page = Livewire::test(AiManifest::class)->set('container', $container->id)->set('file', $csv)->call('read')
        ->assertSee('Fixed: Lapu2 = Lapu-Lapu City')->assertSee('Already in')->assertSee('Listed twice')->assertSee('Save 2 boxes');
    $page->call('save');

    expect(Invoice::where('container_id', $container->id)->whereIn('invoice', ['NEW-1', 'NEW-2'])->count())->toBe(2)
        ->and(Invoice::where('invoice', 'NEW-1')->count())->toBe(1)
        ->and(Invoice::where('invoice', 'NEW-1')->value('receiver_city'))->toBe('Lapu-Lapu City');
});

it('scores risky boxes, writes the text, and warns the driver', function () {
    aiOn(['risky', 'voice']);
    $box = Tripinvoice::where('is_delivered', false)->with('invdata')->firstOrFail();
    $box->invdata->update(['receiver_mobile_no' => '', 'receiver_address' => 'near church']);
    DeliveryAttempt::create(['tripinvoice_id' => $box->id, 'invoice_id' => $box->invoice_id, 'deliverylog_id' => $box->deliverylog_id, 'user_id' => $this->admin->id, 'reason' => FailedDeliveryReason::NoOneHome->value]);

    $risk = Risk::of($box->fresh());
    expect($risk['score'])->toBeGreaterThanOrEqual(70)->and($risk['reasons'])->toContain('No phone number');

    Http::fakeSequence('api.anthropic.com/*')
        ->push(claude('Hi Maria, your box arrives tomorrow. Will someone be home? Reply YES. – Speedtech'))
        ->push(claude('{"reason":"no_one_home","note":"Gate closed. Neighbor says family is in Manila until Friday."}'));
    Livewire::test(AiRisky::class)->assertSee($box->invoice)->call('pick', $box->id)->call('write')
        ->assertSet('message', 'Hi Maria, your box arrives tomorrow. Will someone be home? Reply YES. – Speedtech')
        ->call('markTexted');
    expect(AiRiskMark::where('tripinvoice_id', $box->id)->value('status'))->toBe('texted');

    // the driver sees the warning, and can fill "can't deliver" by voice
    $driver = User::where('email', 'driver@example.com')->firstOrFail();
    $this->flushSession();
    $this->actingAs($driver);
    Filament::setCurrentPanel(Filament::getPanel('delivery'));
    Livewire::test(Dashboard::class)->call('openBox', $box->id)->assertSee('Heads up · may not be delivered')
        ->call('startMiss')->call('voiceFill', 'Sarado ang gate, nasa Manila daw sila hanggang Biyernes')
        ->assertSet('reason', 'no_one_home')->assertSet('note', 'Gate closed. Neighbor says family is in Manila until Friday.');
});

it('raises alerts without a key and lets staff handle them', function () {
    aiOn(['alerts'], key: false);
    $trip = Deliverylog::firstOrFail();
    $boxes = Tripinvoice::where('deliverylog_id', $trip->id)->get();
    $driver = User::where('email', 'driver@example.com')->firstOrFail();
    // 10 boxes "delivered" within 2 minutes
    $start = now()->subHour();
    foreach (range(0, 9) as $i) {
        $b = $boxes[$i % $boxes->count()]->replicate();
        $b->forceFill(['invoice' => 'FAST-'.$i, 'is_delivered' => true, 'delivered_by' => $driver->id, 'delivered_at' => $start->copy()->addSeconds($i * 10)])->save();
    }

    Alerts::run();
    $alert = AiAlert::where('kind', 'drivers')->sole();
    expect($alert->title)->toBe('Too many deliveries too fast')->and($alert->body)->toContain('10 boxes');

    Livewire::test(AiAlerts::class)->assertSee('Too many deliveries too fast')->call('handle', $alert->id, 'checked');
    expect($alert->fresh()->status)->toBe('checked');
    Alerts::run();
    expect($alert->fresh()->status)->toBe('checked'); // not reopened
});

it('lets a receiver ask about their own box only', function () {
    aiOn(['customer_chat']);
    $invoice = Invoice::firstOrFail();
    $invoice->update(['receiver_mobile_no' => '09171234567']);
    $this->flushSession();
    auth()->logout();

    $this->post('/ask-box', ['box' => $invoice->invoice, 'last4' => '9999'])->assertSessionHasErrors('box');
    $this->post('/ask-box', ['box' => $invoice->invoice, 'last4' => '4567'])->assertRedirect();
    $chat = AiChat::sole();

    Http::fake(['api.anthropic.com/*' => Http::response(claude('[STAFF] Pasensya po! Tatawagan kayo ng aming staff ngayong araw.'))]);
    $this->post("/ask-box/{$chat->token}", ['q' => 'Basa ang box pag dating'])->assertRedirect();
    $this->get("/ask-box/{$chat->token}")->assertOk()->assertSee('Tatawagan kayo')->assertSee('Passed to our staff');

    expect($chat->fresh()->needs_staff)->toBeTrue()
        ->and(AiAlert::where('kind', 'customers')->sole()->body)->toContain('Basa ang box');
});

it('hides the AI pages until switched on, and the customer page too', function () {
    aiOn([]);
    expect(AiPhotoCheckPage::canAccess())->toBeFalse();
    $this->get('/ask-box')->assertNotFound();
    aiOn(['photo_check', 'customer_chat']);
    expect(AiPhotoCheckPage::canAccess())->toBeTrue();
    $this->get('/ask-box')->assertOk()->assertSee('Where is my box?');
});
DISPATCH_FILE_END_27

# ---------------------------------------------------------------- tests/Feature/SameNumberTest.php
mkdir -p 'tests/Feature'
cat > 'tests/Feature/SameNumberTest.php' <<'DISPATCH_FILE_END_28'
<?php

use App\Filament\Delivery\Pages\Dashboard;
use App\Filament\Pages\Scanload;
use App\Filament\Resources\Searchinvs\Pages\ListSearchinvs;
use App\Models\Container;
use App\Models\Deliverylog;
use App\Models\Invoice;
use App\Models\Tripinvoice;
use App\Models\User;
use App\Support\Boxes\SameNumber;
use App\Support\InvoiceLookup;
use App\Support\Trips\Picking;
use Database\Seeders\DemoSeeder;
use Filament\Facades\Filament;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Livewire\Livewire;

uses(RefreshDatabase::class);

function sameAs(string $panel, string $email): void
{
    Filament::setCurrentPanel(Filament::getPanel($panel));
    test()->actingAs(User::where('email', $email)->firstOrFail());
}

/** Board 57: one invoice number on two boxes (two sender companies number their own boxes). */
beforeEach(function () {
    $this->seed(DemoSeeder::class);
    $this->trip = Deliverylog::firstOrFail();
    $this->a = Tripinvoice::with('invdata')->where('deliverylog_id', $this->trip->id)->where('is_delivered', false)->where('is_loaded', false)->firstOrFail();
    $c2 = Container::firstOrFail()->replicate();
    $c2->forceFill(['container_no' => 'SAME0000002', 'batch_no' => '777'])->save();
    $twin = $this->a->invdata->replicate();
    $twin->forceFill(['container_id' => $c2->id, 'receiver_name' => 'DESIREE SOTELO', 'sender_name' => 'Mark Sotelo', 'receiver_city' => 'GAPAN', 'receiver_province' => 'NUEVA ECIJA', 'receiver_mobile_no' => '09990001234', 'set_key' => null, 'is_delivered' => false])->save();
    $this->twin = $twin;
    $this->b = Tripinvoice::create(['invoice' => $this->a->invoice, 'invoice_id' => $twin->id, 'deliverylog_id' => $this->trip->id,
        'logistichub_id' => $this->a->logistichub_id, 'is_loaded' => false, 'is_delivered' => false]);
    $this->code = $this->a->invoice;
});

it('counts the open boxes, leaves delivered ones out of look-ups', function () {
    expect(SameNumber::count($this->code))->toBe(2)
        ->and(SameNumber::active($this->code))->toHaveCount(2)
        ->and(SameNumber::only($this->code))->toBeNull()
        ->and(SameNumber::suffix(1, 2))->toBe(' · 1 of 2 with this number');

    $this->a->invdata->forceFill(['is_delivered' => true])->save();
    expect(SameNumber::only($this->code)?->id)->toBe($this->twin->id)
        ->and(SameNumber::choice($this->twin))->toMatchArray(['name' => 'Desiree Sotelo', 'place' => 'Gapan, Nueva Ecija', 'sender' => 'Mark Sotelo']);

    $this->a->forceFill(['is_delivered' => true])->save();
    expect(InvoiceLookup::find($this->code)?->id)->toBe($this->b->id);
});

it('asks Which one? at Load truck, then counts: 1 of 2 · name, 2 of 2, already loaded all', function () {
    sameAs('admin', 'admin@example.com');
    $page = Livewire::test(Scanload::class)->set('data.deliverylog_id', $this->trip->id);

    $page->call('scan', $this->code)->assertSet('which.code', $this->code)->assertSee('Which one?')->assertSee('Desiree Sotelo')->assertSee('from Mark Sotelo');
    expect($this->b->fresh()->is_loaded)->toBeFalsy();
    $page->call('chooseWhich', 999999)->assertSet('which.code', $this->code); // not on the list: nothing
    $page->call('chooseWhich', $this->twin->id)->assertSet('which', null)->assertSet('lastStatus', 'success')->assertSee('1 of 2 · Desiree Sotelo');
    expect($this->b->fresh()->is_loaded)->toBeTruthy()->and($this->a->fresh()->is_loaded)->toBeFalsy();

    $page->call('scan', $this->code)->assertSet('which', null)->assertSet('lastStatus', 'success')->assertSee('2 of 2');
    $page->call('scan', $this->code)->assertSet('lastStatus', 'warning')->assertSee('all 2 boxes with number');
    expect($this->a->fresh()->is_loaded)->toBeTruthy();
});

it('asks Which one? when picking, then picks the chosen box', function () {
    if (! Picking::ready()) {
        $this->markTestSkipped('no picking tables');
    }
    $u = User::where('email', 'warehouse@example.com')->firstOrFail();
    $r = Picking::scan($this->trip, $u, $this->code);
    expect($r['status'])->toBe('which')->and($r['boxes'])->toHaveCount(2);
    expect(Picking::scan($this->trip, $u, $this->code, $this->twin->id)['title'])->toBe('Picked · 1 of 2 · Desiree Sotelo')
        ->and($this->b->fresh()->picked_at)->not->toBeNull()
        ->and(Picking::scan($this->trip, $u, $this->code)['title'])->toStartWith('Picked · 2 of 2')
        ->and(Picking::scan($this->trip, $u, $this->code)['title'])->toBe('Already picked: all 2 with this number');
});

it('asks the driver Which one? by receiver name, and opens the one picked', function () {
    Filament::setCurrentPanel(Filament::getPanel('delivery'));
    $this->actingAs(User::where('email', 'driver@example.com')->firstOrFail());

    $page = Livewire::test(Dashboard::class)->call('go', 'scan')
        ->call('scan', $this->code)
        ->assertSet('sheet', 'which')->assertSee('2 boxes have number '.$this->code)
        ->assertSee('Desiree Sotelo')->assertSee('from Mark Sotelo')
        ->call('pickBox', $this->b->id)
        ->assertSet('sheet', 'found')->assertSet('boxId', $this->b->id);

    // a box not on the list is ignored
    $page->call('closeSheet')->call('scan', $this->code)->call('pickBox', 999999)->assertSet('sheet', 'which');

    // one delivered: no question
    $this->a->forceFill(['is_delivered' => true])->save();
    Livewire::test(Dashboard::class)->call('go', 'scan')->call('scan', $this->code)->assertSet('sheet', 'found')->assertSet('boxId', $this->b->id);
});

it('shows Container · batch and the shared-number chip in Search Invoices', function () {
    sameAs('admin', 'admin@example.com');
    Livewire::test(ListSearchinvs::class)
        ->assertSee('Container · batch')->assertSee('SAME0000002 · 777')
        ->assertSee('⚠ 2 share this number');
});

it('lists both open boxes in Find a box and in the warehouse Search Invoices', function () {
    sameAs('warehouse', 'warehouse@example.com');
    Livewire::test(\App\Filament\Warehouse\Pages\Sections::class)->set('find', $this->code)
        ->assertSee('2 boxes have number '.$this->code)->assertSee('Desiree Sotelo')->assertSee('from Mark Sotelo');
    Livewire::test(\App\Filament\Warehouse\Resources\Searchinvs\Pages\ListSearchinvs::class)
        ->assertSee('SAME0000002 · 777')->assertSee('⚠ 2 share this number');
});

it('asks Which one? at Unload when one container has the number twice; only the picked box is verified', function () {
    $c = $this->a->invdata->container;
    $box = Invoice::where('container_id', $c->id)->where('is_verified', false)->firstOrFail();
    $box2 = $box->replicate();
    $box2->forceFill(['receiver_name' => 'ROSA MENDOZA', 'sender_name' => 'Jun dela Cruz', 'receiver_mobile_no' => '09990005555', 'set_key' => null, 'is_verified' => false])->save();
    $c->forceFill(['is_unloaded' => false, 'is_active' => true])->save();
    sameAs('admin', 'admin@example.com');
    $page = Livewire::test(\App\Filament\Pages\Scaninvoice::class)->set('data.container_id', $c->id);

    $page->call('scan', $box->invoice)->assertSet('which.code', $box->invoice)->assertSee('Rosa Mendoza');
    expect($box->fresh()->is_verified)->toBeFalsy()->and($box2->fresh()->is_verified)->toBeFalsy();
    $page->call('chooseWhich', $box2->id)->assertSet('lastStatus', 'success')->assertSee('1 of 2 · Rosa Mendoza');
    expect($box2->fresh()->is_verified)->toBeTruthy()->and($box->fresh()->is_verified)->toBeFalsy();
    $page->call('scan', $box->invoice)->assertSet('which', null)->assertSee('2 of 2');
    expect($box->fresh()->is_verified)->toBeTruthy();
    $page->call('scan', $box->invoice)->assertSet('lastStatus', 'warning')->assertSee('Already unloaded: all 2');

    expect(SameNumber::inContainer($c->id))->toContain($box->invoice.' is on 2 rows')->toContain('Rosa Mendoza');
});

it('shows the Which one? sheet in the Scan app and loads the tapped box', function () {
    sameAs('scan', 'admin@example.com');
    $page = Livewire::test(\App\Filament\Scan\Pages\ScanApp::class)->call('open', 'load')->call('pick', $this->trip->id)
        ->call('scan', $this->code)->assertSet('status', 'which')->assertSee('2 boxes have number '.$this->code)->assertSee('Not this box');
    $page->call('chooseBox', $this->twin->id)->assertSet('which', null)->assertSet('status', 'success')->assertSet('invoiceId', $this->twin->id);
    expect($this->b->fresh()->is_loaded)->toBeTruthy()->and($this->a->fresh()->is_loaded)->toBeFalsy();
    $page->call('scan', $this->code)->assertSet('status', 'success')->assertSet('invoiceId', $this->a->invoice_id);
});

it('asks Which one? on the partner hub Report a problem page', function () {
    $hubTrip = $this->a->logistichub_id;
    sameAs('admin', 'admin@example.com');
    $open = \App\Support\Shipping\WrongHub::candidates((int) $hubTrip, $this->code);
    expect($open)->toHaveCount(2);
    $w = \App\Support\Shipping\WrongHub::add((int) $hubTrip, $this->code, array_key_first(\App\Models\Shipping\WrongHubBox::REASONS), null, $this->twin->id);
    expect($w?->invoice_id)->toBe($this->twin->id);
});
DISPATCH_FILE_END_28

echo "▶ Rebuilding the design"
npm run build

echo "▶ Clearing caches"
php artisan optimize:clear

echo "▶ Running the tests"
php artisan test || echo "Some tests failed — send the red text for help."

echo
echo "✓ Done. Backup: $BACKUP"
echo "  Start the app with:  PHP_CLI_SERVER_WORKERS=4 php artisan serve   (or open https://dispatchsystem.test in Herd)"
