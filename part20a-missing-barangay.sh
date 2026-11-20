#!/usr/bin/env bash
#
# Dispatch System — Part 20a · missing barangay + Addresses to check + upgraded AI address cleaning
# Only the files changed in this step; the rest of your project is left as it is.
#
#   cd ~/Desktop/Project/DispatchSystem
#   bash ~/Desktop/Project/part20a-missing-barangay.sh

set -euo pipefail
[ -f artisan ] || { echo "Run this from inside your DispatchSystem project folder (the one with 'artisan')."; exit 1; }

STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="../DispatchSystem-backup-$STAMP.tar.gz"
echo "▶ Backing up the project to $BACKUP"
tar -czf "$BACKUP" --exclude=vendor --exclude=node_modules --exclude=storage/logs .

echo "▶ Writing 27 files"

# ---------------------------------------------------------------- app/Console/Commands/AiWork.php
mkdir -p 'app/Console/Commands'
cat > 'app/Console/Commands/AiWork.php' <<'DISPATCH_FILE_END_0'
<?php

namespace App\Console\Commands;

use App\Models\Ai\AiPhotoCheck;
use App\Support\Aging\BoxAging;
use App\Support\Ai\Ai;
use App\Support\Ai\Alerts;
use App\Support\Ai\PhotoCheck;
use App\Support\Maps\Geocoder;
use Illuminate\Console\Command;

/** Every 15 minutes: alerts, and photo checks that could not run right away. */
class AiWork extends Command
{
    protected $signature = 'ai:work {--photos=150 : most photos to check in one run}';

    protected $description = 'AI helpers: look for alerts and check photos waiting for the AI';

    public function handle(): int
    {
        if (Ai::enabled('aging')) {
            // count Box aging for the office now, so the menu badge and the page open fast
            BoxAging::rows(null, null, true);
        }

        $alerts = Alerts::run();
        $this->info("Alerts raised or refreshed: {$alerts}");

        if (Ai::enabled('photo_check')) {
            $n = 0;
            AiPhotoCheck::whereNull('checked_at')->where('created_at', '>=', now()->subDays(7))
                ->oldest('id')->limit((int) $this->option('photos'))->get()
                ->each(function (AiPhotoCheck $c) use (&$n) {
                    PhotoCheck::run($c);
                    $n++;
                });
            $this->info("Photos checked: {$n}");
        }

        // Missing barangay: queue boxes without one, then fill them in (same receiver, map, driver GPS, AI)
        if (\App\Support\Maps\Barangays::ready() && \App\Support\Maps\Barangays::on('early')) {
            \App\Support\Maps\Barangays::scan();
            $b = \App\Support\Maps\Barangays::work(80, 30);
            if ($b['done']) {
                $this->info("Barangays filled in or sent to check: {$b['done']} (AI read {$b['ai']})");
            }
        }

        // Maps & routes: addresses still waiting to be found on the map
        $found = Geocoder::work(60);
        if ($found) {
            $this->info("Addresses looked up on the map: {$found}");
        }

        return self::SUCCESS;
    }
}
DISPATCH_FILE_END_0

# ---------------------------------------------------------------- app/Filament/Company/Pages/AddressesToCheck.php
mkdir -p 'app/Filament/Company/Pages'
cat > 'app/Filament/Company/Pages/AddressesToCheck.php' <<'DISPATCH_FILE_END_1'
<?php

namespace App\Filament\Company\Pages;

use App\Filament\Shared\Addresses\AddressesToCheckPage;

class AddressesToCheck extends AddressesToCheckPage {}
DISPATCH_FILE_END_1

# ---------------------------------------------------------------- app/Filament/Pages/AddressAi.php
mkdir -p 'app/Filament/Pages'
cat > 'app/Filament/Pages/AddressAi.php' <<'DISPATCH_FILE_END_2'
<?php

namespace App\Filament\Pages;

use App\Filament\Shared\Addresses\AddressAiPage;

class AddressAi extends AddressAiPage {}
DISPATCH_FILE_END_2

# ---------------------------------------------------------------- app/Filament/Pages/AddressesToCheck.php
mkdir -p 'app/Filament/Pages'
cat > 'app/Filament/Pages/AddressesToCheck.php' <<'DISPATCH_FILE_END_3'
<?php

namespace App\Filament\Pages;

use App\Filament\Shared\Addresses\AddressesToCheckPage;

class AddressesToCheck extends AddressesToCheckPage {}
DISPATCH_FILE_END_3

# ---------------------------------------------------------------- app/Filament/Shared/Addresses/AddressAiPage.php
mkdir -p 'app/Filament/Shared/Addresses'
cat > 'app/Filament/Shared/Addresses/AddressAiPage.php' <<'DISPATCH_FILE_END_4'
<?php

namespace App\Filament\Shared\Addresses;

use App\Models\Ai\AiSetting;
use App\Models\AppSetting;
use App\Models\Maps\BarangayFill;
use App\Support\Ai\Ai;
use App\Support\Maps\Barangays;
use App\Support\Maps\MapSettings;
use Filament\Pages\Page;
use Illuminate\Contracts\Support\Htmlable;
use Illuminate\Support\Facades\Auth;
use Illuminate\Support\Str;
use Livewire\Attributes\Url;

/** Settings → AI → AI address cleaning: what it does, the order it tries, try an address. */
class AddressAiPage extends Page
{
    protected string $view = 'filament.addresses.ai';

    protected static ?string $slug = 'ai-address-cleaning';

    protected static string|\BackedEnum|null $navigationIcon = 'heroicon-o-sparkles';

    protected static ?string $title = 'AI address cleaning';

    #[Url]
    public string $tab = 'settings';

    public string $tryAddress = '';

    public string $tryCity = '';

    public ?array $result = null;

    public static function canAccess(): bool
    {
        return (bool) Auth::user()?->hasRole('super_admin') && Barangays::ready();
    }

    public function getHeading(): string|Htmlable
    {
        return '';
    }

    public function setTab(string $t): void
    {
        $this->tab = in_array($t, ['settings', 'try', 'compare'], true) ? $t : 'settings';
    }

    public function toggleOn(): void
    {
        $s = AiSetting::current();
        $f = collect($s->features ?? []);
        $s->features = ($f->contains('addresses') ? $f->reject(fn ($x) => $x === 'addresses') : $f->push('addresses'))->values()->all();
        $s->save();
    }

    public function flip(string $option): void
    {
        if (array_key_exists($option, Barangays::OPTIONS)) {
            AppSetting::put('addr.'.$option, Barangays::on($option) ? '0' : '1');
        }
    }

    public function setLevel(int $l): void
    {
        if (array_key_exists($l, Barangays::LEVELS)) {
            AppSetting::put('addr.level', (string) $l);
            $this->result = $this->result ? $this->restatus($this->result) : null;
        }
    }

    public function sample(int $n): void
    {
        $s = $this->samples()[$n] ?? null;
        if ($s) {
            [$this->tryAddress, $this->tryCity] = [$s['address'], $s['city']];
            $this->result = null;
        }
    }

    public function runTry(): void
    {
        $this->validate(['tryAddress' => 'required|string|max:300', 'tryCity' => 'required|string|max:120'], [], ['tryAddress' => 'address', 'tryCity' => 'city']);
        [$city, $province] = array_pad(array_map('trim', explode(',', $this->tryCity, 2)), 2, '');
        $r = Barangays::tryOne($this->tryAddress, $city, $province);
        $this->result = ['raw' => $this->tryAddress.' · '.$this->tryCity] + $r;
    }

    protected function restatus(array $r): array
    {
        $r['status'] = match (true) {
            ! ($r['barangay'] ?? null) => 'none',
            ($r['source'] ?? null) !== 'ai' || ($r['confidence'] ?? 0) >= Barangays::level() => 'used',
            Barangays::on('check') => 'check',
            default => 'none',
        };

        return $r;
    }

    /** Recent real addresses with no barangay, else examples. */
    public function samples(): array
    {
        $real = BarangayFill::with('invoice')->whereIn('status', ['check', 'none', 'used'])->latest('id')->limit(30)->get()
            ->filter(fn ($f) => $f->invoice && filled($f->invoice->receiver_address))
            ->unique(fn ($f) => Str::lower($f->invoice->receiver_address))->take(4)
            ->map(fn ($f) => ['address' => Str::squish($f->invoice->receiver_address), 'city' => Str::squish(Str::title($f->invoice->receiver_city).', '.Str::title($f->invoice->receiver_province), ', ')])->values()->all();

        return $real ?: [
            ['address' => 'Blk 5 Lot 12 Villa Arcadia Subd., near SM Marilao', 'city' => 'Marilao, Bulacan'],
            ['address' => 'Purok 3, Brgy SJ', 'city' => 'Meycauayan, Bulacan'],
            ['address' => 'purok 3 near chapel, Lapu2', 'city' => 'Lapu-Lapu City, Cebu'],
            ['address' => '221 MacArthur Hwy, tapat Petron', 'city' => 'Marilao, Bulacan'],
        ];
    }

    protected function getViewData(): array
    {
        $s = AiSetting::current();
        $m = Barangays::month();

        return [
            'on' => $s->isOn('addresses'), 'hasKey' => $s->hasKey(), 'model' => Ai::model('fast'),
            'options' => collect(Barangays::OPTIONS)->map(fn ($o, $k) => ['icon' => $o[1], 'title' => $o[2], 'sub' => $o[3], 'new' => $o[4], 'on' => Barangays::on($k)]),
            'levels' => Barangays::LEVELS, 'level' => Barangays::level(),
            'mapName' => MapSettings::provider() === 'none' ? 'no map key yet' : MapSettings::providerName(),
            'month' => $m, 'limit' => (float) $s->monthly_limit,
            'samples' => $this->samples(),
        ];
    }
}
DISPATCH_FILE_END_4

# ---------------------------------------------------------------- app/Filament/Shared/Addresses/AddressesToCheckPage.php
mkdir -p 'app/Filament/Shared/Addresses'
cat > 'app/Filament/Shared/Addresses/AddressesToCheckPage.php' <<'DISPATCH_FILE_END_5'
<?php

namespace App\Filament\Shared\Addresses;

use App\Models\Container;
use App\Models\Invoice;
use App\Models\Maps\BarangayFill;
use App\Models\Maps\GeoPlace;
use App\Support\Maps\Barangays;
use App\Support\Maps\TripSorter;
use App\Support\Tracking\Tracker;
use Filament\Facades\Filament;
use Filament\Notifications\Notification;
use Filament\Pages\Page;
use Illuminate\Contracts\Support\Htmlable;
use Illuminate\Database\Eloquent\Builder;
use Illuminate\Support\Facades\Auth;
use Illuminate\Support\Facades\Cache;
use Illuminate\Support\Str;
use Livewire\Attributes\Url;

/** Boxes with no barangay: what the system filled in, and the unsure ones the office checks. */
class AddressesToCheckPage extends Page
{
    protected string $view = 'filament.addresses.check';

    protected static ?string $slug = 'addresses-to-check';

    protected static string|\BackedEnum|null $navigationIcon = 'heroicon-o-map-pin';

    protected static ?string $title = 'Addresses to check';

    #[Url]
    public string $show = 'check';

    #[Url]
    public ?int $container = null;

    #[Url(as: 'box')]
    public ?int $boxId = null;

    public int $limit = 40;

    public string $chosen = '';

    public string $search = '';

    public bool $alsoSame = true;

    public static function canAccess(): bool
    {
        return Barangays::ready() && Tracker::hubFor(Auth::user(), Filament::getCurrentPanel()?->getId()) !== false;
    }

    public static function getNavigationBadge(): ?string
    {
        $panel = Filament::getCurrentPanel()?->getId();
        $user = Auth::user();
        if (! $user || ! Barangays::ready()) {
            return null;
        }
        $n = Cache::remember("menu:{$panel}:{$user->id}:addresses", 60, fn () => Barangays::scope(BarangayFill::query(), $user, $panel)->where('status', 'check')->count());

        return $n ? (string) $n : null;
    }

    public function getHeading(): string|Htmlable
    {
        return '';
    }

    protected function base(): Builder
    {
        return Barangays::scope(BarangayFill::query(), Auth::user(), Filament::getCurrentPanel()?->getId())
            ->when($this->container, fn ($q) => $q->where('container_id', $this->container));
    }

    public function mount(): void
    {
        Barangays::scan(1000);
        if ($this->boxId) {
            $this->openBox($this->boxId);
        }
    }

    public function setShow(string $s): void
    {
        $this->show = in_array($s, ['check', 'sure', 'none', 'all'], true) ? $s : 'check';
        $this->limit = 40;
    }

    public function fillNow(): void
    {
        $ids = (clone $this->base())->where('status', 'pending')->limit(40)->pluck('id');
        $r = Barangays::work(0, 20, BarangayFill::with('invoice')->whereIn('id', $ids)->get());
        Notification::make()->title($r['done'].' '.Str::plural('box', $r['done']).' done'.($r['ai'] ? ' · the AI read '.$r['ai'] : ''))->success()->send();
        $this->forgetBadge();
    }

    protected function fillRow(int $id): ?BarangayFill
    {
        return (clone $this->base())->with('invoice')->find($id);
    }

    /** ✓ OK: the AI's barangay is right. */
    public function ok(int $id): void
    {
        $f = $this->fillRow($id);
        if ($f && $f->barangay) {
            Barangays::confirm($f, $f->barangay, Auth::user(), true);
            $this->forgetBadge();
        }
    }

    public function openBox(int $id): void
    {
        $f = $this->fillRow($id);
        if (! $f) {
            $this->boxId = null;

            return;
        }
        $this->boxId = $id;
        $this->chosen = $f->barangay ?? (($f->candidates[0]['name'] ?? '') ?: '');
        $this->search = '';
    }

    public function closeBox(): void
    {
        $this->boxId = null;
    }

    public function pick(string $name): void
    {
        $this->chosen = $name;
        $this->search = '';
    }

    public function useChosen(): void
    {
        $f = $this->boxId ? $this->fillRow($this->boxId) : null;
        $name = trim($this->search) !== '' ? Str::title(Str::squish($this->search)) : $this->chosen;
        if (! $f || $name === '') {
            return;
        }
        $known = Barangays::known($f->invoice?->receiver_city);
        $name = Barangays::match($name, $known) ?? $name;
        $n = Barangays::confirm($f, $name, Auth::user(), $this->alsoSame);
        Notification::make()->title($name.' saved'.($n > 1 ? ' for '.$n.' boxes' : '').' · remembered for next time')->success()->send();
        $this->boxId = null;
        $this->forgetBadge();
    }

    protected function forgetBadge(): void
    {
        Cache::forget('menu:'.Filament::getCurrentPanel()?->getId().':'.Auth::id().':addresses');
    }

    /** "52190 · 1 of 3" */
    public static function boxLabel(Invoice $i): string
    {
        $set = $i->set_key ? Invoice::where('container_id', $i->container_id)->where('set_key', $i->set_key)->orderBy('id')->pluck('id') : collect([$i->id]);

        return $i->invoice.($set->count() > 1 ? ' · '.($set->search($i->id) + 1).' of '.$set->count() : '');
    }

    protected function getViewData(): array
    {
        $counts = (clone $this->base())->selectRaw('status, source, count(*) as n')->groupBy('status', 'source')->get();
        $by = fn ($st) => (int) $counts->whereIn('status', (array) $st)->sum('n');
        $src = fn ($s) => (int) $counts->whereIn('status', ['used', 'checked'])->where('source', $s)->sum('n');
        $q = (clone $this->base())->with('invoice');
        $q = match ($this->show) {
            'check' => $q->where('status', 'check'),
            'sure' => $q->whereIn('status', ['used', 'checked']),
            'none' => $q->where('status', 'none'),
            default => $q->where('status', '!=', 'pending'),
        };
        $rows = $q->orderByRaw("case status when 'check' then 0 when 'none' then 2 else 1 end")->orderBy('id')->limit($this->limit + 1)->get();
        $box = $this->boxId ? $this->fillRow($this->boxId) : null;
        $boxData = null;
        if ($box && $box->invoice) {
            $i = $box->invoice;
            $place = GeoPlace::where('key', GeoPlace::keyFor(Str::limit(Str::squish(TripSorter::address($i)), 590, '')))->first();
            $others = BarangayFill::where('id', '!=', $box->id)->whereHas('invoice', fn ($x) => $x->where('is_delivered', false)->where('set_key', $i->set_key))->count();
            $cands = collect($box->candidates ?? []);
            if ($box->barangay && ! $cands->contains('name', $box->barangay)) {
                $cands->prepend(['name' => $box->barangay, 'pct' => $box->confidence, 'why' => $box->clue]);
            }
            $boxData = [
                'f' => $box, 'i' => $i, 'label' => static::boxLabel($i),
                'marked' => static::marked((string) $i->receiver_address, $box->clues ?? []),
                'cands' => $cands->take(3)->values(), 'known' => Barangays::known($i->receiver_city),
                'place' => $place?->hasPin() ? $place : null, 'others' => $others,
                'first' => Str::title(Str::before(Str::squish((string) $i->receiver_name), ' ') ?: 'this receiver'),
            ];
        }

        return [
            'tiles' => [
                ['Boxes with no barangay', $by(['used', 'checked', 'check', 'none', 'pending']), $by('pending') ? $by('pending').' still waiting to be filled in' : 'in this list', false],
                ['Filled in, sure', $by(['used', 'checked']), 'same receiver '.$src('same').' · map '.$src('map').' · driver '.$src('driver').($src('office') + $src('ai') ? ' · other '.($src('office') + $src('ai')) : ''), false],
                ['AI not sure', $by('check'), 'one click each', true],
                ['No clues', $by('none'), 'stay in the city group', false],
            ],
            'chips' => ['check' => ['To check', $by('check')], 'sure' => ['Filled in', $by(['used', 'checked'])], 'none' => ['No clues', $by('none')], 'all' => ['All', $by(['used', 'checked', 'check', 'none'])]],
            'pending' => $by('pending'),
            'rows' => $rows->take($this->limit), 'more' => $rows->count() > $this->limit,
            'containers' => Container::whereIn('id', (clone $this->base())->distinct()->pluck('container_id')->filter())->latest('id')->limit(30)->get(),
            'box' => $boxData,
            'level' => Barangays::level(),
        ];
    }

    /** The address with the AI's clue words marked: [[text, kind|null], ...] */
    public static function marked(string $address, array $clues): array
    {
        $parts = [[$address, null]];
        foreach ($clues as $c) {
            $t = (string) ($c['text'] ?? '');
            if ($t === '') {
                continue;
            }
            $next = [];
            foreach ($parts as [$text, $kind]) {
                $pos = $kind === null ? stripos($text, $t) : false;
                if ($pos === false) {
                    $next[] = [$text, $kind];

                    continue;
                }
                $next[] = [substr($text, 0, $pos), null];
                $next[] = [substr($text, $pos, strlen($t)), (string) ($c['kind'] ?? 'clue')];
                $next[] = [substr($text, $pos + strlen($t)), null];
            }
            $parts = $next;
        }

        return array_values(array_filter($parts, fn ($p) => $p[0] !== ''));
    }
}
DISPATCH_FILE_END_5

# ---------------------------------------------------------------- app/Filament/Warehouse/Pages/AddressesToCheck.php
mkdir -p 'app/Filament/Warehouse/Pages'
cat > 'app/Filament/Warehouse/Pages/AddressesToCheck.php' <<'DISPATCH_FILE_END_6'
<?php

namespace App\Filament\Warehouse\Pages;

use App\Filament\Shared\Addresses\AddressesToCheckPage;

class AddressesToCheck extends AddressesToCheckPage {}
DISPATCH_FILE_END_6

# ---------------------------------------------------------------- app/Models/Invoice.php
mkdir -p 'app/Models'
cat > 'app/Models/Invoice.php' <<'DISPATCH_FILE_END_7'
<?php

namespace App\Models;

use Illuminate\Database\Eloquent\Casts\Attribute;
use Illuminate\Database\Eloquent\Model;
use Illuminate\Database\Eloquent\Relations\HasMany;
use Illuminate\Database\Eloquent\Relations\HasOne;

class Invoice extends Model
{
    protected function casts(): array
    {
        return [
            'is_verified' => 'boolean',
            'is_delivered' => 'boolean',
            'is_assigned' => 'boolean',
            'is_returned' => 'boolean',
            'is_priority' => 'boolean',
            'is_resolved' => 'boolean',
            'wh_is_assigned' => 'boolean',
            'sectioned_at' => 'datetime',
        ];
    }

    protected static function booted(): void
    {
        // the customer's set: all boxes for the same receiver, phone and city
        static::saving(function (Invoice $invoice): void {
            if (! $invoice->set_key || $invoice->isDirty(['receiver_name', 'receiver_mobile_no', 'receiver_city'])) {
                $invoice->set_key = \App\Support\Boxes\BoxSets::keyFor($invoice->receiver_name, $invoice->receiver_mobile_no, $invoice->receiver_city);
            }
        });
        // no barangay on the manifest: queue it so the system fills it in (Addresses to check)
        static::created(fn (Invoice $invoice) => \App\Support\Maps\Barangays::queue($invoice));
    }

    public function barangayFill()
    {
        return $this->hasOne(\App\Models\Maps\BarangayFill::class);
    }

    public function whSection()
    {
        return $this->belongsTo(\App\Models\Boxes\WhSection::class, 'wh_section_id');
    }

    public function verifiedBy()
    {
        return $this->belongsTo(User::class, 'verified_by');
    }

    public function container()
    {
        return $this->belongsTo(Container::class);
    }

    public function warehouse()
    {
        return $this->belongsTo(Warehouse::class);
    }

    public function user()
    {
        return $this->belongsTo(User::class);
    }

    public function routearea()
    {
        return $this->belongsTo(Routearea::class);
    }

    protected function FullAddress(): Attribute
    {
        return new Attribute(
            get: fn () => $this->receiver_address.' '.$this->receiver_province.' '.$this->receiver_city.' '.$this->receiver_barangay
        );
    }

    public function consolidator()
    {
        return $this->belongsTo(
            Consolidator::class,
            'location_code', // FK on invoices
            'code'           // UNIQUE key on consolidators
        );

    }

    public function tripInvoices()
    {
        return $this->hasMany(Tripinvoice::class);
    }

    public function deliverylogs()
    {
        return $this->hasManyThrough(Deliverylog::class, Tripinvoice::class);
    }

    public function invoiceissue()
    {
        return $this->hasMany(Invoiceissue::class);
    }

    public function whtripinvoice()
    {
        return $this->hasOne(Whtripinvoice::class, 'invoice_id', 'id');
    }

    public function deliveryAttempts(): HasMany
    {
        return $this->hasMany(DeliveryAttempt::class)->latest('id');
    }

    public function latestDeliveryAttempt(): HasOne
    {
        return $this->hasOne(DeliveryAttempt::class)->latestOfMany();
    }
}
DISPATCH_FILE_END_7

# ---------------------------------------------------------------- app/Models/Maps/BarangayFill.php
mkdir -p 'app/Models/Maps'
cat > 'app/Models/Maps/BarangayFill.php' <<'DISPATCH_FILE_END_8'
<?php

namespace App\Models\Maps;

use App\Models\Invoice;
use Illuminate\Database\Eloquent\Model;

/** A barangay the system filled in for a box whose manifest had none. */
class BarangayFill extends Model
{
    protected $guarded = [];

    protected function casts(): array
    {
        return ['clues' => 'array', 'candidates' => 'array', 'checked_at' => 'datetime', 'confidence' => 'integer'];
    }

    public function invoice()
    {
        return $this->belongsTo(Invoice::class);
    }

    public function isUsed(): bool
    {
        return in_array($this->status, ['used', 'checked'], true) && filled($this->barangay);
    }
}
DISPATCH_FILE_END_8

# ---------------------------------------------------------------- app/Models/Maps/ReceiverPlace.php
mkdir -p 'app/Models/Maps'
cat > 'app/Models/Maps/ReceiverPlace.php' <<'DISPATCH_FILE_END_9'
<?php

namespace App\Models\Maps;

use Illuminate\Database\Eloquent\Model;

/** What we know about a receiver's place: their barangay, and where the driver delivered. */
class ReceiverPlace extends Model
{
    protected $guarded = [];

    protected function casts(): array
    {
        return ['lat' => 'float', 'lng' => 'float', 'confirmed_at' => 'datetime'];
    }
}
DISPATCH_FILE_END_9

# ---------------------------------------------------------------- app/Services/TripAssignment.php
mkdir -p 'app/Services'
cat > 'app/Services/TripAssignment.php' <<'DISPATCH_FILE_END_10'
<?php

namespace App\Services;

use App\Enums\FailedDeliveryReason;
use App\Enums\UndoDeliveryReason;
use App\Models\DeliveryAttempt;
use App\Models\Deliverylog;
use App\Models\DeliveryReversal;
use App\Models\Invoice;
use App\Models\Tripinvoice;
use App\Models\Truck;
use App\Models\User;
use App\Models\Whdeliverylog;
use App\Models\Whtripinvoice;
use App\Support\Ai\PhotoCheck;
use DomainException;
use Filament\Notifications\Notification;
use Illuminate\Support\Facades\Auth;
use Illuminate\Support\Facades\DB;

/**
 * All trip bookkeeping in one place: putting invoices on a trip, taking them
 * off, scanning them onto the truck and marking them delivered.
 *
 * Every write runs in a transaction so the trip row and the invoice flags
 * (is_assigned, wh_is_assigned, hub_assigned …) can never get out of sync.
 */
class TripAssignment
{
    /**
     * Put invoices on a delivery trip (hub → destination hub).
     *
     * @param  iterable<Invoice>  $invoices
     * @return int how many were added (invoices already on a trip are skipped)
     */
    public function addToDeliveryTrip(Deliverylog $trip, iterable $invoices): int
    {
        $this->ensureEditable($trip);

        return DB::transaction(function () use ($trip, $invoices): int {
            $added = 0;

            foreach ($invoices as $invoice) {
                $alreadyOnTrip = Tripinvoice::where('invoice_id', $invoice->id)->whereHas('deliverylog')->lockForUpdate()->exists();

                if ($alreadyOnTrip) {
                    continue;
                }

                // Leftover rows from a deleted trip would hide the box; drop them.
                Tripinvoice::where('invoice_id', $invoice->id)->whereDoesntHave('deliverylog')->delete();

                Tripinvoice::create([
                    'deliverylog_id' => $trip->id,
                    'logistichub_id' => $trip->assigned_to,
                    'invoice' => $invoice->invoice,
                    'invoice_id' => $invoice->id,
                ]);

                $invoice->update(['is_assigned' => true]);
                $added++;
            }

            return $added;
        });
    }

    /**
     * Put invoices on a warehouse trip.
     *
     * @param  iterable<Invoice>  $invoices
     */
    public function addToWarehouseTrip(Whdeliverylog $trip, iterable $invoices): int
    {
        $this->ensureEditable($trip);

        return DB::transaction(function () use ($trip, $invoices): int {
            $added = 0;

            foreach ($invoices as $invoice) {
                // Skip boxes already on a warehouse trip that has not been unloaded yet.
                $onTheMove = Whtripinvoice::where('invoice_id', $invoice->id)
                    ->whereHas('whdeliverylog')
                    ->where('is_unloaded', false)
                    ->lockForUpdate()
                    ->exists();

                if ($onTheMove) {
                    continue;
                }

                Whtripinvoice::where('invoice_id', $invoice->id)->whereDoesntHave('whdeliverylog')->delete();

                Whtripinvoice::create([
                    'whdeliverylog_id' => $trip->id,
                    'user_id' => Auth::id(),
                    'truck_id' => $trip->truck_id,
                    'warehouse_id' => Auth::user()?->warehouse_id ?? $trip->user_whid,
                    'invoice_id' => $invoice->id,
                ]);

                $invoice->update(['wh_is_assigned' => true]);
                $added++;
            }

            return $added;
        });
    }

    /**
     * A partner hub hands invoices it received over to one of its own trips.
     *
     * @param  iterable<Tripinvoice>  $tripinvoices
     */
    public function addToHubTrip(Deliverylog $hubTrip, iterable $tripinvoices): int
    {
        $this->ensureEditable($hubTrip);

        return DB::transaction(function () use ($hubTrip, $tripinvoices): int {
            $added = 0;

            foreach ($tripinvoices as $tripinvoice) {
                if ($tripinvoice->hub_assigned) {
                    continue;
                }

                $tripinvoice->update([
                    'hub_assigned' => true,
                    'deliveryloghub_id' => $hubTrip->id,
                ]);
                $added++;
            }

            return $added;
        });
    }

    /**
     * Take an invoice off its delivery trip. When $returned is true the box
     * is flagged as returned so it shows up for re-delivery.
     */
    public function removeFromDeliveryTrip(Tripinvoice $tripinvoice, bool $returned = false): void
    {
        if ($tripinvoice->deliverylog) {
            $this->ensureEditable($tripinvoice->deliverylog);
        }

        DB::transaction(function () use ($tripinvoice, $returned): void {
            $changes = ['is_assigned' => false];

            if ($returned) {
                $changes['is_returned'] = true;
            }

            Invoice::whereKey($tripinvoice->invoice_id)->update($changes);
            $tripinvoice->delete();
        });
    }

    /** Release an invoice from a partner hub's trip (it stays on the original trip). */
    public function removeFromHubTrip(Tripinvoice $tripinvoice): void
    {
        $tripinvoice->update([
            'hub_assigned' => false,
            'deliveryloghub_id' => null,
            'is_loaded_hub' => false,
        ]);
    }

    /**
     * Record that a box was scanned onto the truck.
     * Once every box on the trip is loaded, the truck and trip are marked as on the road.
     */
    public function markLoaded(Tripinvoice $tripinvoice, bool $atHub = false): void
    {
        DB::transaction(function () use ($tripinvoice, $atHub): void {
            $tripinvoice->update([$atHub ? 'is_loaded_hub' : 'is_loaded' => true]);

            $tripId = $atHub ? $tripinvoice->deliveryloghub_id : $tripinvoice->deliverylog_id;

            if ($trip = Deliverylog::find($tripId)) {
                $this->refreshLoadStatus($trip, $atHub);
            }
        });
    }

    public function refreshLoadStatus(Deliverylog $trip, bool $atHub = false): void
    {
        $tripColumn = $atHub ? 'deliveryloghub_id' : 'deliverylog_id';
        $loadedColumn = $atHub ? 'is_loaded_hub' : 'is_loaded';

        $invoices = Tripinvoice::where($tripColumn, $trip->id);
        $total = (clone $invoices)->count();
        $loaded = (clone $invoices)->where($loadedColumn, true)->count();

        if ($total > 0 && $total === $loaded) {
            $trip->truck?->update(['is_assigned' => true]);
            $trip->update(['is_current' => true]);
        }
    }

    /**
     * Driver hands the box to the receiver.
     *
     * @param  array<int, string>  $pictures  stored photo paths
     */
    public function markDelivered(Tripinvoice $tripinvoice, array $pictures, ?User $by = null): void
    {
        DB::transaction(function () use ($tripinvoice, $pictures, $by): void {
            $alreadyDelivered = (bool) $tripinvoice->is_delivered;

            $tripinvoice->update([
                'delivery_picture' => array_values($pictures),
                'is_delivered' => true,
                // Updating the photos later must not restart the undo window.
                'delivered_at' => $alreadyDelivered ? $tripinvoice->delivered_at : now(),
                'delivered_by' => $alreadyDelivered ? $tripinvoice->delivered_by : ($by ?? Auth::user())?->getKey(),
            ]);

            Invoice::whereKey($tripinvoice->invoice_id)->update(['is_delivered' => true]);
        });

        if ($pictures) {
            PhotoCheck::queueDelivery($tripinvoice, $pictures);
        }
        // the driver's phone was at this receiver: their barangay and place are known for next time
        \App\Support\Maps\Barangays::learnFromDelivery($tripinvoice->fresh());
    }

    /** How long a driver can undo their own delivery. After that only the office can. */
    public const DRIVER_UNDO_MINUTES = 30;

    /** Minutes this driver has left to undo the delivery (null when they can't). */
    public function driverUndoMinutesLeft(Tripinvoice $tripinvoice, User $driver): ?int
    {
        if (! $tripinvoice->is_delivered || ! $tripinvoice->delivered_at || (int) $tripinvoice->delivered_by !== (int) $driver->getKey()) {
            return null;
        }

        $secondsLeft = self::DRIVER_UNDO_MINUTES * 60 - $tripinvoice->delivered_at->diffInSeconds(now());

        return $secondsLeft > 0 ? (int) ceil($secondsLeft / 60) : null;
    }

    /**
     * Put a delivered box back on the driver's list. Drivers can only undo their own
     * deliveries within DRIVER_UNDO_MINUTES; the office can undo any time.
     * The photos and the reason are kept in the box's history.
     */
    public function undoDelivery(
        Tripinvoice $tripinvoice,
        User $by,
        UndoDeliveryReason $reason,
        ?string $note = null,
        bool $byOffice = false,
    ): DeliveryReversal {
        if (! $tripinvoice->is_delivered) {
            throw new DomainException("{$tripinvoice->invoice} is not marked as delivered.");
        }

        if (! $byOffice && $this->driverUndoMinutesLeft($tripinvoice, $by) === null) {
            throw new DomainException('It is too late to undo this delivery. Ask the office to change it.');
        }

        if ($reason->requiresNote() && blank($note)) {
            throw new DomainException('Please add a note for this reason.');
        }

        $reversal = DB::transaction(function () use ($tripinvoice, $by, $reason, $note, $byOffice): DeliveryReversal {
            $reversal = DeliveryReversal::create([
                'tripinvoice_id' => $tripinvoice->id,
                'invoice_id' => $tripinvoice->invoice_id,
                'deliverylog_id' => $tripinvoice->deliveryloghub_id ?: $tripinvoice->deliverylog_id,
                'user_id' => $by->getKey(),
                'delivered_by' => $tripinvoice->delivered_by,
                'delivered_at' => $tripinvoice->delivered_at ?? $tripinvoice->updated_at,
                'reason' => $reason,
                'note' => filled($note) ? trim($note) : null,
                'photos' => $tripinvoice->delivery_picture ?: null,
                'by_office' => $byOffice,
            ]);

            $tripinvoice->update([
                'is_delivered' => false,
                'delivered_at' => null,
                'delivered_by' => null,
                'delivery_picture' => null,
            ]);

            Invoice::whereKey($tripinvoice->invoice_id)->update(['is_delivered' => false]);

            return $reversal;
        });

        $this->notifyAboutUndo($reversal, $tripinvoice);

        return $reversal;
    }

    /** Office undid it → tell the driver. Driver undid it → tell the dispatcher. */
    protected function notifyAboutUndo(DeliveryReversal $reversal, Tripinvoice $tripinvoice): void
    {
        $recipient = $reversal->by_office
            ? User::find($reversal->delivered_by)
            : $reversal->deliverylog?->user;

        if (! $recipient || $recipient->is($reversal->user)) {
            return;
        }

        Notification::make()
            ->title("Delivery of {$tripinvoice->invoice} was undone")
            ->body(collect([
                $reversal->reason->getLabel(),
                ($reversal->by_office ? 'By the office: ' : 'By the driver: ').$reversal->user->full_name,
                $reversal->note,
            ])->filter()->join("\n"))
            ->icon('heroicon-o-arrow-uturn-left')
            ->warning()
            ->sendToDatabase($recipient);
    }

    /**
     * Driver could not hand the box over. The box stays on the truck; the
     * attempt is kept as history and the dispatcher who made the trip is told.
     *
     * @param  array<int, string>  $photos  stored photo paths
     */
    public function recordFailedAttempt(
        Tripinvoice $tripinvoice,
        User $driver,
        FailedDeliveryReason $reason,
        ?string $note = null,
        array $photos = [],
    ): DeliveryAttempt {
        if ($tripinvoice->is_delivered) {
            throw new DomainException("{$tripinvoice->invoice} is already delivered.");
        }

        if ($reason->requiresNote() && blank($note)) {
            throw new DomainException('Please add a note for this reason.');
        }

        if ($reason->requiresPhoto() && $photos === []) {
            throw new DomainException('Please add a photo for this reason.');
        }

        $attempt = DB::transaction(fn () => DeliveryAttempt::create([
            'tripinvoice_id' => $tripinvoice->id,
            'invoice_id' => $tripinvoice->invoice_id,
            'deliverylog_id' => $tripinvoice->deliveryloghub_id ?: $tripinvoice->deliverylog_id,
            'user_id' => $driver->id,
            'reason' => $reason,
            'note' => filled($note) ? trim($note) : null,
            'photos' => array_values($photos) ?: null,
        ]));

        $this->notifyDispatcher($attempt);

        return $attempt;
    }

    protected function notifyDispatcher(DeliveryAttempt $attempt): void
    {
        $dispatcher = $attempt->deliverylog?->user;

        if (! $dispatcher || $dispatcher->is($attempt->user)) {
            return;
        }

        $count = DeliveryAttempt::where('invoice_id', $attempt->invoice_id)->count();

        Notification::make()
            ->title("{$attempt->tripinvoice->invoice} not delivered")
            ->body(collect([
                $attempt->reason->getLabel().($count > 1 ? " (attempt {$count})" : ''),
                'Trip '.$attempt->deliverylog?->trip_number.' · '.$attempt->user->full_name,
                $attempt->note,
            ])->filter()->join("\n"))
            ->icon($attempt->reason->getIcon())
            ->warning()
            ->sendToDatabase($dispatcher);
    }

    /**
     * An undelivered box came back on the truck: take it off the trip and put it
     * back in the pool of boxes waiting for a trip, flagged as returned.
     * The driver's reasons and photos stay in the delivery attempts history.
     */
    public function returnToInventory(Tripinvoice $tripinvoice): void
    {
        if ($tripinvoice->is_delivered) {
            throw new DomainException("{$tripinvoice->invoice} was delivered — it can't be returned.");
        }

        DB::transaction(function () use ($tripinvoice): void {
            Invoice::whereKey($tripinvoice->invoice_id)->update([
                'is_assigned' => false,
                'is_returned' => true,
            ]);

            $tripinvoice->delete();
        });
    }

    /**
     * Partner hub version: the box leaves the hub's own trip and goes back to the
     * hub's list of boxes waiting for a trip (it stays assigned to the hub).
     */
    public function returnToHubInventory(Tripinvoice $tripinvoice): void
    {
        if ($tripinvoice->is_delivered) {
            throw new DomainException("{$tripinvoice->invoice} was delivered — it can't be returned.");
        }

        DB::transaction(function () use ($tripinvoice): void {
            $this->removeFromHubTrip($tripinvoice);
            Invoice::whereKey($tripinvoice->invoice_id)->update(['is_returned' => true]);
        });
    }

    /** Free the truck and close the trip. */
    public function releaseTruck(Deliverylog $trip): void
    {
        DB::transaction(function () use ($trip): void {
            $trip->truck?->update(['is_assigned' => false]);
            $trip->update(['is_current' => false, 'is_active' => false]);
        });
    }

    /**
     * Swap the truck on a trip: the old truck becomes available again,
     * the new one is marked as in use. Does nothing when the truck did not change.
     */
    public function swapTruck(?int $oldTruckId, ?int $newTruckId): void
    {
        if ($oldTruckId === $newTruckId) {
            return;
        }

        DB::transaction(function () use ($oldTruckId, $newTruckId): void {
            if ($oldTruckId) {
                Truck::whereKey($oldTruckId)->update(['is_assigned' => false]);
            }

            if ($newTruckId) {
                Truck::whereKey($newTruckId)->update(['is_assigned' => true]);
            }
        });
    }

    public function ensureEditable(Deliverylog|Whdeliverylog $trip): void
    {
        if ($trip->is_lock) {
            throw new DomainException("Trip {$trip->trip_number} is locked. Ask an administrator to unlock it first.");
        }
    }
}
DISPATCH_FILE_END_10

# ---------------------------------------------------------------- app/Support/Ai/AiFeatures.php
mkdir -p 'app/Support/Ai'
cat > 'app/Support/Ai/AiFeatures.php' <<'DISPATCH_FILE_END_11'
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
        'addresses' => ['AI address cleaning', 'Fixes messy addresses ("purok 3 near chapel, Lapu2" → "Purok 3, Pusok, Lapu-Lapu City, Cebu") so the map finds more stops, and fills in a missing barangay from clues in the address. Unsure ones go to Addresses to check.', 'Admin · Warehouse · Partner hub', true],
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
DISPATCH_FILE_END_11

# ---------------------------------------------------------------- app/Support/Ai/TripPlanner.php
mkdir -p 'app/Support/Ai'
cat > 'app/Support/Ai/TripPlanner.php' <<'DISPATCH_FILE_END_12'
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
                'barangay' => $clean(\App\Support\Maps\Barangays::of($first)) ?: 'No barangay',
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
        // Own trucks first; rental trucks only on days they are booked.
        return \App\Support\Rentals::usable(Truck::where('is_active', true)->where('is_assigned', false)
            ->where('logistichub_id', $this->user->logistichub_id))->get()->sortBy(fn ($t) => [$t->isRental() ? 1 : 0, $t->plate_no])->values()
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
DISPATCH_FILE_END_12

# ---------------------------------------------------------------- app/Support/DriverTrip.php
mkdir -p 'app/Support'
cat > 'app/Support/DriverTrip.php' <<'DISPATCH_FILE_END_13'
<?php

namespace App\Support;

use App\Models\Deliverylog;
use App\Models\Invoiceissue;
use App\Models\Maps\TripStop;
use App\Models\Tripinvoice;
use App\Models\Truckcrew;
use App\Models\User;
use App\Services\TripAssignment;
use App\Support\Maps\TripSorter;
use Illuminate\Database\Eloquent\Builder;
use Illuminate\Support\Collection;
use Illuminate\Support\Facades\Storage;
use Illuminate\Support\Str;

/**
 * Everything the driver's dashboard shows about their current trip.
 * The trip is found the same way as on "My deliveries": the newest active
 * trip of the truck the driver is crew on.
 */
class DriverTrip
{
    public function __construct(
        public readonly User $driver,
        public readonly ?Deliverylog $trip,
    ) {}

    public static function for(User $driver): self
    {
        return new self($driver, static::currentTrip($driver));
    }

    /** The trip the person is on now: on its crew (trip steps), or the newest active trip of their truck. */
    public static function currentTrip(User $driver): ?Deliverylog
    {
        return \App\Support\TripFlow::tripFor($driver);
    }

    /** Every box on the trip, including ones a partner hub handed over to it. */
    public function boxes(): Builder
    {
        $tripId = $this->trip?->getKey() ?? 0;

        return Tripinvoice::query()->where(fn (Builder $query) => $query
            ->where('deliverylog_id', $tripId)
            ->orWhere('deliveryloghub_id', $tripId));
    }

    /** @return array{total: int, delivered: int, notDelivered: int, left: int, percent: int} */
    public function progress(): array
    {
        $total = $this->boxes()->count();
        $delivered = $this->boxes()->where('is_delivered', true)->count();
        $notDelivered = $this->boxes()->where('is_delivered', false)->has('deliveryAttempts')->count();

        return [
            'total' => $total,
            'delivered' => $delivered,
            'notDelivered' => $notDelivered,
            'left' => $total - $delivered,
            'percent' => $total ? (int) floor($delivered / $total * 100) : 0,
        ];
    }

    public function isFinished(): bool
    {
        $progress = $this->progress();

        return $progress['total'] > 0 && $progress['left'] === 0;
    }

    /** The other people on the truck, e.g. "Jun Reyes · Helper". */
    public function crewmates(): Collection
    {
        if (! $this->trip?->truck_id) {
            return collect();
        }

        $crew = \App\Support\TripFlow::crew($this->trip)->pluck('user_id');

        return User::with('workposition')
            ->whereIn('id', $crew->isNotEmpty() ? $crew : Truckcrew::where('truck_id', $this->trip->truck_id)->pluck('crew'))
            ->whereKeyNot($this->driver->getKey())
            ->get()
            ->map(fn (User $user) => [
                'name' => $user->full_name,
                'role' => $user->workposition?->position_description,
            ]);
    }

    /** Undelivered priority boxes, shown first. */
    public function priority(): Collection
    {
        return $this->remaining()
            ->filter(fn (Tripinvoice $box) => $box->invdata?->is_priority)
            ->map(fn (Tripinvoice $box) => $this->stopCard($box))
            ->values();
    }

    /**
     * Remaining boxes grouped by city and barangay, then by receiver, so the
     * driver can finish one area at a time and hand a whole household over at once.
     */
    public function areas(): Collection
    {
        return $this->remaining()
            ->groupBy(fn (Tripinvoice $box) => Str::title((string) $box->invdata?->receiver_city).'|'.Str::title((string) \App\Support\Maps\Barangays::of($box->invdata)))
            ->map(function (Collection $boxes, string $key) {
                [$city, $barangay] = explode('|', $key);

                $stops = $boxes
                    ->groupBy(fn (Tripinvoice $box) => Str::lower(trim($box->invdata?->receiver_name.'|'.$box->invdata?->receiver_address)))
                    ->map(function (Collection $household) {
                        $card = $this->stopCard($household->first());
                        $card['count'] = $household->count();
                        $card['invoices'] = $household->pluck('invoice')->join(', ');

                        return $card;
                    })
                    ->values();

                return [
                    'key' => md5($key),
                    'city' => $city ?: 'No city',
                    'barangay' => $barangay,
                    'boxes' => $boxes->count(),
                    'stops' => $stops,
                ];
            })
            ->sortByDesc('boxes')
            ->values();
    }

    /**
     * Stops still to visit, in the order the office sorted them (Maps & routes).
     * Each has what Navigate needs: the pin, or the address when there is no pin.
     */
    public function stops(): Collection
    {
        if (! $this->trip || ! TripSorter::ensure($this->trip, 10)) {
            return collect();
        }
        $left = $this->remaining()->keyBy('id');

        return TripSorter::stops($this->trip)
            ->map(function (TripStop $s) use ($left) {
                $boxes = collect($s->box_ids)->map(fn ($id) => $left[$id] ?? null)->filter()->values();
                if ($boxes->isEmpty()) {
                    return null;
                }
                $first = $boxes->first();
                $phone = $first->invdata?->receiver_mobile_no;

                return [
                    'id' => $s->id, 'no' => $s->stop_no, 'name' => $s->name, 'address' => $s->address,
                    'place' => trim(($s->barangay ? $s->barangay.', ' : '').$s->city, ', '),
                    'count' => $boxes->count(), 'invoice' => $first->invoice, 'invoices' => $boxes->pluck('invoice')->join(', '),
                    'priority' => $s->priority, 'zone' => $s->zone,
                    'lat' => $s->lat, 'lng' => $s->lng, 'exact' => $s->exact,
                    'go' => $s->hasPin() ? $s->lat.','.$s->lng : $s->address.', Philippines',
                    'phone' => $phone, 'tel' => $phone ? 'tel:'.preg_replace('/[^0-9+]/', '', $phone) : null,
                ];
            })
            ->filter()
            ->values();
    }

    /** Undelivered boxes with a problem reported at unloading. */
    public function problems(): Collection
    {
        $remaining = $this->remaining()->keyBy('invoice_id');

        if ($remaining->isEmpty()) {
            return collect();
        }

        return Invoiceissue::with('boxissue')
            ->whereIn('invoice_id', $remaining->keys())
            ->latest('id')
            ->get()
            ->unique('invoice_id')
            ->map(fn (Invoiceissue $issue) => $this->stopCard($remaining[$issue->invoice_id]) + [
                'issue' => $issue->boxissue?->issue_type ?? 'Problem reported',
                'remarks' => Str::limit(strip_tags((string) $issue->remarks), 80),
            ])
            ->values();
    }

    /** The latest boxes delivered today, with their proof photo. */
    public function deliveredToday(int $limit = 5): Collection
    {
        return $this->boxes()
            ->with('invdata')
            ->where('is_delivered', true)
            ->where(fn (Builder $query) => $query
                ->whereDate('delivered_at', today())
                ->orWhere(fn (Builder $query) => $query->whereNull('delivered_at')->whereDate('updated_at', today())))
            ->orderByRaw('COALESCE(delivered_at, updated_at) DESC')
            ->limit($limit)
            ->get()
            ->map(fn (Tripinvoice $box) => $this->stopCard($box) + [
                'id' => $box->getKey(),
                'undoMinutesLeft' => app(TripAssignment::class)->driverUndoMinutesLeft($box, $this->driver),
                'time' => ($box->delivered_at ?? $box->updated_at)?->format('g:i A'),
                'photo' => ($photo = collect($box->delivery_picture)->first())
                    ? Storage::disk('public')->url($photo)
                    : null,
            ]);
    }

    protected function remaining(): Collection
    {
        return once(fn () => $this->boxes()
            ->with('invdata')
            ->where('is_delivered', false)
            ->orderBy('invoice')
            ->get());
    }

    /** @return array{invoice: string, name: string, address: string, phone: ?string, tel: ?string, count: int} */
    protected function stopCard(Tripinvoice $box): array
    {
        $invoice = $box->invdata;
        $phone = $invoice?->receiver_mobile_no;

        return [
            'invoice' => $box->invoice,
            'name' => Str::title((string) $invoice?->receiver_name),
            'address' => collect([$invoice?->receiver_address, \App\Support\Maps\Barangays::of($invoice), $invoice?->receiver_city])
                ->filter()->map(fn ($part) => Str::title($part))->join(', '),
            'phone' => $phone,
            'tel' => $phone ? 'tel:'.preg_replace('/[^0-9+]/', '', $phone) : null,
            'count' => 1,
        ];
    }
}
DISPATCH_FILE_END_13

# ---------------------------------------------------------------- app/Support/Maps/Barangays.php
mkdir -p 'app/Support/Maps'
cat > 'app/Support/Maps/Barangays.php' <<'DISPATCH_FILE_END_14'
<?php

namespace App\Support\Maps;

use App\Models\AppSetting;
use App\Models\Invoice;
use App\Models\Maps\BarangayFill;
use App\Models\Maps\ReceiverPlace;
use App\Models\Tripinvoice;
use App\Models\User;
use App\Support\Ai\Ai;
use Illuminate\Database\Eloquent\Builder;
use Illuminate\Support\Carbon;
use Illuminate\Support\Collection;
use Illuminate\Support\Facades\Cache;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Schema;
use Illuminate\Support\Str;
use Throwable;

/**
 * Missing barangay: filled in from (1) the same receiver before, (2) the map, (3) driver GPS,
 * (4) the AI reading the address. The manifest address itself is never changed.
 */
class Barangays
{
    /** Settings → AI → AI address cleaning: key => [default, icon, title, what it does, new]. */
    public const OPTIONS = [
        'clean' => [true, '🧹', 'Clean messy addresses for the map', 'What it does today: “Lapu2” → Lapu-Lapu City, “Brgy” → Barangay', false],
        'fill' => [true, '📍', 'Fill in a missing barangay', 'Picks only from the real barangays of that city, never a made-up name', true],
        'landmarks' => [true, '🏬', 'Use landmarks and subdivisions as clues', '“near SM Marilao”, “Villa Arcadia Subd.” help find the barangay (kept for the driver too)', true],
        'early' => [true, '⏱', 'Run right after the manifest is read', 'So the barangay is ready before the AI trip helper plans (before: only when the trip is mapped)', true],
        'remember' => [true, '🧠', 'Remember it for the receiver', 'Same phone or name and street next time: no AI needed, no cost', true],
        'check' => [true, '✅', 'Send unsure ones to Addresses to check', 'The office clicks ✓ OK or Change; everything else is used by itself', true],
    ];

    public const LEVELS = [90 => 'Very sure (90%)', 75 => 'Sure (75%)', 60 => 'Fairly sure (60%)'];

    public const SOURCES = ['same' => 'Same receiver', 'map' => 'Map', 'driver' => 'Driver GPS', 'ai' => 'AI guess', 'office' => 'Checked by the office'];

    public static function ready(): bool
    {
        return Schema::hasTable('barangay_fills');
    }

    public static function on(string $option): bool
    {
        return (bool) AppSetting::get('addr.'.$option, self::OPTIONS[$option][0] ?? false);
    }

    public static function level(): int
    {
        $l = (int) AppSetting::get('addr.level', 75);

        return array_key_exists($l, self::LEVELS) ? $l : 75;
    }

    /** The barangay to use for a box: the manifest's, else the one filled in (sure or checked). */
    public static function of(?Invoice $i): ?string
    {
        if (! $i) {
            return null;
        }
        $own = Str::squish((string) $i->receiver_barangay);
        if ($own !== '' && ! static::blankish($own)) {
            return $own;
        }
        if (! static::ready()) {
            return null;
        }
        $fill = $i->relationLoaded('barangayFill') ? $i->barangayFill : $i->barangayFill()->first();

        return $fill?->isUsed() ? $fill->barangay : null;
    }

    /** Small note for a trip stop: where the barangay came from, or that there is none. */
    public static function note(?Invoice $i): ?string
    {
        if (! $i || (Str::squish((string) $i->receiver_barangay) !== '' && ! static::blankish($i->receiver_barangay))) {
            return null;
        }
        $fill = static::ready() ? ($i->relationLoaded('barangayFill') ? $i->barangayFill : $i->barangayFill()->first()) : null;

        return match (true) {
            $fill?->status === 'checked' => 'checked',
            $fill?->status === 'used' => $fill->source === 'ai' ? 'AI' : (self::SOURCES[$fill->source] ?? 'filled'),
            $fill?->status === 'check' => 'AI guess, not checked',
            default => 'no barangay',
        };
    }

    /** "N/A", "-", "none" count as no barangay. */
    public static function blankish(?string $v): bool
    {
        return in_array(Str::lower(trim((string) $v, " .-")), ['', 'na', 'n/a', 'none', 'null', '0', 'x'], true);
    }

    public static function cityKey(?string $city): string
    {
        $c = Str::lower(Str::squish(preg_replace('/[^\pL\pN ]+/u', ' ', (string) $city)));
        $c = preg_replace('/^(city of|municipality of) /', '', $c);

        return trim(preg_replace('/ city$/', '', $c));
    }

    /** "Brgy. Sto. Niño" and "santo nino" compare the same. */
    public static function nameKey(?string $b): string
    {
        $b = Str::lower(Str::ascii(Str::squish((string) $b)));
        $b = preg_replace('/\b(brgy|bgy|barangay|brg)\b\.?/', '', $b);
        $b = preg_replace(['/\bsto\b\.?/', '/\bsta\b\.?/', '/\bpob\b\.?/', '/\bsn\b\.?/'], ['santo', 'santa', 'poblacion', 'san'], $b);

        return trim(preg_replace('/[^a-z0-9]+/', ' ', $b));
    }

    /** @return list<string> keys for the same receiver: phone, and name + street */
    public static function receiverKeys(Invoice $i): array
    {
        $keys = [];
        $phone = substr(preg_replace('/\D+/', '', (string) $i->receiver_mobile_no), -10);
        if (strlen($phone) >= 9) {
            $keys[] = 'p'.$phone;
        }
        $name = Str::lower(Str::squish($i->receiver_name.'|'.$i->receiver_address));
        if (strlen($name) > 3) {
            $keys[] = 'n'.md5($name.'|'.static::cityKey($i->receiver_city));
        }

        return $keys;
    }

    /** Real barangays of a city: the ones in your own manifests and the ones already checked. */
    public static function known(?string $city): array
    {
        $ck = static::cityKey($city);
        if ($ck === '') {
            return [];
        }

        return Cache::remember('brgy.known.'.md5($ck), 600, function () use ($ck) {
            $core = Str::before($ck, ' ') ?: $ck;
            $names = DB::table('invoices')->where('receiver_city', 'like', '%'.$core.'%')->where('receiver_barangay', '!=', '')
                ->select('receiver_city', 'receiver_barangay')->distinct()->limit(4000)->get()
                ->filter(fn ($r) => static::cityKey($r->receiver_city) === $ck)->pluck('receiver_barangay');
            if (Schema::hasTable('receiver_places')) {
                $names = $names->merge(ReceiverPlace::where('city_key', $ck)->whereNotNull('barangay')->pluck('barangay'));
            }

            return $names->map(fn ($n) => Str::title(Str::squish($n)))->reject(fn ($n) => static::blankish($n))
                ->unique(fn ($n) => static::nameKey($n))->sort()->values()->take(400)->all();
        });
    }

    /** The known barangay this name means, or null. */
    public static function match(?string $name, array $known): ?string
    {
        $k = static::nameKey($name);
        if ($k === '') {
            return null;
        }
        $best = null;
        $score = 0;
        foreach ($known as $b) {
            $bk = static::nameKey($b);
            if ($bk === $k) {
                return $b;
            }
            similar_text($bk, $k, $pct);
            if ($pct > $score) {
                [$best, $score] = [$b, $pct];
            }
        }

        return $score >= 88 ? $best : null;
    }

    /** A new box with no barangay: queue it (no map or AI call here). */
    public static function queue(Invoice $i): void
    {
        try {
            if (! static::ready() || ! static::on('fill') || ! static::blankish($i->receiver_barangay)) {
                return;
            }
            BarangayFill::firstOrCreate(['invoice_id' => $i->id], ['container_id' => $i->container_id, 'status' => 'pending']);
        } catch (Throwable $e) {
            report($e);
        }
    }

    /** Boxes not delivered yet with no barangay and no row: queue them. */
    public static function scan(int $limit = 3000): int
    {
        if (! static::ready() || ! static::on('fill')) {
            return 0;
        }
        $rows = DB::table('invoices as i')->leftJoin('barangay_fills as f', 'f.invoice_id', '=', 'i.id')
            ->whereNull('f.id')->where('i.is_delivered', false)
            ->where(fn ($q) => $q->whereNull('i.receiver_barangay')->orWhereIn(DB::raw('lower(trim(i.receiver_barangay))'), ['', 'na', 'n/a', 'none', '-', 'null']))
            ->limit($limit)->get(['i.id', 'i.container_id']);
        $now = now();
        foreach ($rows->chunk(500) as $chunk) {
            BarangayFill::insertOrIgnore($chunk->map(fn ($r) => ['invoice_id' => $r->id, 'container_id' => $r->container_id, 'status' => 'pending', 'created_at' => $now, 'updated_at' => $now])->all());
        }

        return $rows->count();
    }

    /** Fill in the waiting ones. $maps = most map lookups, AI is asked in batches. */
    public static function work(int $limit = 60, int $maps = 30, ?Collection $only = null): array
    {
        if (! static::ready() || ! static::on('fill')) {
            return ['done' => 0, 'ai' => 0];
        }
        $fills = $only ?? BarangayFill::with('invoice')->where('status', 'pending')->where('tries', '<', 3)->oldest('id')->limit($limit)->get();
        $askAi = [];
        $done = 0;
        foreach ($fills as $f) {
            if (! $f->invoice || ! static::blankish($f->invoice->receiver_barangay)) {
                $f->delete();

                continue;
            }
            $f->tries++;
            $r = static::cheap($f->invoice, $maps);
            if ($r) {
                static::apply($f, $r);
                $done++;
            } else {
                $askAi[] = $f;
            }
        }
        $ai = 0;
        if ($askAi) {
            $results = static::canAskAi() ? static::askAi(collect($askAi)->map->invoice->all()) : [];
            foreach ($askAi as $n => $f) {
                $r = $results[$n] ?? null;
                static::apply($f, $r ?? ['barangay' => null, 'source' => null, 'confidence' => 0, 'clue' => static::canAskAi() ? 'The AI found no barangay clue' : 'Only the city is written', 'clues' => [], 'candidates' => []]);
                $ai += $r ? 1 : 0;
                $done++;
            }
        }

        return ['done' => $done, 'ai' => $ai];
    }

    public static function canAskAi(): bool
    {
        return Ai::enabled('addresses') && ! Ai::overLimit();
    }

    /**
     * Steps 1–3, no AI: same receiver before, the map, driver GPS nearby.
     *
     * @return array{barangay: string, source: string, confidence: int, clue: string, clues: array, candidates: array, lat?: float, lng?: float}|null
     */
    public static function cheap(Invoice $i, int &$maps = 0): ?array
    {
        $ck = static::cityKey($i->receiver_city);
        $known = static::known($i->receiver_city);

        // 1 · same receiver before
        if (static::on('remember')) {
            $keys = static::receiverKeys($i);
            $p = $keys ? ReceiverPlace::whereIn('key', $keys)->where('city_key', $ck)->whereNotNull('barangay')->latest('updated_at')->first() : null;
            if ($p) {
                return static::hit($p->barangay, 'same', 100, 'Same receiver'.($p->confirmed_at ? ', '.$p->confirmed_at->format('M j') : ''));
            }
        }
        $phone = substr(preg_replace('/\D+/', '', (string) $i->receiver_mobile_no), -10);
        if (strlen($phone) >= 9) {
            $before = Invoice::where('id', '!=', $i->id)->where('receiver_mobile_no', 'like', '%'.substr($phone, -4))->where('receiver_barangay', '!=', '')
                ->latest('id')->limit(200)->get(['id', 'receiver_mobile_no', 'receiver_city', 'receiver_barangay', 'created_at'])
                ->first(fn ($o) => substr(preg_replace('/\D+/', '', (string) $o->receiver_mobile_no), -10) === $phone
                    && static::cityKey($o->receiver_city) === $ck && ! static::blankish($o->receiver_barangay));
            if ($before) {
                return static::hit(Str::title(Str::squish($before->receiver_barangay)), 'same', 100, 'Same receiver, '.Carbon::parse($before->created_at)->format('M j').' box');
            }
        }

        // 2 · the map (the address is looked up once and saved; the trip map uses the same lookup)
        $place = null;
        if (MapSettings::provider() !== 'none' && $maps > 0) {
            $maps--;
            try {
                $place = Geocoder::find(TripSorter::address($i));
            } catch (Throwable $e) {
                report($e);
            }
            if ($place && filled($place->barangay ?? null)) {
                $name = static::match($place->barangay, $known) ?? Str::title($place->barangay);

                return static::hit($name, 'map', 95, 'Map found the address', $place->lat, $place->lng);
            }
        }

        // 3 · driver GPS: a receiver delivered next to this pin
        if ($place?->hasPin()) {
            $near = ReceiverPlace::where('city_key', $ck)->whereNotNull('barangay')->whereNotNull('lat')
                ->whereBetween('lat', [$place->lat - 0.004, $place->lat + 0.004])->whereBetween('lng', [$place->lng - 0.004, $place->lng + 0.004])
                ->get()->map(fn ($p) => [$p, static::meters($place->lat, $place->lng, $p->lat, $p->lng)])
                ->filter(fn ($x) => $x[1] <= 300)->sortBy(fn ($x) => $x[1])->first();
            if ($near) {
                return static::hit($near[0]->barangay, 'driver', 90, 'Driver GPS'.($near[0]->confirmed_at ? ', '.$near[0]->confirmed_at->format('M j') : '').' · '.round($near[1]).' m away', $place->lat, $place->lng);
            }
        }

        return null;
    }

    protected static function hit(string $b, string $source, int $conf, string $why, ?float $lat = null, ?float $lng = null): array
    {
        return ['barangay' => $b, 'source' => $source, 'confidence' => $conf, 'clue' => $why, 'clues' => [], 'candidates' => [['name' => $b, 'pct' => $conf, 'why' => $why]], 'lat' => $lat, 'lng' => $lng];
    }

    /**
     * Step 4: the AI reads the addresses (address and city only, never the name or phone).
     *
     * @param  list<Invoice>  $invoices
     * @return array<int, array> results by the same index
     */
    public static function askAi(array $invoices): array
    {
        $out = [];
        foreach (array_chunk($invoices, 15, true) as $chunk) {
            $items = [];
            foreach ($chunk as $n => $i) {
                $address = static::on('landmarks') ? $i->receiver_address : static::withoutNotes($i->receiver_address);
                $items[] = ['i' => $n, 'address' => Str::limit(Str::squish((string) $address), 300, ''), 'city' => Str::squish($i->receiver_city.', '.$i->receiver_province, ', '), 'barangays' => static::known($i->receiver_city)];
            }
            try {
                $res = Ai::json('addresses',
                    'You find the barangay of Philippine delivery addresses whose barangay is missing. For each item, use the clues in the address '
                    .'(subdivision, street, purok, landmark like a mall or school, short forms like "Brgy SJ" or "Pob.") and pick the barangay from that item\'s "barangays" list. '
                    .'Never answer a name that is not in the list; if the list is empty, answer only a barangay that is written in the address. If there is no real clue, answer null. '
                    .'Give how sure you are (0-100), one short reason, the exact words from the address you used, and up to 3 candidates. '
                    .'Answer as {"items":[{"i":0,"barangay":"..." or null,"confidence":0,"why":"...","clues":[{"text":"words from the address","kind":"subdivision|landmark|street|short form"}],"candidates":[{"name":"...","pct":0,"why":"..."}]}]}',
                    json_encode($items, JSON_UNESCAPED_UNICODE), 'fast', 2500);
            } catch (Throwable $e) {
                report($e);

                continue;
            }
            foreach ($res['items'] ?? [] as $row) {
                $n = $row['i'] ?? null;
                if (! array_key_exists($n, $chunk)) {
                    continue;
                }
                $known = static::known($chunk[$n]->receiver_city);
                $pick = fn ($name) => $known ? static::match($name, $known) : (filled($name) && str_contains(static::nameKey($chunk[$n]->receiver_address), static::nameKey($name)) ? Str::title($name) : null);
                $b = $pick($row['barangay'] ?? null);
                $cands = collect($row['candidates'] ?? [])->map(fn ($c) => ['name' => $pick($c['name'] ?? null), 'pct' => max(0, min(100, (int) ($c['pct'] ?? 0))), 'why' => Str::limit((string) ($c['why'] ?? ''), 120)])
                    ->filter(fn ($c) => $c['name'])->unique('name')->take(3)->values()->all();
                $out[$n] = [
                    'barangay' => $b, 'source' => 'ai', 'confidence' => $b ? max(0, min(100, (int) ($row['confidence'] ?? 0))) : 0,
                    'clue' => Str::limit((string) ($row['why'] ?? ''), 280), 'candidates' => $cands,
                    'clues' => collect($row['clues'] ?? [])->map(fn ($c) => ['text' => Str::limit((string) ($c['text'] ?? ''), 80, ''), 'kind' => Str::limit((string) ($c['kind'] ?? 'clue'), 20, '')])
                        ->filter(fn ($c) => $c['text'] !== '' && Str::contains(Str::lower($chunk[$n]->receiver_address), Str::lower($c['text'])))->take(4)->values()->all(),
                ];
            }
        }

        return $out;
    }

    protected static function withoutNotes(?string $a): string
    {
        return trim(preg_replace('/\b(near|beside|in front of|across|tapat( ng)?|malapit sa|likod ng)\b[^,]*/i', '', (string) $a), ' ,');
    }

    /** Save a result: sure ones are used, unsure ones go to Addresses to check. */
    public static function apply(BarangayFill $f, array $r): void
    {
        $b = $r['barangay'] ?? null;
        $conf = (int) ($r['confidence'] ?? 0);
        $status = match (true) {
            ! $b => 'none',
            ($r['source'] ?? null) !== 'ai' || $conf >= static::level() => 'used',
            static::on('check') => 'check',
            default => 'none',
        };
        $f->fill(['barangay' => $b, 'source' => $r['source'] ?? null, 'confidence' => $conf, 'clue' => $r['clue'] ?? null,
            'clues' => $r['clues'] ?? [], 'candidates' => $r['candidates'] ?? [], 'status' => $status])->save();
        if ($status === 'used' && ($r['source'] ?? null) !== 'same') {
            static::remember($f->invoice, $b, $r['source'], $r['lat'] ?? null, $r['lng'] ?? null, false);
        }
    }

    /** The office picks the barangay (✓ OK or Change). Also for the receiver's other boxes when asked. */
    public static function confirm(BarangayFill $f, string $barangay, ?User $by = null, bool $sameReceiver = true): int
    {
        $n = 0;
        $fills = collect([$f]);
        if ($sameReceiver && $f->invoice) {
            $keys = TripPlannerKey::of($f->invoice);
            $fills = $fills->merge(BarangayFill::with('invoice')->where('id', '!=', $f->id)->whereIn('status', ['pending', 'check', 'none', 'used'])
                ->whereHas('invoice', fn ($q) => $q->where('is_delivered', false)->where('set_key', $f->invoice->set_key))->get()
                ->filter(fn ($o) => $o->invoice && TripPlannerKey::of($o->invoice) === $keys));
        }
        foreach ($fills as $x) {
            $x->fill(['barangay' => $barangay, 'status' => 'checked', 'source' => $x->id === $f->id && $x->barangay === $barangay ? $x->source : 'office',
                'checked_by' => $by?->id, 'checked_at' => now()])->save();
            $n++;
        }
        if ($f->invoice) {
            static::remember($f->invoice, $barangay, 'office', null, null, true);
        }

        return $n;
    }

    public static function remember(?Invoice $i, ?string $barangay, ?string $source, ?float $lat = null, ?float $lng = null, bool $confirmed = false): void
    {
        if (! $i || ! static::on('remember') || ! Schema::hasTable('receiver_places')) {
            return;
        }
        foreach (static::receiverKeys($i) as $key) {
            $p = ReceiverPlace::firstOrNew(['key' => $key]);
            $p->city_key = static::cityKey($i->receiver_city);
            if ($barangay) {
                $p->barangay = $barangay;
                $p->source = $source;
            }
            if ($lat !== null && $lng !== null) {
                [$p->lat, $p->lng] = [$lat, $lng];
            }
            if ($confirmed) {
                $p->confirmed_at = now();
            }
            $p->save();
        }
        Cache::forget('brgy.known.'.md5(static::cityKey($i->receiver_city)));
    }

    /** Delivered: the driver's phone was here, so this receiver's place is known for next time. */
    public static function learnFromDelivery(Tripinvoice $t): void
    {
        try {
            if (! static::ready() || ! Schema::hasTable('truck_positions') || ! $t->delivered_at) {
                return;
            }
            $i = $t->invdata;
            $pos = DB::table('truck_positions')->where('deliverylog_id', $t->deliverylog_id)
                ->whereBetween('recorded_at', [$t->delivered_at->copy()->subMinutes(10), $t->delivered_at->copy()->addMinutes(10)])->get()
                ->sortBy(fn ($p) => abs(Carbon::parse($p->recorded_at)->diffInSeconds($t->delivered_at)))->first();
            if ($i && $pos) {
                static::remember($i, static::of($i), 'driver', (float) $pos->lat, (float) $pos->lng, true);
            }
        } catch (Throwable $e) {
            report($e);
        }
    }

    public static function meters(float $aLat, float $aLng, float $bLat, float $bLng): float
    {
        $r = 6371000;
        $dLat = deg2rad($bLat - $aLat);
        $dLng = deg2rad($bLng - $aLng);
        $h = sin($dLat / 2) ** 2 + cos(deg2rad($aLat)) * cos(deg2rad($bLat)) * sin($dLng / 2) ** 2;

        return 2 * $r * asin(min(1, sqrt($h)));
    }

    /** Boxes this panel may see (admin: all; warehouse: its own; partner hub: boxes coming to it). */
    public static function scope(Builder $q, ?User $user, ?string $panel): Builder
    {
        $q->whereHas('invoice', fn ($i) => $i->where('is_delivered', false));
        if (! $user || $panel === 'admin') {
            return $q;
        }
        if ($panel === 'warehouse') {
            return $q->whereHas('invoice', fn ($i) => $i->where('warehouse_id', $user->warehouse_id));
        }
        $hub = (int) $user->logistichub_id;

        return $q->whereHas('invoice', fn ($i) => $i->whereExists(fn ($e) => $e->from('tripinvoices as h')->whereColumn('h.invoice_id', 'invoices.id')->where('h.logistichub_id', $hub)));
    }

    /** Try an address without saving a box (Settings → AI → Try it). */
    public static function tryOne(string $address, string $city, string $province = ''): array
    {
        $i = new Invoice(['receiver_address' => $address, 'receiver_city' => $city, 'receiver_province' => $province, 'receiver_barangay' => '', 'receiver_name' => '', 'receiver_mobile_no' => '']);
        $i->id = 0;
        $clean = null;
        if (static::on('clean') && Ai::enabled('addresses')) {
            $place = Geocoder::place(TripSorter::address($i));
            if (! $place->clean) {
                AddressCleaner::clean(collect([$place]));
            }
            $clean = $place->clean;
        }
        $maps = 1;
        $r = static::cheap($i, $maps) ?? (static::canAskAi() ? (static::askAi([$i])[0] ?? null) : null);
        $r ??= ['barangay' => null, 'source' => null, 'confidence' => 0, 'clue' => static::canAskAi() ? 'No barangay clue' : 'The AI is off', 'clues' => [], 'candidates' => []];
        $r['clean'] = $clean ?? TripSorter::address($i);
        $r['status'] = match (true) {
            ! $r['barangay'] => 'none',
            $r['source'] !== 'ai' || $r['confidence'] >= static::level() => 'used',
            static::on('check') => 'check',
            default => 'none',
        };

        return $r;
    }

    /** This month on the settings page. */
    public static function month(): array
    {
        $from = today()->startOfMonth();
        $fills = static::ready() ? BarangayFill::where('updated_at', '>=', $from) : null;

        return [
            'cleaned' => Schema::hasTable('geo_places') ? DB::table('geo_places')->whereNotNull('clean')->where('updated_at', '>=', $from)->count() : 0,
            'filled' => $fills ? (clone $fills)->whereIn('status', ['used', 'checked'])->count() : 0,
            'check' => $fills ? (clone $fills)->where('status', 'check')->count() : 0,
            'cost' => Schema::hasTable('ai_usage') ? (float) DB::table('ai_usage')->where('feature', 'addresses')->where('created_at', '>=', $from)->sum('cost') : 0.0,
        ];
    }
}
DISPATCH_FILE_END_14

# ---------------------------------------------------------------- app/Support/Maps/Geocoder.php
mkdir -p 'app/Support/Maps'
cat > 'app/Support/Maps/Geocoder.php' <<'DISPATCH_FILE_END_15'
<?php

namespace App\Support\Maps;

use App\Models\Maps\GeoPlace;
use Illuminate\Support\Collection;
use Illuminate\Support\Facades\Http;
use Illuminate\Support\Str;
use RuntimeException;
use Throwable;

/**
 * Finds addresses on the map. Each address is looked up once and saved in
 * geo_places; later trips read the saved pin and cost nothing.
 */
class Geocoder
{
    /** The saved place for an address (made "pending" the first time). */
    public static function place(string $address): GeoPlace
    {
        $address = Str::limit(Str::squish($address), 590, '');

        return GeoPlace::firstOrCreate(['key' => GeoPlace::keyFor($address)], ['raw' => $address, 'status' => 'pending']);
    }

    /** Look one address up now if it is still pending. */
    public static function find(string $address, int $budget = 1): GeoPlace
    {
        $place = static::place($address);
        static::resolve(collect([$place]), $budget);

        return $place;
    }

    /**
     * Look up the pending places, at most $budget map calls. Messy addresses are
     * cleaned by the AI first when that is switched on.
     *
     * @param  Collection<int, GeoPlace>  $places
     * @return array{looked: int, ai: int}
     */
    public static function resolve(Collection $places, int $budget = 40): array
    {
        $provider = MapSettings::provider();
        $todo = $places->filter(fn (GeoPlace $p) => $p->status === 'pending' && $p->tries < 3)->unique('id')->values();
        if ($provider === 'none' || $todo->isEmpty() || $budget <= 0) {
            return ['looked' => 0, 'ai' => 0];
        }
        $todo = $todo->take($budget);

        $ai = 0;
        if (MapSettings::aiCleaning()) {
            $ai = AddressCleaner::clean($todo->whereNull('clean'));
        }

        $looked = 0;
        foreach ($todo as $place) {
            $place->tries++;
            try {
                $hit = static::lookup($provider, $place->clean ?: $place->raw);
                $looked++;
                if ($hit) {
                    $place->fill(['lat' => $hit['lat'], 'lng' => $hit['lng'], 'exact' => $hit['exact'], 'status' => 'found', 'source' => $provider]);
                    if (! empty($hit['barangay']) && \Illuminate\Support\Facades\Schema::hasColumn('geo_places', 'barangay')) {
                        $place->barangay = Str::limit($hit['barangay'], 118, '');
                    }
                } else {
                    $place->fill(['status' => 'not_found', 'source' => $provider]);
                }
            } catch (Throwable $e) {
                report($e);
            }
            $place->save();
        }

        return ['looked' => $looked, 'ai' => $ai];
    }

    /** @return array{lat: float, lng: float, exact: bool, label: string}|null */
    public static function lookup(string $provider, string $text, ?string $key = null): ?array
    {
        $key ??= MapSettings::key($provider);
        if (! $key) {
            throw new RuntimeException('No key for '.MapSettings::providerName($provider).'.');
        }

        if ($provider === 'google') {
            $r = Http::timeout(8)->get('https://maps.googleapis.com/maps/api/geocode/json', [
                'address' => $text, 'components' => 'country:PH', 'region' => 'ph', 'key' => $key,
            ])->throw()->json();
            $status = $r['status'] ?? '';
            if ($status === 'ZERO_RESULTS') {
                return null;
            }
            if ($status !== 'OK') {
                throw new RuntimeException('Google Maps: '.($r['error_message'] ?? $status));
            }
            $hit = $r['results'][0];

            return [
                'lat' => (float) $hit['geometry']['location']['lat'], 'lng' => (float) $hit['geometry']['location']['lng'],
                'exact' => in_array($hit['geometry']['location_type'] ?? '', ['ROOFTOP', 'RANGE_INTERPOLATED'], true) || ! ($hit['partial_match'] ?? false),
                'label' => (string) ($hit['formatted_address'] ?? $text),
                // the barangay as the map knows it (for Addresses to check)
                'barangay' => collect(['sublocality_level_1', 'administrative_area_level_5', 'neighborhood', 'sublocality'])
                    ->map(fn ($type) => collect($hit['address_components'] ?? [])->first(fn ($c) => in_array($type, $c['types'] ?? [], true))['long_name'] ?? null)
                    ->filter()->first(),
            ];
        }

        if ($provider === 'ors') {
            $r = Http::timeout(8)->get('https://api.heigit.org/pelias/v1/search', [
                'api_key' => $key, 'text' => $text, 'boundary.country' => 'PH', 'size' => 1,
            ])->throw()->json();
            $hit = $r['features'][0] ?? null;
            if (! $hit) {
                return null;
            }
            [$lng, $lat] = $hit['geometry']['coordinates'];

            return [
                'lat' => (float) $lat, 'lng' => (float) $lng,
                'exact' => in_array($hit['properties']['layer'] ?? '', ['address', 'street', 'venue'], true),
                'label' => (string) ($hit['properties']['label'] ?? $text),
                'barangay' => $hit['properties']['neighbourhood'] ?? null,
            ];
        }

        return null;
    }

    /** Pending addresses left over from busy trips (run by ai:work every 15 minutes). */
    public static function work(int $budget = 60): int
    {
        if (MapSettings::provider() === 'none') {
            return 0;
        }

        return static::resolve(GeoPlace::where('status', 'pending')->where('tries', '<', 3)->oldest('id')->limit($budget)->get(), $budget)['looked'];
    }
}
DISPATCH_FILE_END_15

# ---------------------------------------------------------------- app/Support/Maps/MapSettings.php
mkdir -p 'app/Support/Maps'
cat > 'app/Support/Maps/MapSettings.php' <<'DISPATCH_FILE_END_16'
<?php

namespace App\Support\Maps;

use App\Models\AppSetting;
use App\Models\Logistichub;
use App\Models\Warehouse;
use App\Support\Ai\Ai;
use Illuminate\Support\Facades\Crypt;
use Throwable;

/**
 * Admin → Settings → Maps & routes. Keys are saved encrypted. The system uses
 * whatever is there: the chosen map if it has a key, else any map with a key,
 * else no map (barangay order). Nothing here ever blocks a trip.
 */
class MapSettings
{
    public const PROVIDERS = [
        'google' => 'Google Maps',
        'ors' => 'OpenRouteService',
        'none' => 'No map key',
    ];

    public static function chosen(): string
    {
        $p = (string) AppSetting::get('maps.provider', 'google');

        return isset(self::PROVIDERS[$p]) ? $p : 'google';
    }

    public static function key(string $provider): ?string
    {
        $v = AppSetting::get('maps.key.'.$provider);
        if (blank($v)) {
            return null;
        }
        try {
            return Crypt::decryptString($v);
        } catch (Throwable) {
            return null;
        }
    }

    public static function putKey(string $provider, ?string $key): void
    {
        AppSetting::put('maps.key.'.$provider, filled($key) ? Crypt::encryptString(trim($key)) : null);
    }

    public static function masked(string $provider): ?string
    {
        $k = static::key($provider);

        return $k ? substr($k, 0, 4).str_repeat('•', 9).substr($k, -3) : null;
    }

    /** The map really used now: google, ors or none. */
    public static function provider(): string
    {
        $chosen = static::chosen();
        if ($chosen === 'none') {
            return 'none';
        }
        if (static::key($chosen)) {
            return $chosen;
        }
        foreach (['google', 'ors'] as $p) {
            if (static::key($p)) {
                return $p;
            }
        }

        return 'none';
    }

    public static function providerName(?string $p = null): string
    {
        return self::PROVIDERS[$p ?? static::provider()] ?? 'No map key';
    }

    public static function aiCleaning(): bool
    {
        return Ai::enabled('addresses') && (bool) AppSetting::get('addr.clean', true);
    }

    public static function priorityFirst(): bool
    {
        return (bool) AppSetting::get('maps.priority_first', false);
    }

    /** Load truck: stop a box that goes in too early (it can still be loaded with "Load it anyway"). */
    public static function warnEarly(): bool
    {
        return (bool) AppSetting::get('maps.warn_early', true);
    }

    /** [lat, lng] typed or pasted as "10.3157, 123.8854" (Google Maps: right-click → copy). */
    public static function parsePin(?string $text): ?array
    {
        if (! preg_match('/(-?\d{1,2}(?:\.\d+)?)\s*[, ]\s*(-?\d{1,3}(?:\.\d+)?)/', (string) $text, $m)) {
            return null;
        }
        [$lat, $lng] = [(float) $m[1], (float) $m[2]];

        return abs($lat) <= 90 && abs($lng) <= 180 && ($lat != 0.0 || $lng != 0.0) ? [$lat, $lng] : null;
    }

    public static function startPin(string $kind, int $id): ?array
    {
        return static::parsePin(AppSetting::get("maps.start.{$kind}.{$id}"));
    }

    public static function putStartPin(string $kind, int $id, ?string $text): void
    {
        $pin = static::parsePin($text);
        AppSetting::put("maps.start.{$kind}.{$id}", $pin ? $pin[0].','.$pin[1] : null);
    }

    /** Where a route starts: the warehouse of the person who made the trip, else its hub. */
    public static function startFor(?int $warehouseId, ?int $hubId): ?array
    {
        if ($warehouseId && ($pin = static::startPin('wh', $warehouseId))) {
            return $pin + ['name' => Warehouse::whereKey($warehouseId)->value('name') ?? 'Warehouse'];
        }
        if ($hubId && ($pin = static::startPin('hub', $hubId))) {
            return $pin + ['name' => Logistichub::whereKey($hubId)->value('hub_name') ?? 'Hub'];
        }
        if ($warehouseId && ($w = Warehouse::find($warehouseId))) {
            $place = Geocoder::find(trim($w->address.', '.$w->city.', '.$w->province, ', '), 1);
            if ($place?->hasPin()) {
                return [$place->lat, $place->lng, 'name' => $w->name];
            }
        }

        return null;
    }
}
DISPATCH_FILE_END_16

# ---------------------------------------------------------------- app/Support/Maps/TripPlannerKey.php
mkdir -p 'app/Support/Maps'
cat > 'app/Support/Maps/TripPlannerKey.php' <<'DISPATCH_FILE_END_17'
<?php

namespace App\Support\Maps;

use App\Models\Invoice;
use App\Support\Ai\TripPlanner;

/** Same receiver, the way the trip planner counts it. */
class TripPlannerKey
{
    public static function of(Invoice $i): string
    {
        return TripPlanner::receiverKey($i);
    }
}
DISPATCH_FILE_END_17

# ---------------------------------------------------------------- app/Support/Maps/TripSorter.php
mkdir -p 'app/Support/Maps'
cat > 'app/Support/Maps/TripSorter.php' <<'DISPATCH_FILE_END_18'
<?php

namespace App\Support\Maps;

use App\Models\Deliverylog;
use App\Models\Invoice;
use App\Models\Maps\GeoPlace;
use App\Models\Maps\TripRoute;
use App\Models\Maps\TripStop;
use App\Models\Routearea;
use App\Models\Tripinvoice;
use App\Models\User;
use App\Support\Ai\TripPlanner;
use Illuminate\Database\Eloquent\Builder;
use Illuminate\Support\Collection;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Str;

/**
 * Sorts a delivery trip: one stop per receiver (all their boxes together), the
 * stops in driving order, and a truck spot for every stop. The first stop is
 * delivered first, so its boxes go in last, at the door (BACK); the last stops
 * go in first, next to the cab (FRONT).
 */
class TripSorter
{
    public const SOURCES = [
        'google' => 'Sorted by Google Maps',
        'ors' => 'Sorted by OpenRouteService',
        'estimate' => 'Sorted by distance (straight line)',
        'barangay' => 'Sorted by barangay (no map key)',
        'manual' => 'Your own order (locked)',
    ];

    /** Trips that go to another hub carry all boxes to one place: no stops to sort. */
    public static function isTransfer(Deliverylog $trip): bool
    {
        return $trip->assigned_to && (int) $trip->assigned_to !== (int) $trip->logistichub_id
            && ! Tripinvoice::where('deliveryloghub_id', $trip->id)->exists();
    }

    public static function boxes(Deliverylog $trip): Builder
    {
        return Tripinvoice::query()->where(fn (Builder $q) => $q->where('deliverylog_id', $trip->id)->orWhere('deliveryloghub_id', $trip->id));
    }

    public static function canSee(?User $user, Deliverylog $trip): bool
    {
        if (! $user) {
            return false;
        }
        if ($user->hasRole('super_admin')) {
            return true;
        }

        return in_array((int) $user->logistichub_id, [(int) $trip->logistichub_id, (int) $trip->assigned_to], true);
    }

    public static function address(?Invoice $i): string
    {
        return collect([$i?->receiver_address, $i?->receiver_barangay, $i?->receiver_city, $i?->receiver_province])
            ->map(fn ($v) => Str::squish((string) $v))->filter()->unique()->push('Philippines')->join(', ');
    }

    /** Sort again only when boxes were added or removed since the last time. */
    public static function ensure(Deliverylog $trip, int $budget = 15): ?TripRoute
    {
        if (static::isTransfer($trip)) {
            return null;
        }
        $route = TripRoute::where('deliverylog_id', $trip->id)->first();
        if (! $route || $route->boxes_hash !== static::hash($trip) || ($route->waiting > 0 && MapSettings::provider() !== 'none')) {
            $route = static::sort($trip, $budget);
        }

        return $route;
    }

    public static function hash(Deliverylog $trip): string
    {
        return sha1(static::boxes($trip)->orderBy('id')->pluck('id')->join(','));
    }

    public static function sort(Deliverylog $trip, int $budget = 40, bool $unlock = false): ?TripRoute
    {
        if (static::isTransfer($trip)) {
            return null;
        }

        $boxes = static::boxes($trip)->with(Barangays::ready() ? ['invdata.barangayFill'] : ['invdata'])->get()->filter(fn ($b) => $b->invdata);
        // boxes with no barangay that were not filled in yet: try now (same receiver, map, driver GPS, AI)
        if (Barangays::ready() && Barangays::on('fill')) {
            $waiting = $boxes->map(fn ($b) => $b->invdata->barangayFill)->filter(fn ($f) => $f && $f->status === 'pending');
            if ($waiting->isNotEmpty()) {
                $waiting->each(fn ($f) => $f->setRelation('invoice', $boxes->first(fn ($b) => $b->invdata->id === $f->invoice_id)->invdata));
                Barangays::work(0, 10, $waiting->values());
            }
        }
        $route = TripRoute::firstOrNew(['deliverylog_id' => $trip->id]);
        if ($unlock) {
            $route->locked = false;
        }

        // one unit per receiver
        $areas = Routearea::whereIn('id', $boxes->pluck('invdata.routearea_id')->filter()->unique())->pluck('code', 'id');
        $units = $boxes->groupBy(fn ($b) => TripPlanner::receiverKey($b->invdata))->map(function (Collection $g, string $key) use ($areas) {
            $i = $g->first()->invdata;

            return [
                'key' => substr($key, 0, 40), 'inv' => $i, 'ids' => $g->pluck('id')->values()->all(), 'n' => $g->count(),
                'prio' => $g->contains(fn ($b) => $b->invdata->is_priority),
                'sortarea' => Str::lower(($areas[$i->routearea_id] ?? 'zzz').'|'.$i->receiver_province.'|'.$i->receiver_city.'|'.(Barangays::of($i) ?? '~').'|'.$i->receiver_name),
                'brgy' => (string) Barangays::of($i),
                'place' => Geocoder::place(static::address($i)),
            ];
        })->keyBy('key');

        $found = Geocoder::resolve($units->pluck('place'), $budget);

        $old = TripStop::where('deliverylog_id', $trip->id)->orderBy('stop_no')->pluck('receiver_key')->all();
        $source = null;
        $km = null;
        $minutes = null;

        if ($route->locked && $old) {
            $order = array_values(array_merge(array_intersect($old, $units->keys()->all()), array_diff($units->keys()->all(), $old)));
            $source = 'manual';
        } else {
            [$order, $source, $km, $minutes] = static::order($trip, $units);
        }

        $zones = static::zones(array_map(fn ($k) => $units[$k]['n'], $order));

        DB::transaction(function () use ($trip, $units, $order, $zones) {
            TripStop::where('deliverylog_id', $trip->id)->whereNotIn('receiver_key', $order ?: ['-'])->delete();
            foreach ($order as $n => $k) {
                $u = $units[$k];
                $i = $u['inv'];
                $pin = $u['place']->hasPin();
                TripStop::updateOrCreate(['deliverylog_id' => $trip->id, 'receiver_key' => $k], [
                    'stop_no' => $n + 1,
                    'name' => Str::title(Str::squish((string) $i->receiver_name)),
                    'address' => $u['place']->clean ?: collect([$i->receiver_address, $u['brgy'], $i->receiver_city])->filter()->map(fn ($v) => Str::title(Str::squish($v)))->join(', '),
                    'barangay' => Str::title(Str::squish($u['brgy'])),
                    'city' => Str::title(Str::squish((string) $i->receiver_city)),
                    'phone' => Str::limit((string) $i->receiver_mobile_no, 38, ''),
                    'lat' => $pin ? $u['place']->lat : null, 'lng' => $pin ? $u['place']->lng : null,
                    'exact' => $pin && $u['place']->exact,
                    'geo_place_id' => $u['place']->id,
                    'zone' => $zones[$n], 'boxes' => $u['n'], 'priority' => $u['prio'], 'box_ids' => $u['ids'],
                ] + (Barangays::ready() ? ['barangay_note' => Barangays::note($i)] : []));
            }
        });

        $route->fill([
            'source' => $source, 'km' => $km, 'minutes' => $minutes,
            'boxes_hash' => static::hash($trip),
            'waiting' => $units->filter(fn ($u) => $u['place']->status === 'pending' && $u['place']->tries < 3)->count(),
            'ai_fixed' => GeoPlace::whereIn('id', $units->pluck('place.id'))->whereNotNull('clean')->whereColumn('clean', '!=', 'raw')->count(),
            'sorted_at' => now(),
        ])->save();
        unset(static::$zoneMemo[$trip->id]);

        return $route;
    }

    /** @return array{0: list<string>, 1: string, 2: ?float, 3: ?int} */
    protected static function order(Deliverylog $trip, Collection $units): array
    {
        $prioFirst = MapSettings::priorityFirst();
        $pinned = $units->filter(fn ($u) => $u['place']->hasPin());
        $rest = $units->reject(fn ($u) => $u['place']->hasPin())->sortBy(fn ($u) => ($prioFirst && $u['prio'] ? '0' : '1').$u['sortarea']);

        if ($pinned->isEmpty()) {
            return [$rest->keys()->all(), 'barangay', null, null];
        }

        $start = MapSettings::startFor($trip->user?->warehouse_id, $trip->logistichub_id);
        $plan = RoutePlanner::plan($start ? [$start[0], $start[1]] : null,
            $pinned->map(fn ($u) => [$u['place']->lat, $u['place']->lng])->all(),
            $prioFirst ? $pinned->filter(fn ($u) => $u['prio'])->keys()->all() : []);
        $order = $plan['order'];

        // stops without a pin go right after a stop in the same barangay, else the same city, else at the end
        foreach ($rest as $k => $u) {
            $at = null;
            $val = fn ($unit, $field) => Str::lower(Str::squish((string) ($field === 'barangay' ? $unit['brgy'] : $unit['inv']->receiver_city)));
            foreach (['barangay', 'city'] as $field) {
                foreach ($order as $pos => $other) {
                    if ($val($units[$other], 'city') === $val($u, 'city') && ($field === 'city' || ($val($u, 'barangay') !== '' && $val($units[$other], 'barangay') === $val($u, 'barangay')))) {
                        $at = $pos;
                    }
                }
                if ($at !== null) {
                    break;
                }
            }
            if ($at === null) {
                $order[] = $k;
            } else {
                array_splice($order, $at + 1, 0, [$k]);
            }
        }

        return [$order, $plan['source'] === 'estimate' || ! $start ? 'estimate' : $plan['source'], $plan['km'], $plan['minutes']];
    }

    /**
     * Truck spot per stop, by boxes: the first third of the boxes delivered = BACK (door),
     * the middle third = MIDDLE, the last third = FRONT (next to the cab).
     *
     * @param  list<int>  $boxes  boxes per stop in delivery order
     * @return list<string>
     */
    public static function zones(array $boxes): array
    {
        $total = max(1, array_sum($boxes));
        $acc = 0;
        $out = [];
        foreach ($boxes as $n) {
            $mid = ($acc + $n / 2) / $total;
            $acc += $n;
            $out[] = $mid < 1 / 3 ? 'back' : ($mid < 2 / 3 ? 'middle' : 'front');
        }

        return $out;
    }

    /** Staff dragged a stop: keep their order from now on (locked). */
    public static function move(Deliverylog $trip, int $stopId, int $toIndex): void
    {
        $stops = TripStop::where('deliverylog_id', $trip->id)->orderBy('stop_no')->get()->values();
        $from = $stops->search(fn ($s) => $s->id === $stopId);
        if ($from === false) {
            return;
        }
        $list = $stops->all();
        $moving = array_splice($list, $from, 1);
        array_splice($list, max(0, min($toIndex, count($list))), 0, $moving);
        static::saveOrder($trip, collect($list));
    }

    public static function saveOrder(Deliverylog $trip, Collection $stops): void
    {
        $zones = static::zones($stops->pluck('boxes')->map(fn ($n) => (int) $n)->all());
        DB::transaction(function () use ($stops, $zones) {
            foreach ($stops->values() as $n => $s) {
                $s->update(['stop_no' => $n + 1, 'zone' => $zones[$n]]);
            }
        });
        TripRoute::updateOrCreate(['deliverylog_id' => $trip->id], ['locked' => true, 'source' => 'manual', 'km' => null, 'minutes' => null]);
        unset(static::$zoneMemo[$trip->id]);
    }

    public static function stops(Deliverylog $trip): Collection
    {
        return TripStop::where('deliverylog_id', $trip->id)->orderBy('stop_no')->get();
    }

    protected static array $zoneMemo = [];

    /** tripinvoice id => ['zone' => 'front', 'stop' => 3] for one trip. */
    public static function zoneMap(Deliverylog $trip): array
    {
        if (! isset(static::$zoneMemo[$trip->id])) {
            $map = [];
            foreach (TripStop::where('deliverylog_id', $trip->id)->get(['stop_no', 'zone', 'box_ids']) as $s) {
                foreach ($s->box_ids ?? [] as $id) {
                    $map[(int) $id] = ['zone' => $s->zone, 'stop' => $s->stop_no];
                }
            }
            static::$zoneMemo[$trip->id] = $map;
        }

        return static::$zoneMemo[$trip->id];
    }
}
DISPATCH_FILE_END_18

# ---------------------------------------------------------------- app/Support/Navigation/Menu.php
mkdir -p 'app/Support/Navigation'
cat > 'app/Support/Navigation/Menu.php' <<'DISPATCH_FILE_END_19'
<?php

namespace App\Support\Navigation;

use App\Models\Shipping\WrongHubBox;
use App\Support\Shipping\Shipments;
use App\Support\Tracking\Tracker;
use Filament\Navigation\NavigationGroup;
use Illuminate\Support\Facades\Auth;
use Illuminate\Support\Facades\Cache;

/**
 * The side menu of the Admin, Warehouse and Partner hub panels, in one place:
 * the groups (in the order of the work of the day) and, per page, its group, name and place.
 * Pages not listed here keep their own group and name.
 */
class Menu
{
    /** Panel => [group name => folded at first]. */
    public const GROUPS = [
        'admin' => [
            'Boxes' => false, 'Trips & delivery' => false, 'Sea & partner hubs' => false, 'Money' => false,
            'AI helpers' => true, 'Scan on this computer' => false,
            'Settings · company & people' => true, 'Settings · places & routes' => true,
            'Settings · trucks & boxes' => true, 'Settings · messages & AI' => true, 'Help' => false,
        ],
        'warehouse' => [
            'Boxes' => false, 'Trips' => false, 'Sea & returns' => false, 'Scan on this computer' => false,
            'Trucks' => false, 'AI helpers' => true, 'Settings & help' => true,
        ],
        'company' => [
            'Coming in' => false, 'Delivery' => false, 'Returns' => false, 'Scan on this computer' => false,
            'Trucks & people' => false, 'AI helpers' => true, 'Settings & help' => true,
        ],
    ];

    /** Panel => [page or resource class (short, after the panel's namespace) => [group, name or null to keep, sort]]. */
    public const ITEMS = [
        'admin' => [
            'Resources\\ContainerResource' => ['Boxes', null, 1],
            'Resources\\Unmanifesteds\\UnmanifestedResource' => ['Boxes', null, 2],
            'Resources\\Inventories\\InventoryResource' => ['Boxes', 'Inventory', 3],
            'Resources\\Boxsummaries\\BoxsummaryResource' => ['Boxes', 'Box summary', 4],
            'Resources\\Searchinvs\\SearchinvResource' => ['Boxes', 'Find a box', 5],
            'Resources\\Invoiceissues\\InvoiceissueResource' => ['Boxes', 'Box issues', 6],
            'Pages\\BoxPhotos' => ['Boxes', 'Box photos', 7],

            'Resources\\Deliverylogs\\DeliverylogResource' => ['Trips & delivery', 'Delivery trips', 1],
            'Resources\\Deliveryinvs\\DeliveryinvResource' => ['Trips & delivery', 'Delivery invoices', 2],
            'Pages\\AddressesToCheck' => ['Trips & delivery', null, 2],
            'Pages\\CrewBoard' => ['Trips & delivery', null, 3],
            'Pages\\TruckTracking' => ['Trips & delivery', null, 4],
            'Pages\\TruckDay' => ['Trips & delivery', null, 5],

            'Pages\\SeaShipments' => ['Sea & partner hubs', null, 1],
            'Pages\\WrongHub' => ['Sea & partner hubs', null, 2],

            'Pages\\CostPerBox' => ['Money', null, 1],
            'Pages\\Fuel' => ['Money', null, 2],

            'Pages\\Scaninvoice' => ['Scan on this computer', 'Unload container', 1],
            'Pages\\Scanload' => ['Scan on this computer', 'Load truck', 2],
            'Pages\\ReturnBoxes' => ['Scan on this computer', 'Return boxes', 3],

            'Pages\\Companyinfo' => ['Settings · company & people', 'Company info', 1],
            'Pages\\AppIcons' => ['Settings · company & people', null, 2],
            'Pages\\PrintSettings' => ['Settings · company & people', null, 3],
            'Resources\\UserResource' => ['Settings · company & people', null, 4],
            '\\BezhanSalleh\\FilamentShield\\Resources\\Roles\\RoleResource' => ['Settings · company & people', null, 5],
            'Resources\\Workpositions\\WorkpositionResource' => ['Settings · company & people', 'Job positions', 6],
            'Resources\\PanelcategoryResource' => ['Settings · company & people', 'Account types', 7],

            'Resources\\Warehouses\\WarehouseResource' => ['Settings · places & routes', null, 1],
            'Pages\\WarehouseSections' => ['Settings · places & routes', null, 2],
            'Resources\\Logistichubs\\LogistichubResource' => ['Settings · places & routes', 'Logistic hubs', 3],
            'Pages\\HubIslands' => ['Settings · places & routes', null, 4],
            'Resources\\RouteareaResource' => ['Settings · places & routes', 'Route areas', 5],
            'Pages\\MapsRoutes' => ['Settings · places & routes', null, 6],

            'Pages\\Fleet' => ['Settings · trucks & boxes', 'Trucks', 1],
            'Pages\\RentalTrucks' => ['Settings · trucks & boxes', null, 1],
            'Resources\\Truckteams\\TruckteamResource' => ['Settings · trucks & boxes', 'Truck teams', 2],
            'Pages\\TrackingSettings' => ['Settings · trucks & boxes', 'Truck tracking settings', 3],
            'Pages\\FuelSettings' => ['Settings · trucks & boxes', 'Fuel settings', 4],
            'Pages\\BoxSizeSettings' => ['Settings · trucks & boxes', null, 5],
            'Resources\\Boxissues\\BoxissueResource' => ['Settings · trucks & boxes', 'Box issue types', 6],
            'Pages\\BoxPhotoSettings' => ['Settings · trucks & boxes', 'Box photo settings', 7],
            'Pages\\AgingLimits' => ['Settings · trucks & boxes', null, 8],
            'Resources\\ConsolidatorResource' => ['Settings · trucks & boxes', null, 9],
            'Resources\\CompanyResource' => ['Settings · trucks & boxes', 'Agents', 10],

            'Pages\\SmsSettings' => ['Settings · messages & AI', null, 1],
            'Pages\\SmsLog' => ['Settings · messages & AI', null, 2],
            'Pages\\AiSettings' => ['Settings · messages & AI', 'AI settings', 3],
            'Pages\\AddressAi' => ['Settings · messages & AI', null, 4],
            'Resources\\HelpGuides\\HelpGuideResource' => ['Settings · messages & AI', 'Help guides (edit)', 4],

            'Pages\\HelpGuide' => ['Help', null, 1],
        ],
        'warehouse' => [
            'Resources\\Containers\\ContainerResource' => ['Boxes', null, 1],
            'Resources\\Inventories\\InventoryResource' => ['Boxes', 'Inventory', 2],
            'Pages\\Sections' => ['Boxes', null, 3],
            'Resources\\Searchinvs\\SearchinvResource' => ['Boxes', 'Find a box', 4],
            'Resources\\Deliveryinvs\\DeliveryinvResource' => ['Boxes', 'Delivery invoices', 5],
            'Resources\\Invoiceissues\\InvoiceissueResource' => ['Boxes', 'Box issues', 6],
            'Pages\\BoxPhotos' => ['Boxes', 'Box photos', 7],

            'Resources\\Deliverylogs\\DeliverylogResource' => ['Trips', 'Delivery trips', 1],
            'Resources\\Whdeliverylogs\\WhdeliverylogResource' => ['Trips', 'Transfers to other warehouses', 2],
            'Pages\\AddressesToCheck' => ['Trips', null, 2],
            'Pages\\CrewBoard' => ['Trips', null, 3],
            'Pages\\TruckTracking' => ['Trips', null, 3],
            'Pages\\TruckDay' => ['Trips', null, 4],
            'Pages\\Fuel' => ['Trips', null, 5],

            'Pages\\SeaShipments' => ['Sea & returns', null, 1],
            'Pages\\ComingBack' => ['Sea & returns', null, 2],

            'Pages\\Unloadedcontainer' => ['Scan on this computer', 'Unload container', 1],
            'Pages\\Hubloaded' => ['Scan on this computer', 'Load delivery truck', 2],
            'Pages\\HubReturnBoxes' => ['Scan on this computer', 'Return boxes', 3],
            'Pages\\Whloaded' => ['Scan on this computer', 'Load transfer truck', 4],
            'Pages\\Whunloaded' => ['Scan on this computer', 'Receive transfer truck', 5],

            'Pages\\Fleet' => ['Trucks', 'Trucks', 1],
            'Pages\\RentalTrucks' => ['Trucks', null, 2],
            'Resources\\Truckteams\\TruckteamResource' => ['Trucks', 'Truck teams', 2],

            'Pages\\MapsRoutes' => ['Settings & help', null, 1],
            'Pages\\InstallApps' => ['Settings & help', null, 2],
            'Pages\\HelpGuide' => ['Settings & help', null, 3],
        ],
        'company' => [
            'Pages\\IncomingShipments' => ['Coming in', null, 1],
            'Pages\\IncomingBoxes' => ['Coming in', null, 2],

            'Resources\\Deliverylogs\\DeliverylogResource' => ['Delivery', 'Delivery trips', 1],
            'Resources\\Deliveryinvs\\DeliveryinvResource' => ['Delivery', 'Delivery invoices', 2],
            'Pages\\NotDelivered' => ['Delivery', null, 3],
            'Pages\\AddressesToCheck' => ['Delivery', null, 3],
            'Pages\\TrackBox' => ['Delivery', null, 4],

            'Pages\\WrongHub' => ['Returns', null, 1],

            'Pages\\LoadTruck' => ['Scan on this computer', 'Load truck', 1],
            'Pages\\ReturnBoxes' => ['Scan on this computer', 'Return boxes', 2],

            'Pages\\Fleet' => ['Trucks & people', 'Trucks', 1],
            'Pages\\RentalTrucks' => ['Trucks & people', null, 2],
            'Pages\\CrewBoard' => ['Trucks & people', null, 2],
            'Pages\\HubDrivers' => ['Trucks & people', null, 2],
            'Resources\\DriverResource' => ['Trucks & people', 'Crew', 3],
            'Pages\\TruckTracking' => ['Trucks & people', null, 4],
            'Pages\\TruckDay' => ['Trucks & people', null, 5],
            'Pages\\Fuel' => ['Trucks & people', null, 6],

            'Pages\\BoxPhotos' => ['Settings & help', 'Box photos', 1],
            'Pages\\MapsRoutes' => ['Settings & help', null, 2],
            'Pages\\InstallApps' => ['Settings & help', null, 3],
            'Pages\\HelpGuide' => ['Settings & help', null, 4],
        ],
    ];

    /** Pages with a number of what waits: panel => [short class => counter]. */
    public const BADGES = [
        'admin' => ['Pages\\SeaShipments' => 'sea', 'Pages\\WrongHub' => 'wrongHub'],
        'warehouse' => ['Pages\\SeaShipments' => 'sea', 'Pages\\ComingBack' => 'comingBack'],
        'company' => ['Pages\\IncomingShipments' => 'sea', 'Pages\\WrongHub' => 'wrongHub'],
    ];

    protected const BASE = ['admin' => 'App\\Filament\\', 'warehouse' => 'App\\Filament\\Warehouse\\', 'company' => 'App\\Filament\\Company\\'];

    public static function has(?string $panel): bool
    {
        return isset(self::GROUPS[$panel ?? '']);
    }

    /** @return array<NavigationGroup> */
    public static function groups(string $panel): array
    {
        return collect(self::GROUPS[$panel] ?? [])
            ->map(fn (bool $folded, string $name) => NavigationGroup::make($name)->collapsible()->collapsed($folded))
            ->values()->all();
    }

    protected static function full(string $panel, string $short): string
    {
        return str_starts_with($short, '\\') ? ltrim($short, '\\') : self::BASE[$panel].$short;
    }

    /** @return array<class-string, array{0: string, 1: ?string, 2: int}> */
    public static function items(string $panel): array
    {
        return collect(self::ITEMS[$panel] ?? [])->mapWithKeys(fn ($v, $k) => [static::full($panel, $k) => $v])->all();
    }

    /** @return array<class-string, string> */
    public static function badges(string $panel): array
    {
        return collect(self::BADGES[$panel] ?? [])->mapWithKeys(fn ($v, $k) => [static::full($panel, $k) => $v])->all();
    }

    /** The number shown beside a page, kept for a minute; null when nothing waits. */
    public static function count(string $panel, string $counter): ?string
    {
        $user = Auth::user();
        if (! $user) {
            return null;
        }
        try {
            $n = Cache::remember("menu:{$panel}:{$user->getKey()}:{$counter}", 60, function () use ($panel, $user, $counter): int {
                if (! Shipments::ready()) {
                    return 0;
                }
                $hub = Tracker::hubFor($user, $panel);
                if ($hub === false) {
                    return 0;
                }

                return match ($counter) {
                    'sea' => Shipments::visible($hub)->where('status', '!=', 'received')->count(),
                    'wrongHub' => WrongHubBox::query()->when(is_int($hub), fn ($q) => $q->where('logistichub_id', $hub))->where('status', 'waiting')->count(),
                    'comingBack' => WrongHubBox::query()->where('status', 'returning')->count(),
                    default => 0,
                };
            });
        } catch (\Throwable) {
            return null;
        }

        return $n > 0 ? (string) $n : null;
    }
}
DISPATCH_FILE_END_19

# ---------------------------------------------------------------- database/migrations/2026_11_19_000038_create_barangay_fills.php
mkdir -p 'database/migrations'
cat > 'database/migrations/2026_11_19_000038_create_barangay_fills.php' <<'DISPATCH_FILE_END_20'
<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

/**
 * Missing barangay: the system fills it in (same receiver, map, driver GPS, AI).
 * The manifest address is never changed; the filled barangay is kept here.
 */
return new class extends Migration
{
    public function up(): void
    {
        if (! Schema::hasTable('barangay_fills')) {
            Schema::create('barangay_fills', function (Blueprint $t) {
                $t->id();
                $t->foreignId('invoice_id')->unique();
                $t->foreignId('container_id')->nullable()->index();
                $t->string('barangay', 120)->nullable();
                $t->string('source', 10)->nullable();       // same, map, driver, ai, office
                $t->unsignedTinyInteger('confidence')->default(0);
                $t->string('clue', 300)->nullable();
                $t->json('clues')->nullable();              // words in the address the AI used
                $t->json('candidates')->nullable();         // [{name, pct, why}]
                $t->string('status', 10)->default('pending')->index(); // pending, used, check, checked, none
                $t->foreignId('checked_by')->nullable();
                $t->timestamp('checked_at')->nullable();
                $t->unsignedTinyInteger('tries')->default(0);
                $t->timestamps();
            });
        }
        if (! Schema::hasTable('receiver_places')) {
            Schema::create('receiver_places', function (Blueprint $t) {
                $t->id();
                $t->string('key', 64)->unique();            // p + phone, or n + name/street
                $t->string('city_key', 80)->index();
                $t->string('barangay', 120)->nullable();
                $t->string('source', 10)->nullable();
                $t->decimal('lat', 10, 7)->nullable();
                $t->decimal('lng', 10, 7)->nullable();
                $t->timestamp('confirmed_at')->nullable();
                $t->timestamps();
            });
        }
        if (Schema::hasTable('geo_places') && ! Schema::hasColumn('geo_places', 'barangay')) {
            Schema::table('geo_places', fn (Blueprint $t) => $t->string('barangay', 120)->nullable());
        }
        if (Schema::hasTable('trip_stops') && ! Schema::hasColumn('trip_stops', 'barangay_note')) {
            Schema::table('trip_stops', fn (Blueprint $t) => $t->string('barangay_note', 40)->nullable());
        }
    }

    public function down(): void
    {
        Schema::dropIfExists('barangay_fills');
        Schema::dropIfExists('receiver_places');
        if (Schema::hasColumn('geo_places', 'barangay')) {
            Schema::table('geo_places', fn (Blueprint $t) => $t->dropColumn('barangay'));
        }
        if (Schema::hasColumn('trip_stops', 'barangay_note')) {
            Schema::table('trip_stops', fn (Blueprint $t) => $t->dropColumn('barangay_note'));
        }
    }
};
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
DISPATCH_FILE_END_21

# ---------------------------------------------------------------- resources/views/filament/addresses/ai.blade.php
mkdir -p 'resources/views/filament/addresses'
cat > 'resources/views/filament/addresses/ai.blade.php' <<'DISPATCH_FILE_END_22'
<x-filament-panels::page>
<div class="ds-fl ds-ad">
    <div class="ds-ad__top">
        <span class="ds-te__title"><small>Settings › AI</small><h1>AI address cleaning</h1><small>Your existing helper, upgraded: it now also fills in a missing barangay. Same switch, same key.</small></span>
        <span class="ds-ad__master">
            <span class="ds-cb__pill is-own ds-ad__model">Claude · fast model ({{ $model }})</span>
            <button type="button" role="switch" aria-checked="{{ $on ? 'true' : 'false' }}" aria-label="AI address cleaning" wire:click="toggleOn" @class(['ds-te__switch', 'ds-ad__bigswitch', 'is-on' => $on])><i></i></button>
            <b>{{ $on ? 'On' : 'Off' }}</b>
        </span>
    </div>
    @unless ($hasKey)<span class="ds-ad__pending"><span>No AI key yet: steps 1–3 (same receiver, map, driver GPS) still work. Add the key in Settings → AI.</span></span>@endunless
    <div class="ds-fl__seg" role="tablist">
        @foreach (['settings' => 'Settings', 'try' => 'Try it', 'compare' => 'Today vs upgraded'] as $k => $l)
            <button type="button" role="tab" aria-selected="{{ $tab === $k ? 'true' : 'false' }}" wire:click="setTab('{{ $k }}')" @class(['is-on' => $tab === $k])>{{ $l }}</button>
        @endforeach
    </div>

    @if ($tab === 'settings')
        <div @class(['ds-ad__set', 'is-off' => ! $on])>
            <section class="ds-cb__card ds-ad__card">
                <span class="ds-te__head"><b>What it does</b><small>Click a row to turn it on or off</small></span>
                @foreach ($options as $k => $o)
                    <button type="button" class="ds-ad__optrow" wire:click="flip('{{ $k }}')" role="switch" aria-checked="{{ $o['on'] ? 'true' : 'false' }}">
                        <span class="ds-ad__icon">{{ $o['icon'] }}</span>
                        <span class="ds-ad__optt"><span><b>{{ $o['title'] }}</b>@if ($o['new'])<span class="ds-cb__pill is-warn">New</span>@endif</span><small>{{ $o['sub'] }}</small></span>
                        <span @class(['ds-te__switch', 'ds-ad__smswitch', 'is-on' => $o['on']])><i></i></span>
                    </button>
                @endforeach
                <span class="ds-ad__level">
                    <span><b>Use it by itself when the AI is at least</b><small>Below this, the box goes to Addresses to check</small></span>
                    <span class="ds-fl__seg">@foreach ($levels as $l => $label)<button type="button" wire:click="setLevel({{ $l }})" @class(['is-on' => $level === $l])>{{ $label }}</button>@endforeach</span>
                </span>
            </section>
            <div class="ds-ad__col">
                <section class="ds-cb__card ds-ad__card">
                    <b class="ds-ad__h">Order it tries</b>
                    @foreach ([['Same receiver before', 'your own delivery history', 'free', 'is-own'], ['Map lookup', $mapName, 'map key', 'is-info'], ['Driver GPS', 'saved at earlier deliveries', 'free', 'is-own'], ['AI reads the address', 'only when 1–3 find nothing', '< 1¢', 'is-warn']] as $n => [$t, $sub, $cost, $tone])
                        <span @class(['ds-ad__step', 'is-ai' => $n === 3])><b class="ds-ad__num">{{ $n + 1 }}</b><span><b>{{ $t }}</b><small>{{ $sub }}</small></span><span class="ds-cb__pill {{ $tone }}">{{ $cost }}</span></span>
                    @endforeach
                </section>
                <section class="ds-cb__card ds-ad__card">
                    <b class="ds-ad__h">This month</b>
                    <span class="ds-ad__month">
                        @foreach ([['Addresses cleaned', number_format($month['cleaned'])], ['Barangays filled in', number_format($month['filled'])], ['Sent to check', number_format($month['check'])], ['AI cost', '$'.number_format($month['cost'], 2)]] as [$l, $v])
                            <span><small>{{ $l }}</small><b>{{ $v }}</b></span>
                        @endforeach
                    </span>
                    <small class="ds-te__hint">Counts toward your AI monthly limit (${{ number_format($limit, 2) }}). Sent to the AI: address and city only, never the name or phone.</small>
                </section>
            </div>
        </div>
    @elseif ($tab === 'try')
        <div class="ds-ad__try">
            <section class="ds-cb__card ds-ad__card">
                <b class="ds-ad__h">Try an address</b>
                @foreach ($samples as $n => $s)
                    <button type="button" wire:click="sample({{ $n }})" @class(['ds-ad__sample', 'is-on' => $tryAddress === $s['address']])><b>{{ $s['address'] }}</b><small>{{ $s['city'] }}</small></button>
                @endforeach
                <label class="ds-te__field">Address<input type="text" wire:model="tryAddress" class="ds-te__input" placeholder="Blk 5 Lot 12 Villa Arcadia Subd., near SM Marilao"></label>
                <label class="ds-te__field">City, province<input type="text" wire:model="tryCity" class="ds-te__input" placeholder="Marilao, Bulacan"></label>
                @error('tryAddress')<small class="ds-te__err">{{ $message }}</small>@enderror @error('tryCity')<small class="ds-te__err">{{ $message }}</small>@enderror
                <button type="button" class="ds-te__btn is-main" wire:click="runTry" wire:loading.attr="disabled"><span wire:loading.remove wire:target="runTry">Try it</span><span wire:loading wire:target="runTry">Asking…</span></button>
                <small class="ds-te__hint">The test uses your key and costs the same as a real box (less than 1¢).</small>
            </section>
            <section class="ds-cb__card ds-ad__card">
                @if ($result)
                    @php($k = $result['status'])
                    <span class="ds-ad__rhead"><b class="ds-ad__h">What it answers</b><span class="ds-cb__pill ds-ad__tag is-{{ $k }}">{{ ['used' => 'Used by itself', 'check' => 'Goes to Addresses to check', 'none' => 'No clues'][$k] }}</span></span>
                    <span class="ds-ad__kv"><small>Written on the manifest</small><span>{{ $result['raw'] }}</span></span>
                    <span class="ds-ad__kv"><small>Cleaned for the map (same as today)</small><span>{{ $result['clean'] }}</span></span>
                    <span class="ds-ad__two">
                        <span class="ds-ad__kv is-{{ $k }}"><small>Barangay (new)</small><b>{{ $result['barangay'] ?: '—' }}</b></span>
                        <span class="ds-ad__kv"><small>How sure</small><b>{{ $result['barangay'] ? $result['confidence'].'%' : '—' }}</b></span>
                    </span>
                    <span class="ds-ad__kv is-plain"><small>{{ ($result['source'] ?? null) && $result['source'] !== 'ai' ? 'Found by' : 'Clue it used' }}</small><span>{{ ($result['source'] ?? null) && $result['source'] !== 'ai' ? (\App\Support\Maps\Barangays::SOURCES[$result['source']] ?? '').' · ' : '' }}{{ $result['clue'] }}</span></span>
                    <span class="ds-ad__next is-{{ $k }}">{{ ['used' => 'Sure enough ('.$level.'% or more), so the box gets '.$result['barangay'].' and the receiver is remembered.', 'check' => 'Below '.$level.'%: the office sees it in Addresses to check (✓ OK or Change).', 'none' => 'Stays in the city group; still goes on the trip. The driver uses the full address.'][$k] }}</span>
                @else
                    <b class="ds-ad__h">What it answers</b>
                    <p class="ds-cb__muted">Pick an address on the left (or type one) and press Try it.</p>
                @endif
            </section>
        </div>
    @else
        <section class="ds-cb__card ds-ad__table">
            <span class="ds-ad__cmp is-head"><span></span><span>Today</span><span>Upgraded</span></span>
            @foreach ([['Missing barangay', 'Left empty', 'Filled in from the real barangay list'], ['Landmarks (“near SM Marilao”)', 'Removed', 'Used as clues, kept for the driver'], ['When it runs', 'Only when a trip is put on the map', 'Right after the manifest is read'], ['How sure', 'Not shown', 'Shown; unsure ones go to Addresses to check'], ['Same receiver next time', 'Asked again', 'Remembered, no AI, no cost'], ['What is sent to the AI', 'Address', 'Address + city (never name or phone)'], ['Setting, key, limit', 'Settings → AI', 'Same (nothing new)']] as [$w, $a, $b])
                <span class="ds-ad__cmp"><b>{{ $w }}</b><span class="ds-ad__muted">{{ $a }}</span><span><span class="ds-ad__tick">✓</span>{{ $b }}</span></span>
            @endforeach
        </section>
        <span class="ds-ad__info">Nothing new to set up: same switch in Settings → AI, same API key, same monthly limit. The “Read a manifest” helper still does the first clean-up when a consolidator file is read.</span>
    @endif
</div>
</x-filament-panels::page>
DISPATCH_FILE_END_22

# ---------------------------------------------------------------- resources/views/filament/addresses/check.blade.php
mkdir -p 'resources/views/filament/addresses'
cat > 'resources/views/filament/addresses/check.blade.php' <<'DISPATCH_FILE_END_23'
<x-filament-panels::page>
<div class="ds-fl ds-ad">
@if ($box)
    @php($f = $box['f'])
    <button type="button" class="ds-tk__back" wire:click="closeBox">‹ Addresses to check</button>
    <span class="ds-te__title"><h1>{{ \Illuminate\Support\Str::title($box['i']->receiver_name) }} · box {{ $box['label'] }}</h1>
        <small>{{ $f->status === 'check' ? 'The AI is not sure. Pick the barangay; we remember it for this receiver next time.' : 'Pick the barangay; we remember it for this receiver next time.' }}</small></span>
    <div class="ds-ad__one">
        <div class="ds-ad__col">
            <section class="ds-cb__card ds-ad__card">
                <b class="ds-ad__h">Address as written on the manifest</b>
                <span class="ds-ad__addr">{!! collect($box['marked'])->map(fn ($p) => $p[1] ? '<mark class="ds-ad__mark is-'.e(\Illuminate\Support\Str::slug($p[1])).'">'.e($p[0]).'</mark>' : e($p[0]))->join('') !!}, {{ \Illuminate\Support\Str::title($box['i']->receiver_city) }}, {{ \Illuminate\Support\Str::title($box['i']->receiver_province) }}@if ($box['i']->receiver_mobile_no) · {{ $box['i']->receiver_mobile_no }}@endif</span>
                <small class="ds-te__hint">@if ($f->clues)Clues the AI used: {!! collect($f->clues)->map(fn ($c) => '<span class="ds-ad__mark is-'.e(\Illuminate\Support\Str::slug($c['kind'] ?? 'clue')).'">'.e($c['kind'] ?? 'clue').'</span>')->unique()->join(' ') !!}. @endif The original address is never changed.</small>
            </section>
            <section class="ds-cb__card ds-ad__card">
                <b class="ds-ad__h">Pick the barangay</b>
                @forelse ($box['cands'] as $n => $c)
                    <button type="button" wire:click="pick(@js($c['name']))" @class(['ds-ad__opt', 'is-on' => $chosen === $c['name'] && $search === ''])>
                        <i class="ds-te__radio" aria-hidden="true"></i>
                        <span><b>{{ $c['name'] }}</b><small>{{ $c['why'] }}</small></span>
                        <span @class(['ds-cb__pill', 'is-own' => $n === 0, 'is-muted' => $n > 0])>{{ $c['pct'] }}% likely</span>
                    </button>
                @empty
                    <small class="ds-te__hint">No suggestion. Type the barangay below.</small>
                @endforelse
                <input type="text" list="brgy-known" wire:model.live.debounce.300ms="search" class="ds-te__input" placeholder="🔍 Another barangay in {{ \Illuminate\Support\Str::title($box['i']->receiver_city) }}…">
                <datalist id="brgy-known">@foreach ($box['known'] as $k)<option value="{{ $k }}">@endforeach</datalist>
                <span class="ds-ad__use">
                    <button type="button" class="ds-te__btn is-main ds-ad__go" wire:click="useChosen" @disabled($chosen === '' && trim($search) === '')>Use {{ trim($search) !== '' ? \Illuminate\Support\Str::title($search) : ($chosen ?: '…') }}</button>
                    @if ($box['others'])<label class="ds-ad__also"><input type="checkbox" wire:model="alsoSame"> Also use for {{ $box['first'] }}'s other {{ $box['others'] }} {{ \Illuminate\Support\Str::plural('box', $box['others']) }}</label>@endif
                </span>
            </section>
        </div>
        <section class="ds-cb__card ds-ad__card">
            <b class="ds-ad__h">Map</b>
            @if ($box['place'])
                @php($p = $box['place'])
                <iframe class="ds-ad__map" title="Map" loading="lazy" src="https://www.openstreetmap.org/export/embed.html?bbox={{ $p->lng - 0.012 }}%2C{{ $p->lat - 0.008 }}%2C{{ $p->lng + 0.012 }}%2C{{ $p->lat + 0.008 }}&layer=mapnik&marker={{ $p->lat }}%2C{{ $p->lng }}"></iframe>
                <small class="ds-te__hint">The pin is where the map service found “{{ \Illuminate\Support\Str::limit($p->clean ?: $p->raw, 80) }}”{{ $p->exact ? '' : ' (area only)' }}. <a href="https://www.google.com/maps/search/?api=1&query={{ $p->lat }},{{ $p->lng }}" target="_blank" rel="noopener" class="ds-te__link">Open in Google Maps ›</a></small>
            @else
                <span class="ds-ad__nomap">📍 No pin yet: the map could not find this address{{ \App\Support\Maps\MapSettings::provider() === 'none' ? ' (no map key in Settings → Maps & routes)' : '' }}.</span>
            @endif
        </section>
    </div>
@else
    <div class="ds-ad__top">
        <span class="ds-te__title"><h1>Addresses to check</h1><small>Boxes with no barangay. Trips still go by city; the barangay only sets the stop order.</small></span>
        <select wire:model.live="container" class="ds-te__input ds-ad__pick" aria-label="Container">
            <option value="">All containers</option>
            @foreach ($containers as $c)<option value="{{ $c->id }}">{{ $c->container_no }}</option>@endforeach
        </select>
    </div>
    <div class="ds-tk__tiles">
        @foreach ($tiles as [$l, $v, $sub, $ring])
            <span @class(['ds-cb__card', 'ds-ad__tile', 'is-ring' => $ring && $v])><small class="ds-cb__label">{{ $l }}</small><b class="ds-ad__big num">{{ number_format($v) }}</b><small class="ds-cb__label">{{ $sub }}</small></span>
        @endforeach
    </div>
    @if ($pending)
        <span class="ds-ad__pending"><span>⏳ {{ $pending }} {{ \Illuminate\Support\Str::plural('box', $pending) }} waiting to be filled in (it runs by itself every 15 minutes).</span><button type="button" class="ds-te__btn" wire:click="fillNow" wire:loading.attr="disabled">Fill in now</button></span>
    @endif
    <div class="ds-fl__chips" role="group" aria-label="Show">
        @foreach ($chips as $k => [$l, $n])
            <button type="button" wire:click="setShow('{{ $k }}')" @class(['ds-fl__chip', 'is-on' => $show === $k])>{{ $l }} <span>{{ $n }}</span></button>
        @endforeach
    </div>
    <section class="ds-cb__card ds-ad__table">
        <span class="ds-ad__row is-head"><span>Receiver · box</span><span>Address as written</span><span>Suggested barangay</span><span>How we know</span><span></span></span>
        @forelse ($rows as $f)
            @php($i = $f->invoice)
            @php($alt = collect($f->candidates ?? [])->pluck('name')->reject(fn ($n) => $n === $f->barangay)->first())
            <span class="ds-ad__row" wire:key="r-{{ $f->id }}">
                <span class="ds-ad__who"><b>{{ \Illuminate\Support\Str::title($i?->receiver_name) }}</b><small>{{ $i ? \App\Filament\Shared\Addresses\AddressesToCheckPage::boxLabel($i) : '' }}</small></span>
                <span class="ds-ad__as">{{ $i?->receiver_address ?: '(no street)' }}<small>{{ \Illuminate\Support\Str::title(trim($i?->receiver_city.', '.$i?->receiver_province, ', ')) }}</small></span>
                <span class="ds-ad__who"><b @class(['is-empty' => ! $f->barangay])>{{ $f->barangay ? $f->barangay.($f->status === 'check' ? '?' : '') : '—' }}</b><small>{{ $f->status === 'none' ? 'Stays in the '.\Illuminate\Support\Str::title($i?->receiver_city).' group' : ($alt ? 'or '.$alt : '') }}</small></span>
                <span class="ds-ad__how">
                    <span @class(['ds-cb__pill', 'is-own' => in_array($f->status, ['used', 'checked'], true), 'is-warn' => $f->status === 'check', 'is-muted' => $f->status === 'none'])>{{ ['used' => 'Sure · used', 'checked' => 'Checked · used', 'check' => 'Not sure · check', 'none' => 'No clues'][$f->status] ?? $f->status }}</span>
                    <small>{{ $f->status === 'checked' ? 'Checked by the office '.$f->checked_at?->format('M j') : ($f->clue ?: (\App\Support\Maps\Barangays::SOURCES[$f->source] ?? '')) }}</small>
                </span>
                <span class="ds-ad__act">
                    @if ($f->status === 'check')
                        <button type="button" class="ds-te__btn is-main ds-ad__sm" wire:click="ok({{ $f->id }})">✓ OK</button>
                        <button type="button" class="ds-te__btn ds-ad__sm" wire:click="openBox({{ $f->id }})">Change</button>
                    @else
                        <small @class(['ds-ad__done', 'is-muted' => $f->status === 'none'])>{{ $f->status === 'none' ? 'Driver uses the full address' : ($f->status === 'checked' ? '✓ Saved for next time' : '✓ Used automatically') }}</small>
                    @endif
                </span>
            </span>
        @empty
            <p class="ds-cb__muted ds-ad__empty">{{ $show === 'check' ? '✓ Nothing to check. Every box with no barangay was filled in or stays in its city group.' : 'No boxes here.' }}</p>
        @endforelse
        @if ($more)<button type="button" class="ds-te__link ds-ad__moreb" wire:click="$set('limit', {{ $rows->count() + 40 }})">Show more</button>@endif
    </section>
@endif
</div>
</x-filament-panels::page>
DISPATCH_FILE_END_23

# ---------------------------------------------------------------- resources/views/filament/maps/trip-stops.blade.php
mkdir -p 'resources/views/filament/maps'
cat > 'resources/views/filament/maps/trip-stops.blade.php' <<'DISPATCH_FILE_END_24'
@php($zoneName = ['front' => 'FRONT', 'middle' => 'MIDDLE', 'back' => 'BACK'])
<x-filament-panels::page>
@assets
    <link rel="stylesheet" href="{{ \Filament\Support\Facades\FilamentAsset::getStyleHref('leaflet') }}">
    <script src="{{ \Filament\Support\Facades\FilamentAsset::getScriptSrc('leaflet') }}"></script>
    <script src="{{ \Filament\Support\Facades\FilamentAsset::getScriptSrc('trip-map') }}"></script>
@endassets
<div class="ds-mp">
    @if ($transfer)
        <section class="ds-board__panel">
            <p>This trip goes to <b>{{ $trip->destination?->hub_name ?? 'another hub' }}</b>. All boxes are one stop, so the loading order does not matter. The partner hub sorts its own trips when it makes them.</p>
        </section>
    @elseif ($stops->isEmpty())
        <section class="ds-board__panel"><p>No boxes on this trip yet. Add boxes and the stops are sorted right away.</p></section>
    @else
        <div class="ds-mp__badges">
            @if ($sourceText)
                <span class="is-ok">✓ {{ $sourceText }}@if ($route?->km) · {{ rtrim(rtrim(number_format($route->km, 1), '0'), '.') }} km · about {{ intdiv((int) $route->minutes, 60) ? intdiv((int) $route->minutes, 60).' h ' : '' }}{{ (int) $route->minutes % 60 }} min driving @endif</span>
            @endif
            @if ($route?->ai_fixed)<span class="is-ai">AI fixed {{ $route->ai_fixed }} {{ str('address')->plural($route->ai_fixed) }}</span>@endif
            @if ($noPin)<span class="is-warn">{{ $noPin }} {{ str('stop')->plural($noPin) }} without a pin: placed by barangay</span>@endif
            @if ($route?->waiting)<span class="is-warn">Finding {{ $route->waiting }} more {{ str('address')->plural($route->waiting) }}… refresh in a minute</span>@endif
            <span class="ds-mp__badgeactions">
                <x-filament::button tag="a" :href="$printUrl" target="_blank" color="gray" icon="heroicon-o-printer">Print loading list</x-filament::button>
                <x-filament::button color="gray" wire:click="toggleLock">{{ $route?->locked ? '🔒 Order locked · unlock' : '🔓 Auto-sort on · lock' }}</x-filament::button>
                <x-filament::button wire:click="resort" wire:loading.attr="disabled">Sort again</x-filament::button>
            </span>
        </div>

        <section class="ds-board__panel ds-mp__truck" aria-label="Truck seen from above">
            <span class="ds-mp__cab">CAB</span>
            @foreach (['front', 'middle', 'back'] as $z)
                @php($in = $stops->where('zone', $z))
                <span class="ds-mp__zone is-{{ $z }}"><b>{{ $zoneName[$z] }}</b><small>{{ $in->isEmpty() ? '—' : 'stops '.$in->pluck('stop_no')->sortDesc()->join(', ') }}</small><small>{{ $in->sum('boxes') }} {{ str('box')->plural($in->sum('boxes')) }}</small></span>
            @endforeach
            <span class="ds-mp__door">DOOR</span>
        </section>

        <div class="ds-mp__grid">
            <section class="ds-board__panel ds-mp__mapwrap">
                <div wire:ignore class="ds-mp__map" x-data x-init="
                    const boot = () => window.L && window.dsTripMap ? (window.dsTripMapNow = window.dsTripMap($el, @js($map))) : setTimeout(boot, 80); boot();
                " x-on:trip-map.window="window.dsTripMapNow && window.dsTripMapNow.draw($event.detail.data)"></div>
                <p class="ds-mp__legend"><span class="is-ok">● exact pin</span><span class="is-area">● area only</span><span class="is-prio">● priority</span><span>WH = start · map © OpenStreetMap</span></p>
            </section>

            <section class="ds-board__panel">
                <div class="ds-board__panel-head"><h2>Delivery order</h2><span class="ds-board__muted">drag ⠿ to change · load # is the loading order</span></div>
                <ol class="ds-mp__stops" x-data="{ from: null, over: null }">
                    @foreach ($stops as $i => $s)
                        <li wire:key="st-{{ $s->id }}-{{ $s->stop_no }}" draggable="true"
                            x-on:dragstart="from = {{ $s->id }}; $event.dataTransfer.effectAllowed = 'move'"
                            x-on:dragover.prevent="over = {{ $i }}" x-on:dragleave="over = null"
                            x-on:drop.prevent="if (from !== null && from !== {{ $s->id }}) $wire.moveStop(from, {{ $i }}); from = null; over = null"
                            x-bind:class="{ 'is-over': over === {{ $i }} }">
                            <span class="ds-mp__grab">⠿</span>
                            <span class="ds-mp__no">{{ $s->stop_no }}</span>
                            <span class="ds-mp__who"><b>{{ $s->name }}</b> · {{ $s->barangay ? $s->barangay.', ' : '' }}{{ $s->city }}
                                <span class="ds-mp__tags">
                                    @if ($s->priority)<em class="is-prio">priority</em>@endif
                                    @if ($s->barangay_note ?? null)<em @class(['ds-mp__brgy', 'is-ai' => str_contains($s->barangay_note, 'not checked'), 'is-ok' => in_array($s->barangay_note, ['checked', 'Map', 'Same receiver', 'Driver GPS'], true)])>{{ $s->barangay_note === 'no barangay' ? 'no barangay · driver uses full address' : 'barangay: '.$s->barangay_note }}</em>@endif
                                    @if (! $s->hasPin())<em class="is-warn">no pin · barangay order</em>@elseif (! $s->exact)<em class="is-area">area only</em>@endif
                                </span>
                            </span>
                            <span class="ds-mp__n">{{ $s->boxes }} {{ str('box')->plural($s->boxes) }}</span>
                            <span class="ds-mp__spot is-{{ $s->zone }}">{{ $zoneName[$s->zone] ?? '' }}</span>
                            <span class="ds-mp__load">load #{{ $stops->count() - $i }}</span>
                            <span class="ds-mp__updown"><button type="button" wire:click="moveStop({{ $s->id }}, {{ max(0, $i - 1) }})" @disabled($i === 0) aria-label="Move up">▲</button><button type="button" wire:click="moveStop({{ $s->id }}, {{ $i + 1 }})" @disabled($loop->last) aria-label="Move down">▼</button></span>
                        </li>
                    @endforeach
                </ol>
                <p class="ds-board__muted">Load #1 (stop {{ $stops->count() }}) goes in first, at the front next to the cab; stop 1 goes in last, at the door. All boxes of one receiver stay together.</p>
            </section>
        </div>
    @endif
</div>
</x-filament-panels::page>
DISPATCH_FILE_END_24

# ---------------------------------------------------------------- resources/views/filament/pages/ai-settings.blade.php
mkdir -p 'resources/views/filament/pages'
cat > 'resources/views/filament/pages/ai-settings.blade.php' <<'DISPATCH_FILE_END_25'
<x-filament-panels::page>
    <form wire:submit="save" class="ds-ai ds-ai-set">
        <section class="ds-board__panel">
            <div class="ds-board__panel-head"><h2>1 · Your Anthropic API key</h2>
                <span class="ds-ai__pill {{ $hasKey ? 'is-ok' : 'is-off' }}">{{ $hasKey ? 'Key saved · ends with '.$keyEnd : 'No key yet' }}</span>
            </div>
            <ol class="ds-ai-set__steps">
                <li>Go to <a href="https://console.anthropic.com/settings/keys" target="_blank" rel="noopener">console.anthropic.com</a>, sign in, add a payment card under Billing.</li>
                <li>Open <b>API keys</b> → <b>Create key</b>, copy it (it starts with <code>sk-ant-</code>).</li>
                <li>Paste it here and press <b>Save</b>, then <b>Test</b>.</li>
            </ol>
            <div class="ds-ai-set__key">
                <input type="password" wire:model="apiKey" autocomplete="off" placeholder="{{ $hasKey ? 'Paste a new key to replace the saved one' : 'sk-ant-…' }}" aria-label="API key">
                <x-filament::button type="submit">Save</x-filament::button>
                <x-filament::button color="gray" wire:click="test" type="button">Test</x-filament::button>
                @if ($hasKey)
                    <x-filament::button color="danger" outlined wire:click="removeKey" wire:confirm="Remove the AI key? All AI helpers that need it will stop." type="button">Remove key</x-filament::button>
                @endif
            </div>
            @error('apiKey')<p class="ds-ai__err">{{ $message }}</p>@enderror
            @if ($testResult)
                <p class="ds-ai__test {{ $testOk ? 'is-ok' : 'is-bad' }}">{{ $testResult }}</p>
            @endif
            <p class="ds-board__muted">The key is saved encrypted in your database and never shown again. Only the question, photo or file being checked is sent to the AI.</p>
        </section>

        <section class="ds-board__panel">
            <div class="ds-board__panel-head"><h2>2 · Which helpers are on</h2><span>this month</span></div>
            @foreach ($features as $key => [$title, $text, $who, $needsKey])
                <label class="ds-ai-set__feat" wire:key="f-{{ $key }}">
                    <input type="checkbox" wire:model="enabled.{{ $key }}">
                    <span>
                        <b>{{ $title }}</b>
                        <small>{{ $text }}</small>
                        <em>{{ $who }}{{ $needsKey ? '' : ' · works without a key' }}</em>
                        @if ($key === 'addresses' && class_exists(\App\Filament\Pages\AddressAi::class))<a href="{{ \App\Filament\Pages\AddressAi::getUrl() }}" class="ds-ad__more">Missing barangay, what it uses, try an address ›</a>@endif
                    </span>
                    <span class="ds-ai-set__use">
                        @php($u = $byFeature[$key] ?? null)
                        <b>${{ number_format((float) ($u->c ?? 0), 2) }}</b>
                        <small>{{ number_format((int) ($u->n ?? 0)) }} uses</small>
                    </span>
                </label>
            @endforeach
            <div class="ds-ai-set__save"><x-filament::button type="submit">Save</x-filament::button></div>
        </section>

        <section class="ds-board__panel">
            <div class="ds-board__panel-head"><h2>3 · Spending and models</h2></div>
            @php($pct = $limitNow > 0 ? min(100, round($spent / $limitNow * 100)) : 0)
            <div class="ds-ai-set__spend">
                <span><b>${{ number_format($spent, 2) }}</b> used in {{ now()->format('F') }}{{ $limitNow > 0 ? ' of $'.number_format($limitNow, 2) : '' }}</span>
                <i><s style="width: {{ $pct }}%" class="{{ $pct >= 90 ? 'is-bad' : '' }}"></s></i>
            </div>
            <div class="ds-gm__grid">
                <label class="ds-gm__field"><span>Monthly limit in US$ (AI pauses when reached · 0 = no limit)</span><input type="number" min="0" step="1" wire:model="limit"></label>
                <label class="ds-gm__field"><span>Fast model (photos, short texts)</span><input type="text" wire:model="modelFast"></label>
                <label class="ds-gm__field"><span>Smart model (questions, manifests, reports)</span><input type="text" wire:model="modelSmart"></label>
            </div>
            <p class="ds-board__muted">Costs shown here are estimates from the prices in <code>config/ai.php</code>. Your Anthropic Console shows the real bill. You can also set a spending limit there.</p>
            @foreach ($failures as $e)
                <p class="ds-ai__err">{{ $e->created_at->format('M j g:i A') }} · {{ $e->feature }} · {{ $e->error }}</p>
            @endforeach
            <div class="ds-ai-set__save"><x-filament::button type="submit">Save</x-filament::button></div>
        </section>

        <section class="ds-board__panel">
            <div class="ds-board__panel-head"><h2>Good to know</h2></div>
            <ul class="ds-ai-set__notes">
                <li>Alerts and the photo check backlog run from the scheduler. On your server keep <code>php artisan schedule:work</code> running (or the usual cron line).</li>
                <li>Customer chat page for receivers: <a href="{{ $chatUrl }}" target="_blank" rel="noopener">{{ $chatUrl }}</a> (only works when Customer chat is on).</li>
                <li>The AI only suggests. A person decides on damaged boxes, manifest rows, texts and emails.</li>
            </ul>
        </section>
    </form>
</x-filament-panels::page>
DISPATCH_FILE_END_25

# ---------------------------------------------------------------- tests/Feature/BarangayFillTest.php
mkdir -p 'tests/Feature'
cat > 'tests/Feature/BarangayFillTest.php' <<'DISPATCH_FILE_END_26'
<?php

use App\Filament\Pages\AddressAi;
use App\Filament\Pages\AddressesToCheck;
use App\Models\Ai\AiSetting;
use App\Models\AppSetting;
use App\Models\Invoice;
use App\Models\Maps\BarangayFill;
use App\Models\Maps\ReceiverPlace;
use App\Models\User;
use App\Support\Maps\Barangays;
use Database\Seeders\DemoSeeder;
use Filament\Facades\Filament;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Illuminate\Support\Facades\Cache;
use Illuminate\Support\Facades\Http;
use Livewire\Livewire;

uses(RefreshDatabase::class);

function brgyAi(bool $on = true): void
{
    AiSetting::query()->delete();
    AiSetting::create(['api_key' => 'sk-ant-test-1234', 'model_fast' => 'claude-haiku-5-5', 'model_smart' => 'claude-sonnet-5-5', 'monthly_limit' => 20, 'features' => $on ? ['addresses'] : []]);
    Cache::forget('ai.settings');
}

function brgyReply(array $items): array
{
    return ['content' => [['type' => 'text', 'text' => json_encode(['items' => $items])]], 'stop_reason' => 'end_turn', 'usage' => ['input_tokens' => 50, 'output_tokens' => 20]];
}

beforeEach(function () {
    $this->seed(DemoSeeder::class);
    $this->admin = User::where('email', 'admin@example.com')->firstOrFail();
    $this->actingAs($this->admin);
    Filament::setCurrentPanel(Filament::getPanel('admin'));
    $this->base = Invoice::firstOrFail();
    $this->box = function (array $over) {
        $i = $this->base->replicate();
        $i->forceFill(array_merge(['invoice' => (string) random_int(70000, 99999), 'is_delivered' => false, 'receiver_city' => 'Marilao', 'receiver_province' => 'Bulacan'], $over))->save();

        return $i->fresh();
    };
    // barangays we know in Marilao from earlier manifests
    foreach (['Lambakin', 'Saog', 'Abangan Norte'] as $b) {
        ($this->box)(['receiver_barangay' => $b, 'receiver_mobile_no' => '0900000'.random_int(1000, 9999), 'is_delivered' => true]);
    }
});

it('queues a box with no barangay and fills it from the same receiver before', function () {
    ($this->box)(['receiver_barangay' => 'Saog', 'receiver_mobile_no' => '0917 222 4410', 'is_delivered' => true]);
    $new = ($this->box)(['receiver_barangay' => '', 'receiver_mobile_no' => '+63 917 222 4410']);

    $f = BarangayFill::where('invoice_id', $new->id)->first();
    expect($f->status)->toBe('pending');
    Barangays::work();
    $f->refresh();
    expect($f->status)->toBe('used')->and($f->source)->toBe('same')->and($f->barangay)->toBe('Saog')
        ->and(Barangays::of($new->fresh()))->toBe('Saog')
        ->and($new->fresh()->receiver_barangay)->toBe(''); // the manifest address is never changed
});

it('asks the AI only when nothing else knows, and sends unsure ones to check', function () {
    brgyAi();
    $sure = ($this->box)(['receiver_barangay' => '', 'receiver_address' => '221 MacArthur Hwy, tapat Petron', 'receiver_mobile_no' => '0918 111 0001']);
    $unsure = ($this->box)(['receiver_barangay' => 'N/A', 'receiver_address' => 'Blk 5 Lot 12 Villa Arcadia Subd., near SM Marilao', 'receiver_mobile_no' => '0918 111 0002']);
    Http::fake(['api.anthropic.com/*' => Http::response(brgyReply([
        ['i' => 0, 'barangay' => 'Abangan Norte', 'confidence' => 93, 'why' => 'MacArthur Hwy near Petron', 'clues' => [], 'candidates' => []],
        ['i' => 1, 'barangay' => 'Lambakin', 'confidence' => 72, 'why' => 'Villa Arcadia is in Lambakin', 'clues' => [['text' => 'Villa Arcadia Subd.', 'kind' => 'subdivision'], ['text' => 'not in address', 'kind' => 'landmark']],
            'candidates' => [['name' => 'Lambakin', 'pct' => 72, 'why' => 'map'], ['name' => 'Saog', 'pct' => 20, 'why' => 'mall'], ['name' => 'Made Up', 'pct' => 8, 'why' => 'x']]],
    ]))]);

    Barangays::work();
    $a = BarangayFill::where('invoice_id', $sure->id)->first();
    $b = BarangayFill::where('invoice_id', $unsure->id)->first();
    expect($a->status)->toBe('used')->and($a->barangay)->toBe('Abangan Norte')
        ->and($b->status)->toBe('check')->and($b->barangay)->toBe('Lambakin')
        ->and(collect($b->candidates)->pluck('name')->all())->toBe(['Lambakin', 'Saog'])   // never a made-up name
        ->and($b->clues)->toHaveCount(1)
        ->and(Barangays::of($unsure->fresh()))->toBeNull();
    Http::assertSent(fn ($r) => ! str_contains($r->body(), (string) $sure->receiver_name) && ! str_contains($r->body(), '0918 111'));
});

it('lists the boxes, ✓ OK confirms, Change picks another one for the receiver\'s other boxes too', function () {
    $one = ($this->box)(['receiver_barangay' => '', 'receiver_name' => 'Ana Cruz', 'receiver_mobile_no' => '0917 999 0001', 'set_key' => null]);
    $two = ($this->box)(['receiver_barangay' => '', 'receiver_name' => 'Ana Cruz', 'receiver_mobile_no' => '0917 999 0001', 'set_key' => null]);
    $jo = ($this->box)(['receiver_barangay' => '', 'receiver_name' => 'Jose Ramos', 'receiver_mobile_no' => '0917 999 0002']);
    foreach ([$one, $two] as $i) {
        BarangayFill::where('invoice_id', $i->id)->update(['status' => 'check', 'source' => 'ai', 'barangay' => 'Lambakin', 'confidence' => 70, 'candidates' => json_encode([['name' => 'Lambakin', 'pct' => 70, 'why' => 'subd'], ['name' => 'Saog', 'pct' => 20, 'why' => 'mall']])]);
    }
    BarangayFill::where('invoice_id', $jo->id)->update(['status' => 'check', 'source' => 'ai', 'barangay' => 'Saog', 'confidence' => 70]);

    $page = Livewire::test(AddressesToCheck::class)->assertSee('Addresses to check')->assertSee('Ana Cruz')->assertSee('Not sure · check')->assertSee('or Saog');
    $page->call('ok', BarangayFill::where('invoice_id', $jo->id)->value('id'));
    expect(BarangayFill::where('invoice_id', $jo->id)->value('status'))->toBe('checked')
        ->and(ReceiverPlace::where('key', 'p9179990002')->value('barangay'))->toBe('Saog');

    $page->call('openBox', BarangayFill::where('invoice_id', $one->id)->value('id'))->assertSee('Pick the barangay')->assertSee('Also use for Ana')
        ->call('pick', 'Saog')->call('useChosen');
    expect(BarangayFill::whereIn('invoice_id', [$one->id, $two->id])->pluck('barangay')->unique()->all())->toBe(['Saog'])
        ->and(BarangayFill::whereIn('invoice_id', [$one->id, $two->id])->pluck('status')->unique()->all())->toBe(['checked']);
    $page->call('setShow', 'check')->assertSee('Nothing to check');
});

it('has its settings: switches, the sure level, and Try it', function () {
    brgyAi();
    Livewire::test(AddressAi::class)->assertSee('AI address cleaning')->assertSee('Fill in a missing barangay')->assertSee('Order it tries')
        ->call('flip', 'landmarks')->call('setLevel', 60)->call('toggleOn');
    expect(Barangays::on('landmarks'))->toBeFalse()->and(Barangays::level())->toBe(60)->and(AiSetting::current()->isOn('addresses'))->toBeFalse();

    brgyAi();
    AppSetting::put('addr.level', '75');
    Http::fake(['api.anthropic.com/*' => Http::sequence()
        ->push(['content' => [['type' => 'text', 'text' => json_encode(['addresses' => [['i' => 0, 'address' => 'Purok 3, San Jose, Meycauayan, Bulacan']]])]], 'usage' => ['input_tokens' => 1, 'output_tokens' => 1]])
        ->push(brgyReply([['i' => 0, 'barangay' => 'Saog', 'confidence' => 72, 'why' => 'SJ', 'clues' => [], 'candidates' => []]]))]);
    Livewire::test(AddressAi::class)->call('setTab', 'try')->set('tryAddress', 'Purok 3, Brgy SJ')->set('tryCity', 'Marilao, Bulacan')->call('runTry')
        ->assertSee('Purok 3, San Jose, Meycauayan, Bulacan')->assertSee('72%')->assertSee('Goes to Addresses to check');
});

it('marks trip stops and remembers where the driver delivered', function () {
    $i = ($this->box)(['receiver_barangay' => '', 'receiver_mobile_no' => '0917 555 0100']);
    expect(Barangays::note($i))->toBe('no barangay');
    BarangayFill::where('invoice_id', $i->id)->update(['status' => 'check', 'barangay' => 'Saog', 'source' => 'ai']);
    expect(Barangays::note($i->fresh()))->toBe('AI guess, not checked');
    Barangays::remember($i, 'Saog', 'driver', 14.8, 120.95, true);
    expect(ReceiverPlace::where('key', 'p9175550100')->first()->lat)->toBe(14.8);
});
DISPATCH_FILE_END_26

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
