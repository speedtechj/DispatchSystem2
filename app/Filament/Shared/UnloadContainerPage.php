<?php

namespace App\Filament\Shared;

use App\Filament\Concerns\ScansInvoices;
use App\Models\Boxissue;
use App\Models\Container;
use App\Models\Invoice;
use App\Models\Invoiceissue;
use App\Models\Unmanifested;
use App\Models\User;
use App\Support\Boxes\BoxSets;
use App\Support\Boxes\Crossdock;
use App\Support\Boxes\Sections;
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

        $invoice = Invoice::where('container_id', $container->id)->where('invoice', $code)->first();

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
            $when = $invoice->verified_at ? \Illuminate\Support\Carbon::parse($invoice->verified_at)->format('g:i A') : null;
            $this->route = Sections::tile($invoice->whSection);
            $this->scanResult('warning', "{$code} was already verified".($who ? " by {$who}" : '').($when ? " at {$when}" : '').'. Not counted again.', $invoice);

            return;
        }

        $invoice->forceFill(['is_verified' => true, 'verified_at' => now(), 'verified_by' => Auth::id()])->save();

        $this->scanResult('success', $this->sendToSection($container, $invoice), $invoice);
    }

    /** After the box is verified: pick its section, or load it straight onto the waiting truck. */
    protected function sendToSection(Container $container, Invoice $invoice): string
    {
        $code = $invoice->invoice;
        $warehouseId = $this->warehouseId($container);
        $section = Sections::forInvoice($invoice, $warehouseId);
        $this->setInfo = BoxSets::atUnload($invoice);

        // Two warehouses: a box that another warehouse delivers goes to the transfer for it.
        if ($home = \App\Support\Warehouses\Coverage::transferTo($invoice, $warehouseId)) {
            $to = Sections::of($warehouseId)->first(fn ($s) => (int) $s->to_warehouse_id === $home);
            if ($to) {
                $section = $to;
            } else {
                $name = \App\Support\Warehouses\Coverage::name($home);
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
            $this->setInfo = \App\Support\Boxes\TruckSets::card($invoice, $trip, $warehouseId) ?? $this->setInfo;

            return "{$code} verified · onto truck {$trip->trip_number}.";
        }

        $label = Sections::labelScan($warehouseId);
        $invoice->forceFill(['wh_section_id' => $section->id, 'sectioned_at' => $label ? null : now()])->save();
        $this->route = Sections::tile($section) + ['pending' => $label, 'why' => $section->kind === 'check' ? Sections::whyCheck($invoice) : null];

        return "{$code} verified · section {$section->code}.";
    }

    /** Section-label scan (when switched on): the boxes this person scanned for that section are now there. */
    protected function placeInSection(Container $container, \App\Models\Boxes\WhSection $section): void
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
            $onTruck = \App\Models\Whtripinvoice::whereIn('whdeliverylog_id', $here)->whereIn('invoice_id', $pending->pluck('id'))->pluck('invoice_id')->all();
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
        $box = $trip ? \App\Support\Boxes\TruckSets::add($of, $boxId, $trip, $warehouseId) : null;
        if (! $box) {
            return null;
        }
        $this->setInfo = \App\Support\Boxes\TruckSets::card($of, $trip, $warehouseId);

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
