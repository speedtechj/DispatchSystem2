#!/usr/bin/env bash
#
# Dispatch System — Box sizes and truck space
# Only the files changed in this step; the rest of your project is left as it is.
#
#   cd ~/Desktop/Project/DispatchSystem
#   bash ~/Desktop/Project/part4-truck-space.sh

set -euo pipefail
[ -f artisan ] || { echo "Run this from inside your DispatchSystem project folder (the one with 'artisan')."; exit 1; }

STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="../DispatchSystem-backup-$STAMP.tar.gz"
echo "▶ Backing up the project to $BACKUP"
tar -czf "$BACKUP" --exclude=vendor --exclude=node_modules --exclude=storage/logs .

echo "▶ Writing 19 files"

# ---------------------------------------------------------------- app/Filament/Company/Resources/Trucks/Schemas/TruckForm.php
mkdir -p 'app/Filament/Company/Resources/Trucks/Schemas'
cat > 'app/Filament/Company/Resources/Trucks/Schemas/TruckForm.php' <<'DISPATCH_FILE_END_0'
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
                                    ->directory('truckypictures')
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
DISPATCH_FILE_END_0

# ---------------------------------------------------------------- app/Filament/Pages/BoxSizeSettings.php
mkdir -p 'app/Filament/Pages'
cat > 'app/Filament/Pages/BoxSizeSettings.php' <<'DISPATCH_FILE_END_1'
<?php

namespace App\Filament\Pages;

use App\Models\AppSetting;
use App\Models\Boxes\BoxSize;
use App\Models\Invoice;
use App\Models\Logistichub;
use App\Models\Truck;
use App\Support\Ai\Ai;
use App\Support\BoxSizes;
use BackedEnum;
use Filament\Notifications\Notification;
use Filament\Pages\Page;
use Filament\Support\Icons\Heroicon;
use Illuminate\Support\Facades\Auth;
use UnitEnum;

/**
 * Admin → Settings → Box sizes. The box types come from the manifests; the normal box is 1
 * and the others are set next to it. Same box, different spelling: join them. Each truck's
 * space is in normal boxes. Changes are saved right away.
 */
class BoxSizeSettings extends Page
{
    protected string $view = 'filament.boxes.settings';

    protected static string|UnitEnum|null $navigationGroup = 'Settings';

    protected static string|BackedEnum|null $navigationIcon = Heroicon::OutlinedCube;

    protected static ?string $navigationLabel = 'Box sizes';

    protected static ?string $title = 'Box sizes';

    protected static ?string $slug = 'box-sizes';

    protected static ?int $navigationSort = 89;

    /** AI look-alikes: [[from id, into id, why]] */
    public array $aiPairs = [];

    public bool $aiChecked = false;

    public static function canAccess(): bool
    {
        return (bool) Auth::user()?->hasRole('super_admin');
    }

    public function mount(): void
    {
        BoxSizes::sync();
    }

    public function toggle(): void
    {
        AppSetting::put(BoxSizes::SETTING, BoxSizes::switchedOn() ? '0' : '1');
        BoxSizes::forget();
    }

    public function step(int $id, int $dir): void
    {
        if ($size = BoxSize::find($id)) {
            BoxSizes::setSpace($size, (float) $size->space + ($dir > 0 ? 0.5 : -0.5));
        }
    }

    /** "Looks right": a new type keeps 1 and is no longer new. */
    public function confirm(int $id): void
    {
        BoxSize::whereKey($id)->update(['is_set' => true]);
        BoxSizes::forget();
    }

    public function makeBase(int $id): void
    {
        if ($size = BoxSize::find($id)) {
            BoxSizes::setBase($size);
            Notification::make()->title("{$size->name} is now your normal box (1)")->body('The other sizes were changed to stay the same real size.')->success()->send();
        }
    }

    public function join(int $from, int $into): void
    {
        $a = BoxSize::find($from);
        $b = BoxSize::find($into);
        if ($a && $b) {
            BoxSizes::join($a, $b);
            $this->aiPairs = array_values(array_filter($this->aiPairs, fn ($p) => $p[0] !== $from && $p[1] !== $from));
            Notification::make()->title("“{$a->name}” joined to {$b->name}")->success()->send();
        }
    }

    public function keepApart(int $a, int $b): void
    {
        $x = BoxSize::find($a);
        $y = BoxSize::find($b);
        if ($x && $y) {
            BoxSizes::keepApart($x, $y);
            $this->aiPairs = array_values(array_filter($this->aiPairs, fn ($p) => ! in_array($p[0], [$a, $b], true) || ! in_array($p[1], [$a, $b], true)));
        }
    }

    public function askAi(): void
    {
        $this->aiChecked = true;
        $this->aiPairs = collect(BoxSizes::lookAlikeAi())->map(fn ($p) => [$p['from']->id, $p['into']->id, $p['why']])->all();
        if (! $this->aiPairs) {
            Notification::make()->title('The AI found no other look-alikes')->send();
        }
    }

    public function setDim(int $id, string $field, mixed $value): void
    {
        if (! in_array($field, ['length_cm', 'width_cm', 'height_cm'], true) || ! \App\Support\TruckSpace::ready()) {
            return;
        }
        $v = (int) $value;
        BoxSize::whereKey($id)->update([$field => $v >= 1 && $v <= 999 ? $v : null]);
        BoxSizes::forget();
    }

    /** Use the space worked out from the box size. */
    public function useDims(int $id): void
    {
        $size = BoxSize::find($id);
        if ($size && ($sp = \App\Support\TruckSpace::spaceFromDims($size))) {
            BoxSizes::setSpace($size, $sp);
        }
    }

    public function setTruckDim(int $id, string $field, mixed $value): void
    {
        $limits = ['cargo_length_cm' => [1, 2000], 'cargo_width_cm' => [1, 2000], 'cargo_height_cm' => [1, 2000], 'fill_pct' => [40, 100], 'reserve_pct' => [0, 50]];
        if (! isset($limits[$field]) || ! \App\Support\TruckSpace::ready()) {
            return;
        }
        $v = trim((string) $value) === '' ? null : (int) $value;
        Truck::whereKey($id)->update([$field => $v !== null && $v >= $limits[$field][0] && $v <= $limits[$field][1] ? $v : null]);
    }

    /** Use the space worked out from the truck's cargo box. */
    public function useFit(int $id): void
    {
        $truck = Truck::find($id);
        if ($truck && ($fit = \App\Support\TruckSpace::fit($truck))) {
            $truck->update(['capacity' => $fit]);
        }
    }

    public function truckStep(int $id, int $dir): void
    {
        $truck = Truck::find($id);
        if ($truck) {
            $now = (int) ($truck->capacity ?: 50);
            $truck->update(['capacity' => max(1, min(2000, $now + ($dir > 0 ? 1 : -1)))]);
        }
    }

    public function setTruck(int $id, mixed $value): void
    {
        $v = (int) $value;
        if ($v >= 1 && $v <= 2000) {
            Truck::whereKey($id)->update(['capacity' => $v]);
        }
    }

    protected function getViewData(): array
    {
        $sizes = BoxSizes::sizes();
        $counts30 = BoxSizes::counts(30);
        $countsAll = BoxSizes::counts();
        $written = BoxSizes::spellingsShown();
        $byId = $sizes->keyBy('id');

        $pairs = collect(BoxSizes::lookAlike())->map(fn ($p) => [$p['from']->id, $p['into']->id, $p['why']]);
        foreach ($this->aiPairs as $p) {
            if ($byId->has($p[0]) && $byId->has($p[1]) && ! $pairs->contains(fn ($q) => $q[0] === $p[0])) {
                $pairs->push($p);
            }
        }

        $trucks = Truck::where('is_active', true)->orderBy('plate_no')->get();
        $past = BoxSizes::truckPast($trucks->pluck('id')->all());
        $big = $sizes->where('is_set', true)->sortByDesc('space')->first();
        $small = $sizes->where('is_set', true)->sortBy('space')->first();

        return [
            'on' => BoxSizes::switchedOn(),
            'working' => BoxSizes::on(),
            'sizes' => $sizes,
            'base' => $sizes->firstWhere('is_base', true),
            'counts30' => $counts30,
            'countsAll' => $countsAll,
            'written' => $written,
            'noType' => Invoice::query()->where(fn ($q) => $q->whereNull('boxtype')->orWhere('boxtype', ''))->where('created_at', '>=', now()->subDays(30))->count(),
            'pairs' => $pairs->map(fn ($p) => ['from' => $byId[$p[0]], 'into' => $byId[$p[1]], 'why' => $p[2]])->values(),
            'trucks' => $trucks,
            'past' => $past,
            'hubs' => Logistichub::pluck('hub_name', 'id'),
            'big' => $big && $big->space > 1 ? $big : null,
            'small' => $small && $small->space < 1 ? $small : null,
            'aiOn' => Ai::enabled('box_sizes'),
            'dimsOn' => \App\Support\TruckSpace::ready(),
        ];
    }
}
DISPATCH_FILE_END_1

# ---------------------------------------------------------------- app/Filament/Resources/Trucks/Schemas/TruckForm.php
mkdir -p 'app/Filament/Resources/Trucks/Schemas'
cat > 'app/Filament/Resources/Trucks/Schemas/TruckForm.php' <<'DISPATCH_FILE_END_2'
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
                                    ->directory('truckypictures')
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
DISPATCH_FILE_END_2

# ---------------------------------------------------------------- app/Filament/Scan/Pages/ScanApp.php
mkdir -p 'app/Filament/Scan/Pages'
cat > 'app/Filament/Scan/Pages/ScanApp.php' <<'DISPATCH_FILE_END_3'
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

    /** Unload: the list of trucks to pick from is open. */
    public bool $truckPicker = false;

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

    public function openTruckPicker(bool $open = true): void
    {
        $this->truckPicker = $open && $this->mode === 'unload';
    }

    public function truckStart(int $tripId): void
    {
        $station = $this->station();
        if ($this->mode === 'unload' && $station && method_exists($station, 'startTruck') && $station->startTruck($tripId)) {
            $this->truckPicker = false;
            Notification::make()->title('Truck waiting: its boxes now go straight onto it')->success()->send();
        }
    }

    public function truckPause(bool $paused): void
    {
        if ($this->mode === 'unload' && ($station = $this->station()) && method_exists($station, 'pauseTruck')) {
            $station->pauseTruck($paused);
        }
    }

    public function truckStop(): void
    {
        if ($this->mode === 'unload' && ($station = $this->station()) && method_exists($station, 'stopTruck')) {
            $station->stopTruck();
        }
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
        $truck = null;
        $trucks = collect();
        $openSets = [];
        $countResult = null;
        $topUp = null;
        if (in_array($this->screen, ['scan', 'done'], true) && $mode && $this->choice) {
            $station = $this->station();
            $progress = $station->progress();
            $target = $station->appChoices()->firstWhere('id', $this->choice);
            $loadNext = $this->screen === 'scan' && method_exists($station, 'loadNext') ? $station->loadNext() : null;
            $team = method_exists($station, 'team') ? $station->team() : [];
            $truck = method_exists($station, 'truckStatus') ? $station->truckStatus() : null;
            $trucks = $this->truckPicker && method_exists($station, 'truckChoices') ? $station->truckChoices() : collect();
            $openSets = $this->screen === 'done' && method_exists($station, 'openSets') ? $station->openSets() : [];
            $countResult = $this->screen === 'done' && method_exists($station, 'countResult') ? $station->countResult() : null;
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
            'truck' => $truck,
            'trucks' => $trucks,
            'openSets' => $openSets,
            'countResult' => $countResult,
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
DISPATCH_FILE_END_3

# ---------------------------------------------------------------- app/Filament/Shared/Ai/TripsPage.php
mkdir -p 'app/Filament/Shared/Ai'
cat > 'app/Filament/Shared/Ai/TripsPage.php' <<'DISPATCH_FILE_END_4'
<?php

namespace App\Filament\Shared\Ai;

use App\Support\Ai\TripPlanner;
use App\Support\BoxSizes;
use BackedEnum;
use Filament\Notifications\Notification;
use Filament\Support\Icons\Heroicon;
use Illuminate\Support\Carbon;
use Illuminate\Support\Collection;
use Illuminate\Support\Facades\Auth;
use Illuminate\Support\Str;
use Throwable;

/** AI trip helper: a draft of trips from the ready boxes and free trucks; nothing is created until you press Create. */
abstract class TripsPage extends AiPage
{
    protected string $view = 'filament.ai.trips';

    protected static string $feature = 'trips';

    protected static string|BackedEnum|null $navigationIcon = Heroicon::OutlinedTruck;

    protected static ?string $navigationLabel = 'AI trip helper';

    protected static ?string $title = 'AI trip helper';

    protected static ?string $slug = 'ai-trips';

    protected static ?int $navigationSort = 0;

    public string $mode = '';

    public string $date = '';

    public string $instruction = '';

    /** @var list<array{truck_id: int, dest: ?int, why: string, places: list<array{place: string, units: list<string>}>}> */
    public array $trips = [];

    public string $note = '';

    public bool $usedAi = false;

    public bool $drafted = false;

    public array $created = [];

    public ?string $error = null;

    protected ?Collection $unitCache = null;

    public static function canAccess(): bool
    {
        return parent::canAccess() && TripPlanner::modesFor(Auth::user()) !== [];
    }

    public function getSubheading(): ?string
    {
        return 'The AI drafts trips from the boxes waiting for a trip and your free trucks. Nothing is created until you press Create.';
    }

    public function mount(): void
    {
        $this->mode = TripPlanner::modesFor(Auth::user())[0];
        $this->date = now()->addDay()->toDateString();
    }

    protected function planner(): TripPlanner
    {
        $modes = TripPlanner::modesFor(Auth::user());
        if (! in_array($this->mode, $modes, true)) {
            $this->mode = $modes[0];
        }

        return new TripPlanner(Auth::user(), $this->mode);
    }

    protected function units(): Collection
    {
        return $this->unitCache ??= $this->planner()->units();
    }

    public function setMode(string $mode): void
    {
        if (in_array($mode, TripPlanner::modesFor(Auth::user()), true)) {
            $this->mode = $mode;
            $this->startOver();
        }
    }

    public function suggest(): void
    {
        $this->error = null;
        $this->created = [];
        $out = $this->planner()->suggest(trim($this->instruction));
        $this->trips = array_map(fn ($t) => ['truck_id' => $t['truck_id'], 'dest' => $t['dest'], 'why' => $t['why'], 'places' => $t['places']], $out['trips']);
        $this->note = $out['note'];
        $this->usedAi = $out['ai'];
        $this->drafted = true;
    }

    /** Move a whole barangay (all its receivers) to the next trip. */
    public function movePlace(int $trip, int $place): void
    {
        if (count($this->trips) < 2 || ! isset($this->trips[$trip]['places'][$place])) {
            return;
        }
        $to = ($trip + 1) % count($this->trips);
        $moving = $this->trips[$trip]['places'][$place];
        array_splice($this->trips[$trip]['places'], $place, 1);
        $slot = collect($this->trips[$to]['places'])->search(fn ($p) => $p['place'] === $moving['place']);
        if ($slot === false) {
            $this->trips[$to]['places'][] = $moving;
        } else {
            $this->trips[$to]['places'][$slot]['units'] = array_values(array_unique(array_merge($this->trips[$to]['places'][$slot]['units'], $moving['units'])));
        }
        $this->trips = array_values(array_filter($this->trips, fn ($t) => $t['places']));
    }

    /** Put a waiting barangay onto a trip. */
    public function addPlace(string $place, int $trip): void
    {
        if (! isset($this->trips[$trip])) {
            return;
        }
        $used = collect($this->trips)->flatMap(fn ($t) => collect($t['places'])->flatMap(fn ($p) => $p['units']))->flip();
        $keys = $this->units()->filter(fn ($u) => TripPlanner::placeKey($u) === $place && ! isset($used[$u['key']]))->pluck('key')->values()->all();
        if ($keys) {
            $this->trips[$trip]['places'][] = ['place' => $place, 'units' => $keys];
        }
    }

    public function removeTrip(int $trip): void
    {
        unset($this->trips[$trip]);
        $this->trips = array_values($this->trips);
    }

    public function setTruck(int $trip, $truckId): void
    {
        $truckId = (int) $truckId;
        if (! isset($this->trips[$trip]) || ! $this->planner()->trucks()->contains('id', $truckId)) {
            return;
        }
        // swap with the trip that had this truck
        foreach ($this->trips as $i => $t) {
            if ($i !== $trip && $t['truck_id'] === $truckId) {
                $this->trips[$i]['truck_id'] = $this->trips[$trip]['truck_id'];
            }
        }
        $this->trips[$trip]['truck_id'] = $truckId;
    }

    public function setDest(int $trip, $dest): void
    {
        if (isset($this->trips[$trip]) && $this->planner()->destinations()->contains('id', (int) $dest)) {
            $this->trips[$trip]['dest'] = (int) $dest;
        }
    }

    public function startOver(): void
    {
        $this->trips = [];
        $this->note = '';
        $this->drafted = false;
        $this->created = [];
        $this->error = null;
    }

    public function create(): void
    {
        $this->error = null;
        $view = $this->tripsView();
        if ($view->isEmpty()) {
            return;
        }
        if ($over = $view->first(fn ($t) => $t['over'])) {
            $this->error = BoxSizes::on()
                ? "{$over['title']} needs more space than truck {$over['truck']} has (".BoxSizes::fmt($over['space'])." of {$over['capacity']}). Move a barangay to another trip first."
                : "{$over['title']} has more boxes than truck {$over['truck']} can carry. Move a barangay to another trip first.";

            return;
        }
        try {
            $date = Carbon::parse($this->date);
        } catch (Throwable) {
            $this->error = 'Pick the trip date.';

            return;
        }
        try {
            $this->created = $this->planner()->create($this->trips, $date);
        } catch (Throwable $e) {
            report($e);
            $this->error = $e instanceof \DomainException ? $e->getMessage() : 'The trips could not be created: '.$e->getMessage();

            return;
        }
        $this->trips = [];
        $this->drafted = false;
        Notification::make()->title(count($this->created).' '.str('trip')->plural(count($this->created)).' created')->success()->send();
    }

    /** The draft with counts, for the screen. */
    protected function tripsView(): Collection
    {
        $units = $this->units()->keyBy('key');
        $trucks = $this->planner()->trucks()->keyBy('id');
        $word = $this->mode === 'transfer' ? 'Transfer' : 'Trip';

        return collect($this->trips)->map(function ($t, $i) use ($units, $trucks, $word) {
            $places = collect($t['places'])->map(function ($p) use ($units) {
                $us = collect($p['units'])->map(fn ($k) => $units[$k] ?? null)->filter();

                return [
                    'place' => $p['place'], 'barangay' => Str::afterLast($p['place'], ' › '),
                    'city' => Str::of($p['place'])->beforeLast(' › ')->afterLast(' › ')->toString(),
                    'n' => $us->sum('n'), 'space' => $us->sum('space'), 'receivers' => $us->count(), 'big' => $us->sortByDesc('n')->first(),
                ];
            })->filter(fn ($p) => $p['n'] > 0)->values();
            $all = collect($t['places'])->flatMap(fn ($p) => $p['units'])->map(fn ($k) => $units[$k] ?? null)->filter();
            $truck = $trucks[$t['truck_id']] ?? null;
            $n = $all->sum('n');
            $space = BoxSizes::half($all->sum('space'));
            $cap = $truck['capacity'] ?? 0;
            $mix = [];
            foreach ($all as $u) {
                foreach ($u['mix'] ?? [] as $name => $c) {
                    $mix[$name] = ($mix[$name] ?? 0) + $c;
                }
            }
            arsort($mix);

            return [
                'i' => $i, 'title' => $word.' '.($i + 1), 'truck_id' => $t['truck_id'], 'truck' => $truck['plate'] ?? '—', 'capacitySet' => $truck['set'] ?? false,
                'capacity' => $cap, 'boxes' => $n, 'space' => $space, 'mix' => BoxSizes::mixText($mix),
                'pct' => $cap ? min(100, (int) round($space / $cap * 100)) : 0, 'over' => $cap && $space > $cap,
                'prio' => $all->sum('prio'), 'retry' => $all->sum('retry'), 'dest' => $t['dest'], 'why' => $t['why'], 'places' => $places,
            ];
        })->filter(fn ($t) => $t['boxes'] > 0)->values();
    }

    protected function getViewData(): array
    {
        $planner = $this->planner();
        $units = $this->units();
        $used = collect($this->trips)->flatMap(fn ($t) => collect($t['places'])->flatMap(fn ($p) => $p['units']))->flip();
        $waiting = $units->reject(fn ($u) => isset($used[$u['key']]));

        $tree = $units->groupBy('province')->sortKeys()->map(fn ($p, $prov) => [
            'name' => $prov, 'n' => $p->sum('n'),
            'cities' => $p->groupBy('city')->sortKeys()->map(fn ($c, $city) => [
                'name' => $city, 'n' => $c->sum('n'),
                'brgys' => $c->groupBy('barangay')->sortKeys()->map(fn ($b, $brgy) => $brgy.' '.$b->sum('n'))->join(' · '),
            ])->values(),
        ])->values();

        return [
            'paused' => $this->pausedReason(),
            'modes' => collect(TripPlanner::modesFor(Auth::user()))->mapWithKeys(fn ($m) => [$m => TripPlanner::MODES[$m]]),
            'tree' => $tree,
            'ready' => $units->sum('n'),
            'prio' => $units->sum('prio'),
            'retry' => $units->sum('retry'),
            'bigGroups' => $units->where('n', '>=', 5)->count(),
            'tripsView' => $this->tripsView(),
            'trucks' => $planner->trucks(),
            'dests' => $planner->destinations(),
            'waitingPlaces' => $waiting->groupBy(fn ($u) => TripPlanner::placeKey($u))->map(fn ($g, $k) => ['place' => $k, 'n' => $g->sum('n'), 'prio' => $g->sum('prio') + $g->sum('retry')])->sortByDesc('prio')->values(),
            'word' => $this->mode === 'transfer' ? 'transfer' : 'trip',
            'bySpace' => BoxSizes::on(),
            'readySpace' => BoxSizes::half($units->sum('space')),
        ];
    }
}
DISPATCH_FILE_END_4

# ---------------------------------------------------------------- app/Models/Boxes/BoxSize.php
mkdir -p 'app/Models/Boxes'
cat > 'app/Models/Boxes/BoxSize.php' <<'DISPATCH_FILE_END_5'
<?php

namespace App\Models\Boxes;

use App\Support\BoxSizes;
use Illuminate\Database\Eloquent\Model;

/** One box type from the manifests and the truck space it takes (normal box = 1). */
class BoxSize extends Model
{
    protected $table = 'box_sizes';

    protected $guarded = [];

    protected function casts(): array
    {
        return ['spellings' => 'array', 'kept_apart' => 'array', 'space' => 'float', 'is_base' => 'boolean', 'is_set' => 'boolean'];
    }

    protected static function booted(): void
    {
        static::saved(fn () => BoxSizes::forget());
        static::deleted(fn () => BoxSizes::forget());
    }
}
DISPATCH_FILE_END_5

# ---------------------------------------------------------------- app/Support/Ai/AiFeatures.php
mkdir -p 'app/Support/Ai'
cat > 'app/Support/Ai/AiFeatures.php' <<'DISPATCH_FILE_END_6'
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
        'box_sizes' => ['Box sizes: same box, different spelling', 'In Settings → Box sizes, finds box types on the manifests that are the same box written differently ("Bulilit" and "Small", "X-LARGE" and "XL") so you can join them.', 'Admin', true],
        'help_ask' => ['Help answers', 'In the Help guide, staff and drivers ask in their own words (English, Tagalog or Taglish) and get a short answer taken only from the guides, with the right guide to open.', 'Admin · Warehouse · Partner hub · Scan app · Driver app', true],
        'customer_chat' => ['Customer chat', 'A public page where receivers type their box number and ask questions. Answers come from tracking; anything else goes to staff.', 'Receivers · Admin · Partner hub', true],
    ];

    public static function title(string $key): string
    {
        return self::ALL[$key][0] ?? $key;
    }
}
DISPATCH_FILE_END_6

# ---------------------------------------------------------------- app/Support/Ai/TripPlanner.php
mkdir -p 'app/Support/Ai'
cat > 'app/Support/Ai/TripPlanner.php' <<'DISPATCH_FILE_END_7'
<?php

namespace App\Support\Ai;

use App\Models\DeliveryAttempt;
use App\Models\Deliverylog;
use App\Models\Invoice;
use App\Models\Logistichub;
use App\Models\Tripinvoice;
use App\Models\Truck;
use App\Models\User;
use App\Models\Warehouse;
use App\Models\Whdeliverylog;
use App\Services\TripAssignment;
use App\Support\BoxSizes;
use Filament\Facades\Filament;
use Illuminate\Support\Carbon;
use Illuminate\Support\Collection;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Str;

/**
 * AI trip helper. The AI only decides which places go together on which truck;
 * the rules are kept here in code:
 *  - boxes for the same receiver are never split,
 *  - priority and tried-before boxes go first,
 *  - a truck is never filled over its capacity (in space: Settings → Box sizes; a big box takes more),
 *  - only free trucks of your own hub, only boxes that are not on a trip yet.
 * Trip numbers are given by the system when the trips are created, as always.
 */
class TripPlanner
{
    /** Used when a truck has no capacity set. */
    public const DEFAULT_CAPACITY = 50;

    public const MODES = [
        'delivery' => 'Delivery trips',
        'transfer' => 'Warehouse transfer',
        'hub' => 'Hub trips',
    ];

    public function __construct(public readonly User $user, public readonly string $mode) {}

    /** Which kinds of trips this person can make in the panel they are in. */
    public static function modesFor(User $user, ?string $panel = null): array
    {
        $panel ??= Filament::getCurrentPanel()?->getId();
        $hub = AiScope::hubId($user);
        if ($hub === false || ! $user->logistichub_id) {
            return [];
        }

        return match (true) {
            $panel === 'company' || (bool) $hub => Logistichub::whereKey($user->logistichub_id)->value('is_company') ? ['hub'] : [],
            $panel === 'warehouse' => $user->warehouse_id ? ['delivery', 'transfer'] : [],
            default => ['delivery'],
        };
    }

    /** In the warehouse panel only that warehouse's boxes are used. */
    protected function warehouseOnly(): ?int
    {
        return Filament::getCurrentPanel()?->getId() === 'warehouse' || $this->mode === 'transfer'
            ? ($this->user->warehouse_id ?: -1)
            : null;
    }

    /**
     * Ready boxes, grouped per receiver (one "unit" = all boxes of one receiver).
     *
     * @return Collection<string, array{key: string, name: string, province: string, city: string, barangay: string, ids: list<int>, n: int, prio: int, retry: int}>
     */
    public function units(): Collection
    {
        if ($this->mode === 'hub') {
            $rows = Tripinvoice::query()->with('invdata')
                ->where('logistichub_id', $this->user->logistichub_id)
                ->where('is_loaded', true)->where('hub_assigned', false)->where('is_delivered', false)
                ->limit(3000)->get();
            $boxes = $rows->filter(fn ($t) => $t->invdata)->map(fn ($t) => ['id' => $t->id, 'inv' => $t->invdata]);
        } else {
            $q = Invoice::query()->where('is_verified', true)->where('is_delivered', false)->where('is_assigned', false);
            if ($this->mode === 'transfer') {
                $q->where('wh_is_assigned', false);
            }
            if ($wh = $this->warehouseOnly()) {
                $q->where('warehouse_id', $wh);
            }
            $boxes = $q->limit(3000)->get()->map(fn ($i) => ['id' => $i->id, 'inv' => $i]);
        }

        $tried = DeliveryAttempt::whereIn('invoice_id', $boxes->map(fn ($b) => $b['inv']->id))->distinct()->pluck('invoice_id')->flip();
        $clean = fn ($v) => Str::of((string) $v)->squish()->title()->toString();

        return $boxes->groupBy(fn ($b) => static::receiverKey($b['inv']))->map(function (Collection $g, string $key) use ($tried, $clean) {
            $first = $g->first()['inv'];

            return [
                'key' => $key,
                'name' => $clean($first->receiver_name),
                'province' => $clean($first->receiver_province) ?: 'No province',
                'city' => $clean($first->receiver_city) ?: 'No city',
                'barangay' => $clean($first->receiver_barangay) ?: 'No barangay',
                'ids' => $g->pluck('id')->values()->all(),
                'n' => $g->count(),
                'space' => BoxSizes::half($g->sum(fn ($b) => BoxSizes::spaceOf($b['inv']->boxtype))),
                'mix' => $g->countBy(fn ($b) => BoxSizes::nameOfType($b['inv']->boxtype))->all(),
                'prio' => $g->filter(fn ($b) => $b['inv']->is_priority)->count(),
                'retry' => $g->filter(fn ($b) => isset($tried[$b['inv']->id]))->count(),
            ];
        });
    }

    /** Same receiver = same name and address, or same phone number. */
    public static function receiverKey(Invoice $i): string
    {
        $phone = substr(preg_replace('/\D+/', '', (string) $i->receiver_mobile_no), -10);
        if (strlen($phone) >= 9) {
            return 'p'.$phone;
        }

        return 'n'.md5(Str::lower(Str::squish($i->receiver_name.'|'.$i->receiver_address.'|'.$i->receiver_barangay.'|'.$i->receiver_city)));
    }

    public static function placeKey(array $u): string
    {
        return $u['province'].' › '.$u['city'].' › '.$u['barangay'];
    }

    /** Free trucks of this hub (only trucks; drivers are not assigned). */
    public function trucks(): Collection
    {
        return Truck::where('is_active', true)->where('is_assigned', false)
            ->where('logistichub_id', $this->user->logistichub_id)->orderBy('plate_no')->get()
            ->map(fn (Truck $t) => ['id' => $t->id, 'plate' => $t->plate_no, 'capacity' => \App\Support\TruckSpace::usable($t, self::DEFAULT_CAPACITY), 'set' => (bool) ($t->capacity ?: \App\Support\TruckSpace::fit($t)), 'kind' => $t->description ?: $t->category]);
    }

    /** Where a trip can go: hubs for delivery trips, other warehouses for transfers. */
    public function destinations(): Collection
    {
        return match ($this->mode) {
            'transfer' => Warehouse::where('id', '!=', $this->user->warehouse_id)->orderBy('name')->get()
                ->map(fn ($w) => ['id' => $w->id, 'name' => $w->name, 'place' => trim($w->city.', '.$w->province, ', ')]),
            'delivery' => Logistichub::where('is_active', true)->orderBy('hub_name')->get()
                ->map(fn ($h) => ['id' => $h->id, 'name' => $h->hub_name, 'place' => $h->hub_code]),
            default => collect(),
        };
    }

    /**
     * Make a draft. Returns trips with places (each place = a barangay with its receiver groups) and what was left out.
     *
     * @return array{trips: list<array>, left: list<string>, note: string, ai: bool}
     */
    public function suggest(string $instruction = ''): array
    {
        $units = $this->units();
        $trucks = $this->trucks();
        if ($units->isEmpty()) {
            return ['trips' => [], 'left' => [], 'note' => 'No boxes are waiting for a trip.', 'ai' => false];
        }
        if ($trucks->isEmpty()) {
            return ['trips' => [], 'left' => [], 'note' => 'No free trucks. Release a truck from a finished trip first.', 'ai' => false];
        }

        $places = $units->groupBy(fn ($u) => static::placeKey($u))->map(fn ($g, $k) => [
            'place' => $k, 'boxes' => $g->sum('n'), 'space' => $g->sum('space'), 'receivers' => $g->count(), 'biggest_receiver' => $g->max('space'),
            'priority' => $g->sum('prio'), 'tried_before' => $g->sum('retry'),
        ])->sortBy('place')->values();

        $ai = false;
        $note = '';
        $plan = null;
        if (Ai::enabled('trips')) {
            try {
                $out = Ai::json('trips',
                    'You plan delivery trips for a Philippine balikbayan box cargo company. Group places that are close together '
                    .'(same province first, then same or neighbouring city/municipality, then barangays) onto the free trucks. '
                    .(BoxSizes::on()
                        ? 'Each truck has a capacity in space (a normal box is 1, bigger boxes take more): the total "space" of the places on a truck must not go over its capacity. '
                        : 'Each truck has a capacity in boxes: do not plan more boxes than the capacity. ')
                    .'Places with priority or tried-before boxes must be planned first. '
                    .'You may leave places out when there is no room (they wait for the next day). Use each truck at most once. '
                    .($this->mode === 'transfer' ? 'These are transfers to other warehouses: also pick the destination warehouse id closest to the places. ' : '')
                    .'Return {"trips": [{"truck_id": id, '.($this->mode === 'transfer' ? '"warehouse_id": id, ' : '').'"places": ["exact place text", ...], "why": "one short reason"}], "note": "one or two short sentences: what was planned and what was left for later"}.',
                    json_encode([
                        'instruction_from_staff' => $instruction ?: 'Plan trips for the ready boxes.',
                        'places' => $places, 'trucks' => $trucks->map(fn ($t) => ['truck_id' => $t['id'], 'plate' => $t['plate'], 'capacity' => $t['capacity']]),
                        'warehouses' => $this->mode === 'transfer' ? $this->destinations() : null,
                    ], JSON_UNESCAPED_UNICODE),
                    'smart', 2500);
                $plan = collect($out['trips'] ?? [])->map(fn ($t) => [
                    'truck_id' => (int) ($t['truck_id'] ?? 0), 'dest' => isset($t['warehouse_id']) ? (int) $t['warehouse_id'] : null,
                    'places' => array_values(array_filter((array) ($t['places'] ?? []), 'is_string')), 'why' => (string) ($t['why'] ?? ''),
                ])->all();
                $note = (string) ($out['note'] ?? '');
                $ai = true;
            } catch (AiUnavailable $e) {
                $note = 'Made without AI ('.$e->getMessage().') by grouping province, city and barangay in order.';
            }
        } else {
            $note = 'Made without AI by grouping province, city and barangay in order. '.Ai::whyOff('trips');
        }

        $plan ??= $this->simplePlan($places, $trucks);

        return $this->fill($plan, $units, $trucks, $note, $ai);
    }

    /** Without AI: one province per truck, places with priority first, then city and barangay in order. */
    protected function simplePlan(Collection $places, Collection $trucks): array
    {
        $prov = fn ($p) => Str::before($p['place'], ' › ');
        $urgentProv = $places->filter(fn ($p) => $p['priority'] + $p['tried_before'] > 0)->map($prov)->unique()->flip();
        $order = $places->sortBy(fn ($p) => [isset($urgentProv[$prov($p)]) ? 0 : 1, $prov($p), ($p['priority'] + $p['tried_before']) > 0 ? 0 : 1, $p['place']])->values();
        $plan = [];
        $ti = -1;
        $load = 0;
        $current = null;
        foreach ($order as $p) {
            $needNew = $ti < 0 || $prov($p) !== $current || $load + $p['biggest_receiver'] > $trucks[$ti]['capacity'];
            if ($needNew) {
                $ti++;
                $load = 0;
                $current = $prov($p);
            }
            if ($ti >= $trucks->count()) {
                break;
            }
            $plan[$ti] ??= ['truck_id' => $trucks[$ti]['id'], 'dest' => null, 'places' => [], 'why' => 'Places in '.$current.', next to each other in the list.'];
            $plan[$ti]['places'][] = $p['place'];
            $load += min($p['space'], $trucks[$ti]['capacity'] - $load);
        }

        return array_values($plan);
    }

    /** Put the receiver groups into the planned trips, keeping every rule. */
    public function fill(array $plan, Collection $units, Collection $trucks, string $note, bool $ai): array
    {
        $byPlace = $units->groupBy(fn ($u) => static::placeKey($u));
        $index = $byPlace->keys()->mapWithKeys(fn ($k) => [mb_strtolower($k) => $k]);
        $resolve = fn (string $name) => $index[mb_strtolower(trim($name))]
            ?? $byPlace->keys()->first(fn ($k) => str_ends_with(mb_strtolower($k), mb_strtolower(trim(Str::afterLast($name, '›')))));
        $usedTrucks = [];
        $usedUnits = [];
        $trips = [];
        $dests = $this->destinations()->keyBy('id');

        foreach ($plan as $p) {
            $truck = $trucks->firstWhere('id', $p['truck_id']);
            if (! $truck || isset($usedTrucks[$truck['id']])) {
                continue;
            }
            $usedTrucks[$truck['id']] = true;
            $trip = ['truck_id' => $truck['id'], 'dest' => $p['dest'] && $dests->has($p['dest']) ? $p['dest'] : $this->defaultDest(), 'why' => $p['why'], 'places' => []];
            $load = 0;
            // priority and tried-before receivers first, then the biggest groups
            foreach ($p['places'] as $asked) {
                $placeName = $resolve((string) $asked);
                if (! $placeName) {
                    continue;
                }
                $group = ($byPlace[$placeName] ?? collect())->reject(fn ($u) => isset($usedUnits[$u['key']]))
                    ->sortBy(fn ($u) => [-($u['prio'] + $u['retry']), -$u['space']]);
                $keys = [];
                foreach ($group as $u) {
                    if ($load + $u['space'] > $truck['capacity']) {
                        continue; // the whole receiver waits; never split
                    }
                    $keys[] = $u['key'];
                    $usedUnits[$u['key']] = true;
                    $load += $u['space'];
                }
                if ($keys) {
                    $trip['places'][] = ['place' => $placeName, 'units' => $keys];
                }
            }
            if ($trip['places']) {
                $trip['load'] = $load;
                $trip['capacity'] = $truck['capacity'];
                $trips[] = $trip;
            }
        }

        // boxes that were not planned: put them on a trip with room in the same province (priority and tried-before first)
        $waiting = $units->reject(fn ($u) => isset($usedUnits[$u['key']]))->sortBy(fn ($u) => [-($u['prio'] + $u['retry']), -$u['space']]);
        foreach ($waiting as $u) {
            $place = static::placeKey($u);
            $sameProvince = collect($trips)->keys()->filter(fn ($i) => collect($trips[$i]['places'])->contains(fn ($pl) => str_starts_with($pl['place'], $u['province'].' ›')));
            // a place already on a trip goes there first
            $order = $sameProvince->sortBy(fn ($i) => collect($trips[$i]['places'])->contains('place', $place) ? 0 : 1);
            foreach ($order as $i) {
                if ($trips[$i]['load'] + $u['space'] <= $trips[$i]['capacity']) {
                    $slot = collect($trips[$i]['places'])->search(fn ($pl) => $pl['place'] === $place);
                    if ($slot === false) {
                        $trips[$i]['places'][] = ['place' => $place, 'units' => [$u['key']]];
                    } else {
                        $trips[$i]['places'][$slot]['units'][] = $u['key'];
                    }
                    $trips[$i]['load'] += $u['space'];
                    $usedUnits[$u['key']] = true;
                    break;
                }
            }
        }

        $left = $units->reject(fn ($u) => isset($usedUnits[$u['key']]));

        return [
            'trips' => $trips,
            'left' => $left->groupBy(fn ($u) => static::placeKey($u))->map(fn ($g, $k) => $k.' ('.$g->sum('n').(BoxSizes::on() && $g->sum('space') != $g->sum('n') ? ' · '.BoxSizes::fmt($g->sum('space')).' space' : '').')')->values()->all(),
            'leftPrio' => $left->sum('prio'),
            'note' => $note,
            'ai' => $ai,
        ];
    }

    public function defaultDest(): ?int
    {
        return match ($this->mode) {
            'delivery' => $this->user->logistichub_id,
            'transfer' => $this->destinations()->first()['id'] ?? null,
            default => null,
        };
    }

    /**
     * Create the trips of the draft. Trip numbers come from the system as usual.
     *
     * @return list<array{number: string, truck: string, boxes: int, skipped: int}>
     */
    public function create(array $trips, Carbon $date): array
    {
        $units = $this->units()->keyBy('key');
        $service = app(TripAssignment::class);
        $made = [];

        foreach ($trips as $t) {
            $ids = collect($t['places'])->flatMap(fn ($p) => $p['units'])->flatMap(fn ($k) => $units[$k]['ids'] ?? [])->unique()->values();
            if ($ids->isEmpty()) {
                continue;
            }

            $made[] = DB::transaction(function () use ($t, $ids, $date, $service) {
                $truck = Truck::whereKey($t['truck_id'])->where('logistichub_id', $this->user->logistichub_id)
                    ->where('is_active', true)->lockForUpdate()->first();
                if (! $truck || ($this->mode !== 'transfer' && $truck->is_assigned)) {
                    throw new \DomainException('Truck '.($truck?->plate_no ?? '#'.$t['truck_id']).' is no longer free. Suggest again.');
                }

                if ($this->mode === 'transfer') {
                    $trip = Whdeliverylog::create([
                        'truck_id' => $truck->id, 'warehouse_id' => $t['dest'] ?: $this->defaultDest(),
                        'departure_date' => $date->toDateString(), 'delivery_date' => $date->toDateString(),
                        'user_id' => $this->user->id, 'user_whid' => $this->user->warehouse_id,
                    ]);
                    $added = $service->addToWarehouseTrip($trip, Invoice::whereKey($ids)->get());
                } else {
                    $trip = Deliverylog::create([
                        'truck_id' => $truck->id, 'trip_day' => 1, 'eta' => $date->toDateString(), 'departure_date' => $date->toDateString(),
                        'logistichub_id' => $this->user->logistichub_id,
                        'assigned_to' => $this->mode === 'hub' ? $this->user->logistichub_id : ($t['dest'] ?: $this->user->logistichub_id),
                        'user_id' => $this->user->id,
                    ]);
                    $truck->update(['is_assigned' => true]);
                    $added = $this->mode === 'hub'
                        ? $service->addToHubTrip($trip, Tripinvoice::whereKey($ids)->get())
                        : $service->addToDeliveryTrip($trip, Invoice::whereKey($ids)->get());
                }

                return ['number' => (string) $trip->trip_number, 'truck' => (string) $truck->plate_no, 'boxes' => $added, 'skipped' => $ids->count() - $added,
                    'places' => collect($t['places'])->map(fn ($p) => Str::afterLast($p['place'], ' › '))->join(', ')];
            });
        }

        return $made;
    }
}
DISPATCH_FILE_END_7

# ---------------------------------------------------------------- app/Support/BoxSizes.php
mkdir -p 'app/Support'
cat > 'app/Support/BoxSizes.php' <<'DISPATCH_FILE_END_8'
<?php

namespace App\Support;

use App\Models\AppSetting;
use App\Models\Boxes\BoxSize;
use App\Models\Deliverylog;
use App\Models\Invoice;
use App\Models\Tripinvoice;
use App\Support\Ai\Ai;
use Illuminate\Support\Collection;
use Illuminate\Support\Facades\Cache;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Schema;
use Illuminate\Support\Str;

/**
 * Box sizes: trucks fill by space, not by count. The box types come from the manifests
 * (the invoices' box type); the normal box is 1 space and the others are set next to it.
 * Different spellings of one type ("LARGE", "Large box", "LG") are joined into one size.
 * A box with no type, or a type not set yet, counts as 1.
 */
class BoxSizes
{
    public const SETTING = 'boxes.by_space';

    /** Words that mean the same size, after cleaning. */
    protected const SAME = [
        ['xl', 'xlarge', 'extralarge', 'xlg', 'exl', 'xtralarge'],
        ['xxl', 'xxlarge', '2xl', 'extraextralarge'],
        ['l', 'lg', 'lrg', 'lge', 'large'],
        ['m', 'md', 'med', 'mdm', 'medium', 'mid'],
        ['s', 'sm', 'sml', 'small'],
        ['xs', 'xsmall', 'extrasmall'],
        ['reg', 'regular', 'std', 'standard', 'normal'],
        ['jb', 'jmb', 'jumbo'],
    ];

    protected static ?array $map = null;

    protected static ?array $names = null;

    protected static ?bool $ready = null;

    /** The app these memos belong to (a new one in each test, or after a queue worker restart). */
    protected static ?\WeakReference $app = null;

    protected static function fresh(): void
    {
        $app = app();
        if (static::$app?->get() !== $app) {
            static::$app = \WeakReference::create($app);
            static::$map = static::$names = static::$ready = null;
        }
    }

    public static function ready(): bool
    {
        static::fresh();

        return static::$ready ??= Schema::hasTable('box_sizes');
    }

    /**
     * Plan trips by space: switched on (the default) and at least one box type is set bigger
     * or smaller than the normal box. Until then trucks are counted in boxes, as before.
     */
    public static function on(): bool
    {
        return static::switchedOn() && collect(static::map())->contains(fn ($v) => abs($v - 1) > 0.01);
    }

    public static function switchedOn(): bool
    {
        return static::ready() && (string) AppSetting::get(static::SETTING, '1') === '1';
    }

    public static function forget(): void
    {
        static::$map = null;
        static::$names = null;
        static::$ready = null;
        Cache::forget('box.sizes');
        Cache::forget('box.names');
    }

    /** "X-LARGE", "Large Box", " large " → "xlarge", "large", "large". */
    public static function key(?string $type): string
    {
        $k = preg_replace('/[^a-z0-9]+/', '', Str::lower(Str::ascii((string) $type)));
        $short = preg_replace('/(boxes|box|size)$/', '', $k);

        return $short !== '' ? $short : $k;
    }

    /** cleaned spelling => space */
    public static function map(): array
    {
        static::fresh();
        if (static::$map !== null) {
            return static::$map;
        }
        if (! static::ready()) {
            return static::$map = [];
        }

        return static::$map = Cache::remember('box.sizes', 600, function () {
            $out = [];
            foreach (BoxSize::all() as $s) {
                foreach ($s->spellings ?? [] as $k) {
                    $out[$k] = $s->is_set ? (float) $s->space : 1.0;
                }
            }

            return $out;
        });
    }

    /** The truck space one box takes. 1 when planning by space is off, or the type is unknown. */
    public static function spaceOf(?string $type): float
    {
        if (! static::on()) {
            return 1.0;
        }
        $k = static::key($type);

        return $k === '' ? 1.0 : (static::map()[$k] ?? 1.0);
    }

    /** The size a box type belongs to. */
    public static function sizeOf(?string $type): ?BoxSize
    {
        $k = static::key($type);
        if ($k === '' || ! static::ready()) {
            return null;
        }

        return static::sizes()->first(fn (BoxSize $s) => in_array($k, $s->spellings ?? [], true));
    }

    /** The size name for a written box type ("LG" → "Large"); "No type" when empty. */
    public static function nameOfType(?string $type): string
    {
        $k = static::key($type);
        if ($k === '') {
            return 'No type';
        }
        static::fresh();
        static::$names ??= static::ready() ? Cache::remember('box.names', 600, function () {
            $out = [];
            foreach (BoxSize::all() as $s) {
                foreach ($s->spellings ?? [] as $sp) {
                    $out[$sp] = $s->name;
                }
            }

            return $out;
        }) : [];

        return static::$names[$k] ?? trim((string) $type);
    }

    /** @return Collection<int, BoxSize> */
    public static function sizes(): Collection
    {
        return static::ready() ? BoxSize::orderByDesc('is_base')->orderBy('is_set')->orderBy('space')->orderBy('name')->get() : collect();
    }

    public static function base(): ?BoxSize
    {
        return static::ready() ? BoxSize::where('is_base', true)->first() : null;
    }

    /** 1.5 → "1½", 0.5 → "½", 2 → "2". */
    public static function fmt(float $n): string
    {
        $n = round($n * 2) / 2;
        $whole = (int) floor($n);
        $half = $n - $whole > 0.01;

        return $half ? ($whole === 0 ? '½' : $whole.'½') : (string) $whole;
    }

    /** Round to the nearest half. */
    public static function half(float $n): float
    {
        return round($n * 2) / 2;
    }

    // ------------------------------------------------------------------ reading the manifests

    /**
     * How many boxes of each written box type. @return Collection<int, array{raw: string, key: string, n: int}>
     */
    public static function written(?int $days = null): Collection
    {
        $q = Invoice::query()->whereNotNull('boxtype')->where('boxtype', '!=', '');
        if ($days) {
            $q->where('created_at', '>=', now()->subDays($days));
        }

        return $q->select('boxtype', DB::raw('count(*) as n'))->groupBy('boxtype')->get()
            ->map(fn ($r) => ['raw' => trim((string) $r->boxtype), 'key' => static::key($r->boxtype), 'n' => (int) $r->n])
            ->filter(fn ($r) => $r['key'] !== '')->values();
    }

    /**
     * Add every box type on the manifests that is not here yet (as "New · not set").
     * The most common one becomes the normal box the first time.
     */
    public static function sync(): int
    {
        if (! static::ready()) {
            return 0;
        }
        $known = BoxSize::pluck('spellings')->flatten()->flip();
        $added = 0;
        $groups = static::written()->groupBy('key');
        foreach ($groups as $key => $rows) {
            if (isset($known[$key])) {
                continue;
            }
            BoxSize::create(['name' => static::nameOf($rows), 'spellings' => [$key], 'space' => 1, 'is_base' => false, 'is_set' => false]);
            $added++;
        }
        if (! BoxSize::where('is_base', true)->exists() && ($top = static::biggest())) {
            $top->update(['is_base' => true, 'is_set' => true, 'space' => 1]);
        }
        static::forget();

        return $added;
    }

    /** The name as most often written: "LARGE" and "Large" → "Large". */
    protected static function nameOf(Collection $rows): string
    {
        $raw = $rows->sortByDesc('n')->first()['raw'];

        return Str::length($raw) <= 3 ? Str::upper($raw) : Str::title(Str::lower($raw));
    }

    /** The size with the most boxes. */
    protected static function biggest(): ?BoxSize
    {
        $counts = static::counts();

        return BoxSize::all()->sortByDesc(fn (BoxSize $s) => $counts[$s->id] ?? 0)->first();
    }

    /** size id => boxes (last $days days, or all when null). */
    public static function counts(?int $days = null): array
    {
        $byKey = static::written($days)->groupBy('key')->map(fn ($g) => $g->sum('n'));
        $out = [];
        foreach (BoxSize::all() as $s) {
            $out[$s->id] = collect($s->spellings ?? [])->sum(fn ($k) => $byKey[$k] ?? 0);
        }

        return $out;
    }

    /** size id => the ways it is written on the manifests ("LARGE", "Large box", "LG"). */
    public static function spellingsShown(): array
    {
        $byKey = static::written()->groupBy('key')->map(fn ($g) => $g->sortByDesc('n')->pluck('raw')->unique()->take(4)->all());
        $out = [];
        foreach (BoxSize::all() as $s) {
            $out[$s->id] = collect($s->spellings ?? [])->flatMap(fn ($k) => $byKey[$k] ?? [])->unique()->take(6)->values()->all();
        }

        return $out;
    }

    // ------------------------------------------------------------------ changing sizes

    /** Make this the normal box (1). The others are changed so they stay the same real size. */
    public static function setBase(BoxSize $size): void
    {
        $old = (float) ($size->is_set ? $size->space : 1) ?: 1;
        DB::transaction(function () use ($size, $old) {
            foreach (BoxSize::all() as $s) {
                if ($s->id === $size->id) {
                    $s->update(['is_base' => true, 'is_set' => true, 'space' => 1]);
                } else {
                    $s->update(['is_base' => false, 'space' => max(0.5, static::half(((float) $s->space) / $old))]);
                }
            }
        });
        static::forget();
    }

    public static function setSpace(BoxSize $size, float $space): void
    {
        if ($size->is_base) {
            return;
        }
        $size->update(['space' => max(0.5, min(10, static::half($space))), 'is_set' => true]);
    }

    /** "X-LARGE" is the same as "XL": its spellings move over and it is gone. */
    public static function join(BoxSize $from, BoxSize $into): void
    {
        if ($from->id === $into->id) {
            return;
        }
        DB::transaction(function () use ($from, $into) {
            $into->update(['spellings' => array_values(array_unique([...($into->spellings ?? []), ...($from->spellings ?? [])]))]);
            if ($from->is_base) {
                $into->update(['is_base' => true, 'is_set' => true, 'space' => 1]);
            }
            $from->delete();
        });
        static::forget();
    }

    public static function keepApart(BoxSize $a, BoxSize $b): void
    {
        $a->update(['kept_apart' => array_values(array_unique([...($a->kept_apart ?? []), $b->id]))]);
        $b->update(['kept_apart' => array_values(array_unique([...($b->kept_apart ?? []), $a->id]))]);
    }

    /**
     * Box types that look like the same box. The smaller one joins the bigger one.
     *
     * @return list<array{from: BoxSize, into: BoxSize, why: string}>
     */
    public static function lookAlike(): array
    {
        $sizes = BoxSize::all();
        $counts = static::counts();
        $pairs = [];
        $seen = [];
        foreach ($sizes as $a) {
            foreach ($sizes as $b) {
                if ($a->id >= $b->id || in_array($b->id, $a->kept_apart ?? [], true)) {
                    continue;
                }
                $why = static::sameWhy($a->spellings ?? [], $b->spellings ?? []);
                if (! $why) {
                    continue;
                }
                [$from, $into] = ($counts[$a->id] ?? 0) <= ($counts[$b->id] ?? 0) ? [$a, $b] : [$b, $a];
                if ($from->is_base) {
                    [$from, $into] = [$into, $from];
                }
                if (isset($seen[$from->id])) {
                    continue;
                }
                $seen[$from->id] = true;
                $pairs[] = ['from' => $from, 'into' => $into, 'why' => $why];
            }
        }

        return $pairs;
    }

    protected static function sameWhy(array $a, array $b): ?string
    {
        $groupOf = function (string $k): ?int {
            foreach (static::SAME as $i => $group) {
                if (in_array($k, $group, true)) {
                    return $i;
                }
            }

            return null;
        };
        foreach ($a as $x) {
            foreach ($b as $y) {
                $gx = $groupOf($x);
                $gy = $groupOf($y);
                if ($gx !== null && $gx === $gy) {
                    return 'same size word';
                }
                if ($gx !== null && $gy !== null) {
                    continue; // two different size words ("large" and "xlarge")
                }
                $short = strlen($x) <= strlen($y) ? $x : $y;
                $long = $short === $x ? $y : $x;
                if (strlen($short) >= 3 && str_starts_with($long, $short)) {
                    return 'one is short for the other';
                }
                if (strlen($short) >= 5 && strlen($x) === strlen($y) && levenshtein($x, $y) <= 1) {
                    return 'spelled almost the same';
                }
            }
        }

        return null;
    }

    /**
     * With the AI helper on: pairs the simple check missed (consolidator names like "Bulilit"
     * and "Small"). Only names that exist are used.
     *
     * @return list<array{from: BoxSize, into: BoxSize, why: string}>
     */
    public static function lookAlikeAi(): array
    {
        if (! Ai::enabled('box_sizes')) {
            return [];
        }
        $sizes = BoxSize::all();
        $counts = static::counts();
        $list = $sizes->map(fn (BoxSize $s) => ['id' => $s->id, 'name' => $s->name, 'written' => $s->spellings, 'boxes' => $counts[$s->id] ?? 0])->values()->all();
        try {
            $out = Ai::json('box_sizes',
                'These are box types written on cargo manifests of a Philippine balikbayan box company. Find types that are clearly the SAME box size written differently '
                .'(abbreviations, typos, Tagalog/English, "box" added). Do not pair different sizes. Return {"same": [{"from_id": id, "into_id": id, "why": "few words"}]}; the one with fewer boxes is "from".',
                json_encode($list, JSON_UNESCAPED_UNICODE), 'fast', 600);
        } catch (\Throwable) {
            return [];
        }
        $byId = $sizes->keyBy('id');
        $pairs = [];
        foreach ((array) ($out['same'] ?? []) as $p) {
            $from = $byId[(int) ($p['from_id'] ?? 0)] ?? null;
            $into = $byId[(int) ($p['into_id'] ?? 0)] ?? null;
            if ($from && $into && $from->id !== $into->id && ! $from->is_base && ! in_array($into->id, $from->kept_apart ?? [], true)) {
                $pairs[] = ['from' => $from, 'into' => $into, 'why' => '✨ '.Str::limit((string) ($p['why'] ?? 'AI'), 60)];
            }
        }

        return $pairs;
    }

    // ------------------------------------------------------------------ trucks and trips

    /**
     * The space of boxes, and how many of each size.
     *
     * @param  iterable<Invoice|null>  $invoices
     * @return array{space: float, boxes: int, mix: array<string, int>}
     */
    public static function measure(iterable $invoices): array
    {
        $space = 0.0;
        $boxes = 0;
        $mix = [];
        foreach ($invoices as $inv) {
            $boxes++;
            $space += static::spaceOf($inv?->boxtype);
            $name = static::nameOfType($inv?->boxtype);
            $mix[$name] = ($mix[$name] ?? 0) + 1;
        }
        arsort($mix);

        return ['space' => static::half($space), 'boxes' => $boxes, 'mix' => $mix];
    }

    /** "24 Medium · 8 XL · 6 Bulilit" */
    public static function mixText(array $mix, int $max = 4): string
    {
        return collect($mix)->take($max)->map(fn ($n, $name) => $n.' '.$name)->join(' · ');
    }

    /**
     * Space on a trip: loaded so far and in all, and the truck's space.
     *
     * @return array{loaded: float, total: float, cap: ?int, reserve: int}
     */
    public static function tripSpace(Deliverylog $trip, bool $atHub = false): array
    {
        $boxes = Tripinvoice::query()->with('invdata:id,boxtype')
            ->where($atHub ? 'deliveryloghub_id' : 'deliverylog_id', $trip->id)
            ->get(['id', 'invoice_id', 'is_loaded', 'is_loaded_hub']);
        $loadedFlag = $atHub ? 'is_loaded_hub' : 'is_loaded';
        $loaded = $boxes->filter(fn ($b) => $b->{$loadedFlag})->sum(fn ($b) => static::spaceOf($b->invdata?->boxtype));

        return [
            'loaded' => static::half($loaded),
            'total' => static::half($boxes->sum(fn ($b) => static::spaceOf($b->invdata?->boxtype))),
            'cap' => $trip->truck && ($trip->truck->capacity || TruckSpace::fit($trip->truck)) ? TruckSpace::capacity($trip->truck) : null,
            'reserve' => $trip->truck && TruckSpace::ready() ? (int) ($trip->truck->reserve_pct ?? 0) : 0,
        ];
    }

    /**
     * The most each truck carried on one trip in the last 90 days.
     *
     * @return array<int, array{space: float, boxes: int}>
     */
    public static function truckPast(array $truckIds): array
    {
        if (! $truckIds) {
            return [];
        }
        $trips = Deliverylog::whereIn('truck_id', $truckIds)->where('created_at', '>=', now()->subDays(90))->pluck('truck_id', 'id');
        if ($trips->isEmpty()) {
            return [];
        }
        $rows = Tripinvoice::query()->join('invoices', 'invoices.id', '=', 'tripinvoices.invoice_id')
            ->whereIn('tripinvoices.deliverylog_id', $trips->keys())
            ->select('tripinvoices.deliverylog_id', 'invoices.boxtype', DB::raw('count(*) as n'))
            ->groupBy('tripinvoices.deliverylog_id', 'invoices.boxtype')->get();
        $perTrip = [];
        foreach ($rows as $r) {
            $t = $r->deliverylog_id;
            $perTrip[$t]['space'] = ($perTrip[$t]['space'] ?? 0) + static::spaceOf($r->boxtype) * $r->n;
            $perTrip[$t]['boxes'] = ($perTrip[$t]['boxes'] ?? 0) + $r->n;
        }
        $out = [];
        foreach ($perTrip as $tripId => $v) {
            $truck = $trips[$tripId];
            if (! isset($out[$truck]) || $v['space'] > $out[$truck]['space']) {
                $out[$truck] = ['space' => static::half($v['space']), 'boxes' => $v['boxes']];
            }
        }

        return $out;
    }
}
DISPATCH_FILE_END_8

# ---------------------------------------------------------------- app/Support/Help/DefaultGuides.php
mkdir -p 'app/Support/Help'
cat > 'app/Support/Help/DefaultGuides.php' <<'DISPATCH_FILE_END_9'
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
                    $s('A truck is waiting', 'Tap "A truck is waiting" and pick the warehouse trip. Its boxes show 🚚: put them straight on the truck. "Put in section instead" keeps one box in its section.', 'May truck na naghihintay', 'Pindutin ang "A truck is waiting" at piliin ang warehouse trip. Ang mga box nito ay may 🚚: diretso sa truck. Ang "Put in section instead" ay itatabi ang box sa seksyon.'),
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
        ];
    }
}
DISPATCH_FILE_END_9

# ---------------------------------------------------------------- app/Support/TruckSpace.php
mkdir -p 'app/Support'
cat > 'app/Support/TruckSpace.php' <<'DISPATCH_FILE_END_10'
<?php

namespace App\Support;

use App\Models\Boxes\BoxSize;
use App\Models\Deliverylog;
use App\Models\Invoice;
use App\Models\Truck;
use App\Models\Tripinvoice;
use Illuminate\Support\Collection;
use Illuminate\Support\Facades\Schema;

/**
 * Space from real sizes: box dimensions give each box type its space (next to the normal box),
 * the truck's cargo box gives how many normal boxes fit (packed about 85% full), and a reserve
 * keeps room for odd items (bikes, TVs). At loading, room left can be topped up with more boxes.
 */
class TruckSpace
{
    public const FILL = 85;

    public static function ready(): bool
    {
        return Schema::hasColumn('trucks', 'reserve_pct');
    }

    public static function volume(?int $l, ?int $w, ?int $h): ?float
    {
        return $l && $w && $h ? (float) $l * $w * $h : null;
    }

    public static function boxVolume(?BoxSize $s): ?float
    {
        return $s ? static::volume($s->length_cm, $s->width_cm, $s->height_cm) : null;
    }

    /** Space from dimensions, next to the normal box (rounded to a half). */
    public static function spaceFromDims(BoxSize $s): ?float
    {
        $base = static::boxVolume(BoxSizes::base());
        $v = static::boxVolume($s);

        return $base && $v ? max(0.5, BoxSizes::half($v / $base)) : null;
    }

    /** How many normal boxes fit in the truck's cargo box, packed fill% full. */
    public static function fit(Truck $t): ?int
    {
        $base = static::boxVolume(BoxSizes::base());
        $cargo = static::ready() ? static::volume($t->cargo_length_cm, $t->cargo_width_cm, $t->cargo_height_cm) : null;

        return $base && $cargo ? (int) floor($cargo * (($t->fill_pct ?: self::FILL) / 100) / $base) : null;
    }

    /** The truck's space: set by hand, else from its cargo box, else 50. */
    public static function capacity(Truck $t, int $default = 50): int
    {
        return (int) ($t->capacity ?: static::fit($t) ?: $default);
    }

    /** Space the planner may fill: capacity minus the reserve. */
    public static function usable(Truck $t, int $default = 50): int
    {
        $r = static::ready() ? (int) ($t->reserve_pct ?? 0) : 0;

        return max(1, (int) floor(static::capacity($t, $default) * (1 - min(90, $r) / 100)));
    }

    /**
     * Room left on a trip once its boxes are loaded, and waiting boxes that fit, same provinces first.
     *
     * @return array{room: float, cap: int, boxes: Collection}
     */
    public static function topUp(Deliverylog $trip, int $max = 8): array
    {
        $truck = $trip->truck;
        if (! $truck) {
            return ['room' => 0.0, 'cap' => 0, 'boxes' => collect()];
        }
        $rows = Tripinvoice::with('invdata:id,boxtype,receiver_province,warehouse_id')->where('deliverylog_id', $trip->id)->get();
        $used = $rows->sum(fn ($r) => BoxSizes::spaceOf($r->invdata?->boxtype));
        $cap = static::capacity($truck);
        $room = BoxSizes::half(max(0, $cap - $used));
        if ($room < 1) {
            return ['room' => $room, 'cap' => $cap, 'boxes' => collect()];
        }
        $provinces = $rows->pluck('invdata.receiver_province')->filter()->map(fn ($p) => mb_strtolower(trim($p)))->unique()->values();
        $wh = $rows->pluck('invdata.warehouse_id')->filter()->mode()[0] ?? null;
        $cands = Invoice::query()->where('is_verified', true)->where('is_assigned', false)->where('wh_is_assigned', false)
            ->where(fn ($q) => $q->where('is_delivered', false)->orWhereNull('is_delivered'))
            ->when($wh, fn ($q) => $q->where('warehouse_id', $wh))
            ->when($provinces->isNotEmpty(), fn ($q) => $q->whereIn(\Illuminate\Support\Facades\DB::raw('lower(trim(receiver_province))'), $provinces->all()))
            ->orderByDesc('is_priority')->orderBy('id')->limit(60)->get();
        $out = collect();
        $left = $room;
        foreach ($cands as $b) {
            $sp = BoxSizes::spaceOf($b->boxtype);
            if ($sp <= $left) {
                $out->push(['id' => $b->id, 'invoice' => $b->invoice, 'name' => \Illuminate\Support\Str::title((string) $b->receiver_name),
                    'place' => collect([$b->receiver_city, $b->receiver_province])->filter()->join(', '), 'space' => $sp, 'section' => $b->whSection?->code]);
                $left -= $sp;
            }
            if ($out->count() >= $max) {
                break;
            }
        }

        return ['room' => $room, 'cap' => $cap, 'boxes' => $out];
    }
}
DISPATCH_FILE_END_10

# ---------------------------------------------------------------- database/migrations/2026_11_13_000021_create_box_sizes_table.php
mkdir -p 'database/migrations'
cat > 'database/migrations/2026_11_13_000021_create_box_sizes_table.php' <<'DISPATCH_FILE_END_11'
<?php

use App\Support\Help\Help;
use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

/** Box sizes: how much truck space each box type from the manifests takes (your normal box = 1). */
return new class extends Migration
{
    public function up(): void
    {
        if (! Schema::hasTable('box_sizes')) {
            Schema::create('box_sizes', function (Blueprint $table) {
                $table->id();
                /** The name shown, as most often written on the manifests. */
                $table->string('name', 80);
                /** Every way it is written, cleaned ("LARGE", "Large box", "large" → "large"). */
                $table->json('spellings');
                /** Truck space it takes, in normal boxes. */
                $table->decimal('space', 4, 1)->default(1);
                $table->boolean('is_base')->default(false);
                /** False until an admin has looked at it (shown as New · not set). */
                $table->boolean('is_set')->default(false);
                /** Box types the admin said are not the same as this one. */
                $table->json('kept_apart')->nullable();
                $table->timestamps();
            });
        }

        Help::installDefaults();
    }

    public function down(): void
    {
        Schema::dropIfExists('box_sizes');
    }
};
DISPATCH_FILE_END_11

# ---------------------------------------------------------------- database/migrations/2026_11_15_000026_add_box_dimensions.php
mkdir -p 'database/migrations'
cat > 'database/migrations/2026_11_15_000026_add_box_dimensions.php' <<'DISPATCH_FILE_END_12'
<?php

use App\Support\Help\Help;
use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

/** Box dimensions, the truck's cargo box, how full it can be packed, and a reserve for odd items. */
return new class extends Migration
{
    public function up(): void
    {
        Schema::table('box_sizes', function (Blueprint $t) {
            $t->unsignedSmallInteger('length_cm')->nullable();
            $t->unsignedSmallInteger('width_cm')->nullable();
            $t->unsignedSmallInteger('height_cm')->nullable();
        });
        Schema::table('trucks', function (Blueprint $t) {
            $t->unsignedSmallInteger('cargo_length_cm')->nullable();
            $t->unsignedSmallInteger('cargo_width_cm')->nullable();
            $t->unsignedSmallInteger('cargo_height_cm')->nullable();
            $t->unsignedTinyInteger('fill_pct')->nullable();     // how full it really packs (default 85)
            $t->unsignedTinyInteger('reserve_pct')->nullable();  // kept free for bikes, TVs, odd items
        });
        Help::installDefaults();
    }

    public function down(): void
    {
        Schema::table('trucks', fn (Blueprint $t) => $t->dropColumn(['cargo_length_cm', 'cargo_width_cm', 'cargo_height_cm', 'fill_pct', 'reserve_pct']));
        Schema::table('box_sizes', fn (Blueprint $t) => $t->dropColumn(['length_cm', 'width_cm', 'height_cm']));
    }
};
DISPATCH_FILE_END_12

# ---------------------------------------------------------------- resources/css/filament/admin/theme.css
mkdir -p 'resources/css/filament/admin'
cat > 'resources/css/filament/admin/theme.css' <<'DISPATCH_FILE_END_13'
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
.ds-sx__tile.is-truck strong { font-size: 2.8rem; }
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
DISPATCH_FILE_END_13

# ---------------------------------------------------------------- resources/views/filament/ai/trips.blade.php
mkdir -p 'resources/views/filament/ai'
cat > 'resources/views/filament/ai/trips.blade.php' <<'DISPATCH_FILE_END_14'
<x-filament-panels::page>
<div class="ds-ai ds-ai-trips">
    @include('filament.ai.paused', ['paused' => $paused])

    @if (count($modes) > 1)
        <div class="ds-ai__seg">
            @foreach ($modes as $k => $l)
                <button type="button" wire:click="setMode('{{ $k }}')" @class(['is-on' => $mode === $k])>{{ $l }}</button>
            @endforeach
        </div>
    @endif

    @if ($created)
        <section class="ds-ai__card">
            <div class="ds-ai__made"><span>✓</span><span><b>{{ count($created) }} {{ str($word)->plural(count($created)) }} created</b><small>Boxes are on the trips. Load them with Load Truck or the Scan app, as usual.</small></span></div>
            @foreach ($created as $c)
                <div class="ds-ai__madeRow"><b>{{ $c['number'] }}</b><span>🚚 {{ $c['truck'] }}</span><span>{{ $c['places'] }}</span><b>{{ $c['boxes'] }} boxes</b>
                    @if ($c['skipped'])<small class="is-amber">{{ $c['skipped'] }} skipped (already on another trip)</small>@endif</div>
            @endforeach
            <div class="ds-ai__two"><x-filament::button color="gray" wire:click="startOver">Plan more {{ str($word)->plural() }}</x-filament::button></div>
        </section>
    @else
        <div class="ds-ai__card ds-ai__plan">
            <span class="ds-ai__badge">AI</span>
            <input type="text" wire:model="instruction" placeholder="Optional: e.g. only Cebu and Bohol, keep NBC 557 for tomorrow" maxlength="300" aria-label="Instructions for the AI">
            <label class="ds-ai__date"><span>Date</span><input type="date" wire:model="date"></label>
            <x-filament::button wire:click="suggest" wire:loading.attr="disabled" wire:target="suggest">
                <span wire:loading.remove wire:target="suggest">{{ $drafted ? 'Suggest again' : 'Suggest '.str($word)->plural() }}</span>
                <span wire:loading wire:target="suggest">Planning…</span>
            </x-filament::button>
        </div>

        <div class="ds-ai__split is-trips">
            <section class="ds-ai__card">
                <div class="ds-ai__card-head"><b>{{ $mode === 'hub' ? 'At your hub' : 'Waiting for a '.$word }}</b><small class="ds-board__muted">{{ number_format($ready) }} boxes @if ($bySpace && $readySpace != $ready)· {{ \App\Support\BoxSizes::fmt($readySpace) }} space @endif</small></div>
                <div class="ds-ai__two is-left">
                    @if ($prio)<i class="ds-ai__tag is-damaged">{{ $prio }} priority</i>@endif
                    @if ($retry)<i class="ds-ai__tag is-open">{{ $retry }} tried before</i>@endif
                    @if ($bigGroups)<i class="ds-ai__tag is-wet">{{ $bigGroups }} {{ str('receiver')->plural($bigGroups) }} with 5+ boxes</i>@endif
                </div>
                <div class="ds-ai__tree">
                    @forelse ($tree as $p)
                        <div><b>{{ $p['name'] }} <small>{{ $p['n'] }}</small></b>
                            @foreach ($p['cities'] as $c)
                                <span><b>{{ $c['name'] }} <small>{{ $c['n'] }}</small></b><small>{{ $c['brgys'] }}</small></span>
                            @endforeach
                        </div>
                    @empty
                        <p class="ds-ai__empty">No boxes are waiting.</p>
                    @endforelse
                </div>
                <small class="ds-board__muted">Free trucks{{ $bySpace ? ' (space)' : '' }}: {{ $trucks->map(fn ($t) => $t['plate'].' ('.$t['capacity'].($t['set'] ? '' : '?').')')->join(', ') ?: 'none' }}@if ($trucks->contains('set', false)) · ? = no capacity set, {{ \App\Support\Ai\TripPlanner::DEFAULT_CAPACITY }} is used @endif</small>
            </section>

            <section class="ds-ai__tripcol">
                @if ($error)<p class="ds-ai__err">{{ $error }}</p>@endif
                @if (! $drafted)
                    <div class="ds-ai__card ds-ai__empty">Press <b>Suggest {{ str($word)->plural() }}</b>. Boxes are grouped by province, city and barangay; priority and tried-before boxes go first; boxes for the same receiver always stay together.</div>
                @else
                    <div class="ds-ai__said"><span class="ds-ai__badge">{{ $usedAi ? 'AI' : '≡' }}</span><span><b>Draft · nothing created yet.</b> {{ $note }}</span></div>
                    <div class="ds-ai__trips">
                        @forelse ($tripsView as $t)
                            <div @class(['ds-ai__trip', 'is-over' => $t['over']]) wire:key="t-{{ $t['i'] }}-{{ $t['truck_id'] }}">
                                <div class="ds-ai__card-head"><b>{{ $t['title'] }}</b><button type="button" class="ds-ai__link" wire:click="removeTrip({{ $t['i'] }})">Remove</button></div>
                                <select class="ds-ai__select is-full" wire:change="setTruck({{ $t['i'] }}, $event.target.value)" aria-label="Truck">
                                    @foreach ($trucks as $tr)<option value="{{ $tr['id'] }}" @selected($tr['id'] === $t['truck_id'])>🚚 {{ $tr['plate'] }} · fits {{ $tr['capacity'] }}{{ $bySpace ? ' space' : '' }}</option>@endforeach
                                </select>
                                @if ($mode !== 'hub')
                                    <label class="ds-ai__dest"><span>{{ $mode === 'transfer' ? 'To warehouse' : 'Going to' }}</span>
                                        <select class="ds-ai__select" wire:change="setDest({{ $t['i'] }}, $event.target.value)">
                                            @foreach ($dests as $d)<option value="{{ $d['id'] }}" @selected($d['id'] === $t['dest'])>{{ $d['name'] }}</option>@endforeach
                                        </select>
                                    </label>
                                @endif
                                @if ($bySpace)
                                    <div class="ds-ai__fill"><span><b>{{ \App\Support\BoxSizes::fmt($t['space']) }} / {{ $t['capacity'] }}</b> space · {{ $t['boxes'] }} {{ str('box')->plural($t['boxes']) }}</span><span class="{{ $t['over'] ? 'is-red' : '' }}">{{ $t['over'] ? \App\Support\BoxSizes::fmt($t['space'] - $t['capacity']).' too much' : $t['pct'].'% full' }}</span></div>
                                @else
                                    <div class="ds-ai__fill"><span><b>{{ $t['boxes'] }}</b> {{ str('box')->plural($t['boxes']) }}</span><span class="{{ $t['over'] ? 'is-red' : '' }}">{{ $t['over'] ? ($t['boxes'] - $t['capacity']).' too many' : $t['pct'].'% full' }}</span></div>
                                @endif
                                <i class="ds-ai__meter"><s style="width: {{ $t['pct'] }}%" @class(['is-bad' => $t['over'], 'is-warn' => ! $t['over'] && $t['pct'] > 85])></s></i>
                                @if ($bySpace && $t['mix'])<small class="ds-board__muted">{{ $t['mix'] }}</small>@endif
                                <div class="ds-ai__two is-left">
                                    @if ($t['prio'])<i class="ds-ai__tag is-damaged">{{ $t['prio'] }} priority</i>@endif
                                    @if ($t['retry'])<i class="ds-ai__tag is-open">{{ $t['retry'] }} tried before</i>@endif
                                </div>
                                @foreach ($t['places'] as $pi => $p)
                                    <button type="button" class="ds-ai__place" wire:click="movePlace({{ $t['i'] }}, {{ $pi }})" title="Move to the next {{ $word }}">
                                        <span><b>{{ $p['barangay'] }}</b> {{ $p['city'] }}<small>{{ $p['receivers'] }} {{ str('receiver')->plural($p['receivers']) }}@if ($p['big'] && $p['big']['n'] >= 3) · {{ $p['big']['name'] }} {{ $p['big']['n'] }} together @endif</small></span>
                                        <span>{{ $p['n'] }}@if ($bySpace && $p['space'] != $p['n'])<small> · {{ \App\Support\BoxSizes::fmt($p['space']) }} sp</small>@endif ⇄</span>
                                    </button>
                                @endforeach
                                @if ($t['why'])<small class="ds-ai__why1">✦ {{ $t['why'] }}</small>@endif
                            </div>
                        @empty
                            <div class="ds-ai__card ds-ai__empty">{{ $note ?: 'No trips could be made.' }}</div>
                        @endforelse
                    </div>
                    @if ($waitingPlaces->isNotEmpty() && $tripsView->isNotEmpty())
                        <section class="ds-ai__card">
                            <div class="ds-ai__card-head"><b>Left for later</b><small class="ds-board__muted">Click to add to {{ $word }} 1, or press Suggest again</small></div>
                            <div class="ds-ai__two is-left">
                                @foreach ($waitingPlaces->take(40) as $w)
                                    <button type="button" class="ds-ai__chipbtn {{ $w['prio'] ? 'is-prio' : '' }}" wire:click="addPlace(@js($w['place']), 0)">{{ \Illuminate\Support\Str::afterLast($w['place'], ' › ') }} · {{ $w['n'] }}</button>
                                @endforeach
                            </div>
                        </section>
                    @endif
                    @if ($tripsView->isNotEmpty())
                        <div class="ds-ai__card ds-ai__foot">
                            <span>{{ $tripsView->count() }} {{ str($word)->plural($tripsView->count()) }} · {{ $tripsView->sum('boxes') }} of {{ $ready }} boxes @if ($bySpace) · {{ \App\Support\BoxSizes::fmt($tripsView->sum('space')) }} space used of {{ $tripsView->sum('capacity') }}@endif. Click a barangay to move it to the next {{ $word }}. Trip numbers are given when you press Create.</span>
                            <x-filament::button color="gray" wire:click="startOver">Start over</x-filament::button>
                            <x-filament::button wire:click="create" wire:confirm="Create {{ $tripsView->count() }} {{ str($word)->plural($tripsView->count()) }} for {{ $date }}?" wire:loading.attr="disabled">Create {{ $tripsView->count() }} {{ str($word)->plural($tripsView->count()) }}</x-filament::button>
                        </div>
                    @endif
                @endif
            </section>
        </div>
    @endif
</div>
</x-filament-panels::page>
DISPATCH_FILE_END_14

# ---------------------------------------------------------------- resources/views/filament/boxes/settings.blade.php
mkdir -p 'resources/views/filament/boxes'
cat > 'resources/views/filament/boxes/settings.blade.php' <<'DISPATCH_FILE_END_15'
@php($fmt = fn ($n) => \App\Support\BoxSizes::fmt((float) $n))
<x-filament-panels::page>
<div class="ds-bx">
    <header class="ds-bx__head">
        <p>The box types below come from your manifests. Your normal box is <b>1</b>; set the others next to it. Trucks are then filled by space, not by count. Changes are saved right away.</p>
        <button type="button" wire:click="toggle" @class(['ds-bx__switch', 'is-on' => $on]) aria-pressed="{{ $on ? 'true' : 'false' }}">
            <i aria-hidden="true"></i>{{ $on ? 'Plan trips by space: on' : 'Plan trips by space: off (count boxes)' }}
        </button>
    </header>
    @if ($on && ! $working)
        <p class="ds-bx__note">Every box type is still 1, so trucks are counted in boxes. Set a bigger or smaller type below and trips are planned by space.</p>
    @endif

    <div class="ds-bx__two">
        <section class="ds-board__panel ds-bx__types">
            <div class="ds-board__panel-head"><h2>Box types from your manifests</h2><span class="ds-board__muted">Last 30 days</span></div>
            @forelse ($sizes as $s)
                <div wire:key="size-{{ $s->id }}" @class(['ds-bx__type', 'is-new' => ! $s->is_set])>
                    <span class="ds-bx__name">
                        <span><b>{{ $s->name }}</b>
                            @if ($s->is_base)<em class="ds-bx__tag is-base">Normal box = 1</em>@endif
                            @unless ($s->is_set)<em class="ds-bx__tag is-new">New · not set</em>@endunless
                        </span>
                        <small>{{ number_format($counts30[$s->id] ?? 0) }} {{ str('box')->plural($counts30[$s->id] ?? 0) }}@if (($countsAll[$s->id] ?? 0) !== ($counts30[$s->id] ?? 0)) ({{ number_format($countsAll[$s->id] ?? 0) }} in all)@endif
                            @if ($written[$s->id] ?? null)· written as {{ implode(' · ', $written[$s->id]) }}@endif</small>
                        @if ($dimsOn)
                            <span class="ds-bx__dims">
                                <input type="number" min="1" max="999" placeholder="L" value="{{ $s->length_cm }}" wire:change="setDim({{ $s->id }}, 'length_cm', $event.target.value)" aria-label="Length cm">×
                                <input type="number" min="1" max="999" placeholder="W" value="{{ $s->width_cm }}" wire:change="setDim({{ $s->id }}, 'width_cm', $event.target.value)" aria-label="Width cm">×
                                <input type="number" min="1" max="999" placeholder="H" value="{{ $s->height_cm }}" wire:change="setDim({{ $s->id }}, 'height_cm', $event.target.value)" aria-label="Height cm"> cm
                                @if (! $s->is_base && ($fd = \App\Support\TruckSpace::spaceFromDims($s)) && abs($fd - (float) $s->space) >= 0.25)
                                    <button type="button" wire:click="useDims({{ $s->id }})">From the size: {{ $fmt($fd) }} · use it</button>
                                @endif
                            </span>
                        @endif
                        @unless ($s->is_base)
                            <span class="ds-bx__links">
                                @unless ($s->is_set)<button type="button" wire:click="confirm({{ $s->id }})">Keep at 1</button>@endunless
                                <button type="button" wire:click="makeBase({{ $s->id }})" wire:confirm="Make {{ $s->name }} your normal box (1)? The other sizes are changed to stay the same real size.">Make this the normal box</button>
                            </span>
                        @endunless
                    </span>
                    <span class="ds-bx__step">
                        @if ($s->is_base)
                            <b>1</b>
                        @else
                            <button type="button" wire:click="step({{ $s->id }}, -1)" aria-label="Smaller">−</button>
                            <b>{{ $s->is_set ? $fmt($s->space) : '1?' }}</b>
                            <button type="button" wire:click="step({{ $s->id }}, 1)" aria-label="Bigger">+</button>
                        @endif
                    </span>
                    <span class="ds-bx__pic" aria-hidden="true"><i style="width: {{ round(14 + ($s->is_set ? $s->space : 1) * 15) }}px; height: {{ round(10 + ($s->is_set ? $s->space : 1) * 11) }}px"></i></span>
                </div>
            @empty
                <p class="ds-board__muted">No box types on your invoices yet. They show up here after a manifest is imported.</p>
            @endforelse
            <div class="ds-bx__type is-plain">
                <span class="ds-bx__name"><span><b>No box type on the manifest</b></span><small>{{ number_format($noType) }} {{ str('box')->plural($noType) }} · counts as your normal box</small></span>
                <span class="ds-bx__step"><b>1</b></span><span></span>
            </div>
        </section>

        <div class="ds-bx__side">
            @if ($pairs->isNotEmpty())
                <section class="ds-board__panel ds-bx__same">
                    <div class="ds-board__panel-head"><h2>These look like the same box</h2></div>
                    @foreach ($pairs as $p)
                        <div wire:key="pair-{{ $p['from']->id }}-{{ $p['into']->id }}">
                            <span><span>“{{ $p['from']->name }}” ({{ number_format($countsAll[$p['from']->id] ?? 0) }}) looks like <b>{{ $p['into']->name }}</b></span><small>{{ $p['why'] }}</small></span>
                            <x-filament::button size="sm" wire:click="join({{ $p['from']->id }}, {{ $p['into']->id }})">Join</x-filament::button>
                            <x-filament::button size="sm" color="gray" wire:click="keepApart({{ $p['from']->id }}, {{ $p['into']->id }})">Keep apart</x-filament::button>
                        </div>
                    @endforeach
                </section>
            @endif
            @if ($aiOn && $sizes->count() > 1)
                <button type="button" class="ds-bx__ai" wire:click="askAi" wire:loading.attr="disabled" wire:target="askAi">
                    <span wire:loading.remove wire:target="askAi">✨ {{ $aiChecked ? 'Ask the AI again' : 'Ask the AI to find more look-alikes' }}</span>
                    <span wire:loading wire:target="askAi">Checking…</span>
                </button>
            @endif

            <section class="ds-board__panel ds-bx__trucks">
                <div class="ds-board__panel-head"><h2>Truck space</h2><span class="ds-board__muted">In normal boxes{{ isset($base) ? ' ('.$base->name.')' : '' }}</span></div>
                @forelse ($trucks as $t)
                    @php($cap = (int) ($t->capacity ?: 50))
                    <div wire:key="truck-{{ $t->id }}">
                        <span>
                            <b>{{ $t->plate_no }}</b> <small>{{ $t->description ?: $t->category }}{{ ($hubs[$t->logistichub_id] ?? null) ? ' · '.$hubs[$t->logistichub_id] : '' }}{{ $t->capacity ? '' : ' · not set, 50 is used' }}</small>
                            <small>= {{ collect([$cap.' '.($base?->name ?? 'normal'), $big ? (int) floor($cap / $big->space).' '.$big->name : null, $small ? (int) floor($cap / $small->space).' '.$small->name : null])->filter()->join(', or ') }}</small>
                            @if ($dimsOn)
                                <span class="ds-bx__dims">
                                    Cargo box <input type="number" min="1" max="2000" placeholder="L" value="{{ $t->cargo_length_cm }}" wire:change="setTruckDim({{ $t->id }}, 'cargo_length_cm', $event.target.value)" aria-label="Cargo length cm">×
                                    <input type="number" min="1" max="2000" placeholder="W" value="{{ $t->cargo_width_cm }}" wire:change="setTruckDim({{ $t->id }}, 'cargo_width_cm', $event.target.value)" aria-label="Cargo width cm">×
                                    <input type="number" min="1" max="2000" placeholder="H" value="{{ $t->cargo_height_cm }}" wire:change="setTruckDim({{ $t->id }}, 'cargo_height_cm', $event.target.value)" aria-label="Cargo height cm"> cm ·
                                    packed <input type="number" min="40" max="100" placeholder="85" value="{{ $t->fill_pct }}" wire:change="setTruckDim({{ $t->id }}, 'fill_pct', $event.target.value)" aria-label="Packed percent">% ·
                                    reserve <input type="number" min="0" max="50" placeholder="0" value="{{ $t->reserve_pct }}" wire:change="setTruckDim({{ $t->id }}, 'reserve_pct', $event.target.value)" aria-label="Reserve percent">%
                                    @if (($fit = \App\Support\TruckSpace::fit($t)) && $fit !== (int) $t->capacity)<button type="button" wire:click="useFit({{ $t->id }})">From the cargo box: {{ $fit }} · use it</button>@endif
                                </span>
                                @if ($t->reserve_pct)<small>Trips are planned up to {{ \App\Support\TruckSpace::usable($t) }}: {{ $t->reserve_pct }}% kept free for bikes, TVs and odd items, or a top-up at loading.</small>@endif
                            @endif
                            @if ($past[$t->id] ?? null)<small class="ds-bx__past">Last 90 days: carried up to {{ $fmt($past[$t->id]['space']) }} space ({{ $past[$t->id]['boxes'] }} boxes) on one trip</small>@endif
                        </span>
                        <span class="ds-bx__step">
                            <button type="button" wire:click="truckStep({{ $t->id }}, -1)" aria-label="Less">−</button>
                            <input type="number" min="1" max="2000" value="{{ $cap }}" wire:change="setTruck({{ $t->id }}, $event.target.value)" aria-label="Space for {{ $t->plate_no }}">
                            <button type="button" wire:click="truckStep({{ $t->id }}, 1)" aria-label="More">+</button>
                        </span>
                    </div>
                @empty
                    <p class="ds-board__muted">No active trucks.</p>
                @endforelse
            </section>
        </div>
    </div>
</div>
</x-filament-panels::page>
DISPATCH_FILE_END_15

# ---------------------------------------------------------------- resources/views/filament/scan/app.blade.php
mkdir -p 'resources/views/filament/scan'
cat > 'resources/views/filament/scan/app.blade.php' <<'DISPATCH_FILE_END_16'
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

            @if ($this->mode === 'unload')
                @if ($truck)
                    <div @class(['ds-sx__truck', 'is-paused' => $truck['paused']])>
                        <span class="ds-sx__truckhead"><b>🚚 {{ $truck['paused'] ? 'Paused · ' : '' }}Truck {{ $truck['trip'] }} → {{ $truck['to'] }}</b>
                            <span>
                                <button type="button" wire:click="truckPause({{ $truck['paused'] ? 'false' : 'true' }})">{{ $truck['paused'] ? 'Resume' : 'Pause' }}</button>
                                <button type="button" wire:click="truckStop" wire:confirm="The truck leaves now? Its boxes still in the container go to section {{ $truck['section'] ?? '' }}.">Truck leaves</button>
                            </span>
                        </span>
                        <span class="ds-sx__truckn"><span><b>{{ $truck['onTruck'] }}</b> on truck</span><span><b>{{ max(0, $truck['inSection']) }}</b> in section {{ $truck['section'] ?? '' }}</span><span><b>{{ $truck['inContainer'] }}</b> still in container</span></span>
                    </div>
                @elseif ($truckPicker)
                    <div class="ds-sx__picker">
                        <strong>Which truck is waiting?</strong>
                        @forelse ($trucks as $tk)
                            <button type="button" wire:click="truckStart({{ $tk['id'] }})"><b>{{ $tk['name'] }}</b><small>→ {{ $tk['to'] }}{{ $tk['truck'] ? ' · '.$tk['truck'] : '' }}</small></button>
                        @empty
                            <p>No open warehouse trip from this warehouse. Make the trip first (Warehouse → Warehouse trips).</p>
                        @endforelse
                        <button type="button" class="ds-sx__link" wire:click="openTruckPicker(false)">Cancel</button>
                    </div>
                @elseif (! $status)
                    <button type="button" class="ds-sx__link" wire:click="openTruckPicker">🚚 A truck is waiting for some of these boxes?</button>
                @endif
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
                            <small>{{ ($route['kind'] ?? '') === 'truck' ? 'Put it on the truck' : 'Put this box in' }}</small>
                            <strong>{{ ($route['kind'] ?? '') === 'truck' ? '🚚' : $route['code'] }}</strong>
                            <span>{{ ($route['kind'] ?? '') === 'truck' ? 'Truck '.$route['trip'].' → '.$route['name'] : $route['name'] }}</span>
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
DISPATCH_FILE_END_16

# ---------------------------------------------------------------- tests/Feature/BoxSizesTest.php
mkdir -p 'tests/Feature'
cat > 'tests/Feature/BoxSizesTest.php' <<'DISPATCH_FILE_END_17'
<?php

use App\Filament\Pages\Ai\AiTrips as AdminTrips;
use App\Filament\Pages\BoxSizeSettings;
use App\Filament\Scan\Pages\ScanApp;
use App\Models\Ai\AiSetting;
use App\Models\AppSetting;
use App\Models\Boxes\BoxSize;
use App\Models\Container;
use App\Models\Deliverylog;
use App\Models\Invoice;
use App\Models\Truck;
use App\Models\User;
use App\Services\TripAssignment;
use App\Support\Ai\TripPlanner;
use App\Support\BoxSizes;
use Database\Seeders\DemoSeeder;
use Filament\Facades\Filament;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Illuminate\Support\Facades\Http;
use Livewire\Livewire;

uses(RefreshDatabase::class);

function sizeBox(string $no, string $type, string $name = 'Maria Santos', string $brgy = 'Basak', string $phone = '09171112222'): Invoice
{
    return Invoice::create([
        'container_id' => Container::value('id'), 'invoice' => $no, 'sender_name' => 'Sender', 'receiver_name' => $name,
        'receiver_address' => '1 Street', 'receiver_province' => 'Cebu', 'receiver_city' => 'Mandaue City', 'receiver_barangay' => $brgy,
        'receiver_mobile_no' => $phone, 'boxtype' => $type, 'location_code' => 'X', 'is_verified' => true, 'warehouse_id' => 1,
    ]);
}

function sizeOfName(string $name): BoxSize
{
    return BoxSize::where('name', $name)->firstOrFail();
}

beforeEach(function () {
    (fn () => static::$memo = null)->call(new AppSetting); // kept in memory between tests
    BoxSizes::forget();
    $this->seed(DemoSeeder::class);
    Invoice::query()->update(['boxtype' => 'Medium', 'is_verified' => false]);
    $this->admin = User::where('email', 'admin@example.com')->firstOrFail();
    $this->actingAs($this->admin);
    Filament::setCurrentPanel(Filament::getPanel('admin'));
});

it('reads the box types from the manifests, joins spellings, and makes the most common one the normal box', function () {
    foreach (['LARGE', 'Large Box', 'large'] as $i => $t) {
        sizeBox("L{$i}", $t);
    }
    sizeBox('X1', 'X-LARGE');
    sizeBox('X2', 'XL');
    sizeBox('B1', 'Bulilit');

    expect(BoxSizes::key('Large Box'))->toBe('large')
        ->and(BoxSizes::key(' X-LARGE '))->toBe('xlarge')
        ->and(BoxSizes::key('Med. Box'))->toBe('med');

    BoxSizes::sync();
    expect(BoxSize::pluck('name')->sort()->values()->all())->toBe(['Bulilit', 'Large', 'Medium', 'X-Large', 'XL'])
        ->and(sizeOfName('Medium')->is_base)->toBeTrue()
        ->and(sizeOfName('Large')->is_set)->toBeFalse();

    // a second sync adds nothing new
    expect(BoxSizes::sync())->toBe(0);

    // "X-LARGE" and "XL" look like the same box
    $pairs = collect(BoxSizes::lookAlike());
    expect($pairs)->toHaveCount(1)
        ->and($pairs[0]['into']->name)->toBe('XL');
    BoxSizes::join($pairs[0]['from'], $pairs[0]['into']);
    expect(sizeOfName('XL')->spellings)->toContain('xl', 'xlarge')
        ->and(BoxSizes::lookAlike())->toBe([]);
});

it('counts space only once a size is set, and a missing or unknown type is 1', function () {
    sizeBox('L1', 'Large');
    BoxSizes::sync();
    expect(BoxSizes::on())->toBeFalse()           // everything still 1: count boxes as before
        ->and(BoxSizes::spaceOf('Large'))->toBe(1.0);

    BoxSizes::setSpace(sizeOfName('Large'), 1.5);
    expect(BoxSizes::on())->toBeTrue()
        ->and(BoxSizes::spaceOf('LARGE box'))->toBe(1.5)
        ->and(BoxSizes::spaceOf(''))->toBe(1.0)
        ->and(BoxSizes::spaceOf('Never seen'))->toBe(1.0)
        ->and(BoxSizes::fmt(1.5))->toBe('1½')
        ->and(BoxSizes::fmt(0.5))->toBe('½');

    AppSetting::put(BoxSizes::SETTING, '0');
    BoxSizes::forget();
    expect(BoxSizes::on())->toBeFalse()->and(BoxSizes::spaceOf('Large'))->toBe(1.0);
});

it('keeps the real sizes when the normal box changes', function () {
    sizeBox('L1', 'Large');
    sizeBox('X1', 'XL');
    BoxSizes::sync();
    BoxSizes::setSpace(sizeOfName('Large'), 2);
    BoxSizes::setSpace(sizeOfName('XL'), 4);

    BoxSizes::setBase(sizeOfName('Large'));
    expect(sizeOfName('Large')->space)->toBe(1.0)
        ->and(sizeOfName('XL')->space)->toBe(2.0)
        ->and(sizeOfName('Medium')->space)->toBe(0.5)
        ->and(sizeOfName('Medium')->is_base)->toBeFalse();
});

it('fills trucks by space in the AI trip helper', function () {
    Truck::query()->update(['is_assigned' => true]);
    $hub = $this->admin->logistichub_id;
    $truck = Truck::create(['plate_no' => 'SPC 101', 'logistichub_id' => $hub, 'is_active' => true, 'is_assigned' => false, 'capacity' => 10, 'category' => 'Truck', 'description' => 'Elf', 'registration_no' => 'R1', 'user_id' => $this->admin->id, 'date_registered' => now(), 'date_expired' => now()->addYear()]);
    // Maria: 4 XL (2 each = 8 space); Jose: 4 Medium (4 space). 8 boxes would fit 10 by count, not by space.
    foreach (range(1, 4) as $i) {
        sizeBox("MX{$i}", 'XL');
        sizeBox("JM{$i}", 'Medium', 'Jose Ramos', 'Basak', '09173334444');
    }
    BoxSizes::sync();
    BoxSizes::setSpace(sizeOfName('XL'), 2);

    $units = (new TripPlanner($this->admin, 'delivery'))->units();
    expect($units->firstWhere('name', 'Maria Santos')['space'])->toBe(8.0)
        ->and($units->firstWhere('name', 'Maria Santos')['n'])->toBe(4);

    AiSetting::query()->delete();
    AiSetting::create(['api_key' => null, 'features' => ['trips']]); // made without AI: same rules
    (fn () => static::$memo = null)->call(new AiSetting);
    $page = Livewire::test(AdminTrips::class)->call('suggest');
    $trips = $page->get('trips');
    $keys = collect($trips)->flatMap(fn ($t) => collect($t['places'])->flatMap(fn ($p) => $p['units']));
    expect($keys)->toHaveCount(1); // only one receiver fits by space
    $page->assertSee('/ 10')->assertSee('space')->assertSee('Left for later');

    // forcing both on the truck is blocked
    $page->call('addPlace', 'Cebu › Mandaue City › Basak', 0)->assertSee('too much');
    $page->call('create')->assertSee('needs more space than truck SPC 101');
});

it('shows Settings → Box sizes, sets sizes, joins, sets the base and truck space', function () {
    sizeBox('L1', 'LG');
    sizeBox('L2', 'Large');
    $truck = Truck::first();

    $page = Livewire::test(BoxSizeSettings::class)
        ->assertSee('Box types from your manifests')
        ->assertSee('Normal box = 1')
        ->assertSee('New · not set')
        ->assertSee('These look like the same box')
        ->assertSee('Every box type is still 1');

    $lg = sizeOfName('LG');
    $large = sizeOfName('Large');
    $page->call('join', $lg->id, $large->id)->assertDontSee('These look like the same box');
    $page->call('step', $large->id, 1)->call('step', $large->id, 1)->assertSee('2')->assertDontSee('Every box type is still 1');
    expect($large->fresh()->space)->toBe(2.0)->and($large->fresh()->is_set)->toBeTrue()
        ->and(BoxSizes::spaceOf('LG'))->toBe(2.0);

    $page->call('setTruck', $truck->id, 64);
    expect($truck->fresh()->capacity)->toBe(64);
    $page->call('truckStep', $truck->id, 1);
    expect($truck->fresh()->capacity)->toBe(65);

    $page->call('toggle');
    expect(BoxSizes::on())->toBeFalse();

    $this->get('/box-sizes')->assertOk();
    $this->flushSession();
    $this->actingAs(User::where('email', 'warehouse@example.com')->firstOrFail());
    $this->get('/box-sizes')->assertForbidden();
});

it('shows the size and the space used while loading in the Scan app', function () {
    $hub = $this->admin->logistichub_id;
    Deliverylog::query()->update(['is_active' => false]);
    $truck = Truck::create(['plate_no' => 'SPC 202', 'logistichub_id' => $hub, 'is_active' => true, 'is_assigned' => true, 'capacity' => 20, 'category' => 'Truck', 'description' => 'Elf', 'registration_no' => 'R2', 'user_id' => $this->admin->id, 'date_registered' => now(), 'date_expired' => now()->addYear()]);
    $trip = Deliverylog::create(['truck_id' => $truck->id, 'logistichub_id' => $hub, 'assigned_to' => $hub, 'user_id' => $this->admin->id, 'trip_day' => 1, 'eta' => today(), 'departure_date' => today(), 'is_active' => true]);
    $a = sizeBox('SX1', 'XL');
    $b = sizeBox('SM1', 'Medium', 'Jose Ramos', 'Basak', '09173334444');
    app(TripAssignment::class)->addToDeliveryTrip($trip, collect([$a, $b]));
    BoxSizes::sync();
    BoxSizes::setSpace(sizeOfName('XL'), 2);

    $space = BoxSizes::tripSpace($trip->fresh());
    expect($space)->toBe(['loaded' => 0.0, 'total' => 3.0, 'cap' => 20, 'reserve' => 0]);

    Filament::setCurrentPanel(Filament::getPanel('scan'));
    Livewire::test(ScanApp::class)
        ->call('open', 'load')->call('pick', $trip->id)
        ->assertSee('0 / 20 space')
        ->call('scan', 'SX1')
        ->assertSee('XL · takes 2 space')
        ->assertSee('2 / 20 space');
});

it('lets the AI find look-alikes the simple check misses, using only real box types', function () {
    sizeBox('B1', 'Bulilit');
    sizeBox('S1', 'Small');
    sizeBox('S2', 'Small');
    BoxSizes::sync();
    expect(BoxSizes::lookAlike())->toBe([]);

    AiSetting::query()->delete();
    AiSetting::create(['api_key' => 'sk-ant-test', 'features' => ['box_sizes']]);
    (fn () => static::$memo = null)->call(new AiSetting);
    $bulilit = sizeOfName('Bulilit');
    $small = sizeOfName('Small');
    Http::fake(fn () => Http::response(['content' => [['type' => 'text', 'text' => json_encode(['same' => [
        ['from_id' => $bulilit->id, 'into_id' => $small->id, 'why' => 'Bulilit means small'],
        ['from_id' => 999, 'into_id' => $small->id, 'why' => 'made up'],
    ]])]], 'stop_reason' => 'end_turn', 'usage' => ['input_tokens' => 5, 'output_tokens' => 5]]));

    Livewire::test(BoxSizeSettings::class)
        ->call('askAi')
        ->assertSee('“Bulilit” (1) looks like')
        ->assertSee('Bulilit means small')
        ->call('join', $bulilit->id, $small->id);
    expect(BoxSizes::spaceOf('Bulilit'))->toBe(1.0)
        ->and(sizeOfName('Small')->spellings)->toContain('bulilit');
});
DISPATCH_FILE_END_17

# ---------------------------------------------------------------- tests/Feature/TruckSpaceTest.php
mkdir -p 'tests/Feature'
cat > 'tests/Feature/TruckSpaceTest.php' <<'DISPATCH_FILE_END_18'
<?php

use App\Filament\Pages\BoxSizeSettings;
use App\Filament\Scan\Pages\ScanApp;
use App\Models\AppSetting;
use App\Models\Boxes\BoxSize;
use App\Models\Container;
use App\Models\Deliverylog;
use App\Models\Invoice;
use App\Models\Truck;
use App\Models\Tripinvoice;
use App\Models\User;
use App\Services\TripAssignment;
use App\Support\BoxSizes;
use App\Support\TruckSpace;
use Database\Seeders\DemoSeeder;
use Filament\Facades\Filament;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Livewire\Livewire;

uses(RefreshDatabase::class);

beforeEach(function () {
    (fn () => static::$memo = null)->call(new AppSetting);
    BoxSizes::forget();
    $this->seed(DemoSeeder::class);
    $this->admin = User::where('email', 'admin@example.com')->firstOrFail();
    $this->actingAs($this->admin);
    $mk = fn ($no, $type, $prov = 'Cebu') => Invoice::create(['container_id' => Container::value('id'), 'invoice' => $no, 'sender_name' => 'S', 'receiver_name' => 'R '.$no,
        'receiver_address' => '1', 'receiver_province' => $prov, 'receiver_city' => 'Mandaue City', 'receiver_barangay' => 'Basak', 'receiver_mobile_no' => '0917'.crc32($no),
        'boxtype' => $type, 'location_code' => 'X', 'is_verified' => true, 'warehouse_id' => 1]);
    Invoice::query()->update(['is_verified' => false]);
    $this->boxes = collect([$mk('TS-1', 'Regular'), $mk('TS-2', 'Regular'), $mk('TS-3', 'Jumbo')]);
    $this->waiting = [$mk('TS-4', 'Regular'), $mk('TS-5', 'Jumbo'), $mk('TS-6', 'Regular', 'Bohol')];
    AppSetting::put(BoxSizes::SETTING, '1');
    BoxSizes::sync();
    BoxSizes::setBase(BoxSize::where('name', 'Regular')->firstOrFail());
    BoxSize::where('name', 'Regular')->update(['length_cm' => 50, 'width_cm' => 40, 'height_cm' => 40]);
    BoxSize::where('name', 'Jumbo')->update(['length_cm' => 60, 'width_cm' => 60, 'height_cm' => 60]);
    BoxSizes::forget();
});

it('works out box space from dimensions and truck space from the cargo box', function () {
    $jumbo = BoxSize::where('name', 'Jumbo')->firstOrFail();
    expect(TruckSpace::spaceFromDims($jumbo))->toBe(2.5); // 216000 / 80000 = 2.7 → 2.5

    $truck = Truck::firstOrFail();
    $truck->update(['capacity' => null, 'cargo_length_cm' => 300, 'cargo_width_cm' => 160, 'cargo_height_cm' => 160, 'fill_pct' => null, 'reserve_pct' => 10]);
    expect(TruckSpace::fit($truck))->toBe(81)       // 7.68 m³ × 85% / 0.08 m³
        ->and(TruckSpace::capacity($truck))->toBe(81)
        ->and(TruckSpace::usable($truck))->toBe(72);   // 10% kept free

    Filament::setCurrentPanel(Filament::getPanel('admin'));
    Livewire::test(BoxSizeSettings::class)->assertSee('From the size: 2½')->call('useDims', $jumbo->id)
        ->call('setTruckDim', $truck->id, 'fill_pct', '90')->call('useFit', $truck->id);
    expect((float) $jumbo->fresh()->space)->toBe(2.5)->and($truck->fresh()->capacity)->toBe(86);
});

it('offers boxes to top up the truck when everything is loaded and there is room', function () {
    $truck = Truck::firstOrFail();
    $truck->update(['capacity' => 7]);
    BoxSize::where('name', 'Jumbo')->update(['space' => 2, 'is_set' => true]);
    BoxSizes::forget();
    $trip = Deliverylog::create(['truck_id' => $truck->id, 'logistichub_id' => $this->admin->logistichub_id, 'assigned_to' => $this->admin->logistichub_id, 'user_id' => $this->admin->id, 'trip_day' => 1, 'eta' => today(), 'departure_date' => today(), 'is_active' => true]);
    app(TripAssignment::class)->addToDeliveryTrip($trip, $this->boxes);
    foreach (Tripinvoice::where('deliverylog_id', $trip->id)->get() as $r) {
        app(TripAssignment::class)->markLoaded($r);
    }
    $t = TruckSpace::topUp($trip->fresh('truck'));
    expect($t['room'])->toBe(3.0)->and($t['boxes']->pluck('invoice')->all())->toBe(['TS-4', 'TS-5']); // Bohol is another province

    Filament::setCurrentPanel(Filament::getPanel('scan'));
    Livewire::test(ScanApp::class)->call('open', 'load')->call('pick', $trip->id)->call('finish')
        ->assertSee('Room for about 3 more')->assertSee('TS-4')
        ->call('topUpAdd', $this->waiting[0]->id)->assertSet('screen', 'scan');
    expect(Tripinvoice::where('deliverylog_id', $trip->id)->where('invoice', 'TS-4')->exists())->toBeTrue();
});
DISPATCH_FILE_END_18

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
