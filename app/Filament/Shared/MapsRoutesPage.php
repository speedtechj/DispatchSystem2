<?php

namespace App\Filament\Shared;

use App\Models\Ai\AiSetting;
use App\Models\AppSetting;
use App\Models\Deliverylog;
use App\Models\Logistichub;
use App\Models\Maps\GeoPlace;
use App\Models\Maps\TripStop;
use App\Models\Warehouse;
use App\Support\Ai\Ai;
use App\Support\Maps\Geocoder;
use App\Support\Maps\MapSettings;
use BackedEnum;
use Filament\Notifications\Notification;
use Filament\Pages\Page;
use Filament\Support\Icons\Heroicon;
use Illuminate\Support\Facades\Auth;
use Throwable;
use UnitEnum;

/**
 * Settings → Maps & routes. Admin sees everything (keys, switches, all pins);
 * Warehouse and Partner hub see what is used, their own start pin, and fix the
 * pins of addresses on their own trips. Keys are set once, in Admin.
 *
 * Admin → Settings → Maps & routes. Put in the keys you have; the system uses
 * what is there and falls back by itself (AI key → addresses cleaned; map key →
 * addresses found and stops in road order; no key → barangay order).
 */
abstract class MapsRoutesPage extends Page
{
    /** Admin: keys, switches and every pin. Warehouse / Partner hub: only their own places. */
    protected static bool $full = true;

    protected string $view = 'filament.pages.maps-routes';

    protected static string|UnitEnum|null $navigationGroup = 'Settings';

    protected static ?int $navigationSort = 90;

    protected static string|BackedEnum|null $navigationIcon = Heroicon::OutlinedMap;

    protected static ?string $navigationLabel = 'Maps & routes';

    protected static ?string $title = 'Maps & routes';

    protected static ?string $slug = 'maps-routes';

    public string $provider = 'google';

    public string $key = '';

    public string $testAddress = 'Basak, Mandaue City, Cebu';

    public ?string $testResult = null;

    public bool $testOk = false;

    /** 'wh:1' => '10.31, 123.88' */
    public array $starts = [];

    /** geo place id => '10.31, 123.88' */
    public array $pins = [];

    /** Warehouse id and hub id this person may set pins for (null = all, for Admin). */
    protected function scope(): array
    {
        $u = Auth::user();

        return static::$full ? [null, null] : [(int) $u?->warehouse_id, (int) $u?->logistichub_id];
    }

    /** Keys and switches are changed in Admin only. */
    protected function notFull(): bool
    {
        return ! static::$full;
    }

    protected function warehousesInScope()
    {
        [$wh] = $this->scope();
        $q = Warehouse::orderBy('name');

        return static::$full ? $q->get(['id', 'name', 'city']) : ($wh ? $q->whereKey($wh)->get(['id', 'name', 'city']) : collect());
    }

    protected function hubsInScope()
    {
        [$wh, $hub] = $this->scope();
        $q = Logistichub::orderBy('hub_name');
        if (static::$full) {
            return $q->get(['id', 'hub_name']);
        }

        // a warehouse's trips start at the warehouse; a partner hub's at the hub
        return $wh || ! $hub ? collect() : $q->whereKey($hub)->get(['id', 'hub_name']);
    }

    /** Saved places used on this person's trips (all for Admin). */
    protected function placesQuery()
    {
        $q = GeoPlace::query();
        if (static::$full) {
            return $q;
        }
        [, $hub] = $this->scope();
        $trips = Deliverylog::where('logistichub_id', $hub)->orWhere('assigned_to', $hub)->pluck('id');

        return $q->whereIn('id', TripStop::whereIn('deliverylog_id', $trips)->whereNotNull('geo_place_id')->distinct()->pluck('geo_place_id'));
    }

    public function mount(): void
    {
        $this->provider = MapSettings::chosen();
        foreach ($this->warehousesInScope() as $w) {
            $p = MapSettings::startPin('wh', $w->id);
            $this->starts['wh:'.$w->id] = $p ? $p[0].', '.$p[1] : '';
        }
        foreach ($this->hubsInScope() as $h) {
            $p = MapSettings::startPin('hub', $h->id);
            $this->starts['hub:'.$h->id] = $p ? $p[0].', '.$p[1] : '';
        }
    }

    public function pick(string $provider): void
    {
        if ($this->notFull()) {
            return;
        }
        if (! isset(MapSettings::PROVIDERS[$provider])) {
            return;
        }
        $this->provider = $provider;
        AppSetting::put('maps.provider', $provider);
        $this->reset('key', 'testResult', 'testOk');
    }

    public function saveKey(): void
    {
        if ($this->notFull()) {
            return;
        }
        $this->validate(['key' => ['required', 'string', 'max:500', 'regex:/^\S+$/']], ['key.regex' => 'The key has a space in it. Paste it again.']);
        if ($this->provider === 'none') {
            return;
        }
        MapSettings::putKey($this->provider, $this->key);
        $this->key = '';
        // addresses that waited for a key can be looked up now
        GeoPlace::where('status', 'pending')->update(['tries' => 0]);
        Notification::make()->title(MapSettings::providerName($this->provider).' key saved')->body('Press Test to check it.')->success()->send();
    }

    public function removeKey(): void
    {
        if ($this->notFull()) {
            return;
        }
        MapSettings::putKey($this->provider, null);
        $this->reset('testResult', 'testOk');
        Notification::make()->title('Key removed')->send();
    }

    public function test(): void
    {
        if ($this->notFull()) {
            return;
        }
        $this->testOk = false;
        if ($this->provider === 'none') {
            $this->testResult = 'No map is used: stops go in barangay order.';

            return;
        }
        try {
            $hit = Geocoder::lookup($this->provider, $this->testAddress.', Philippines');
            $this->testOk = (bool) $hit;
            $this->testResult = $hit
                ? '✓ Found "'.$hit['label'].'" at '.round($hit['lat'], 5).', '.round($hit['lng'], 5).($hit['exact'] ? '' : ' (area only, not the exact house)').'. The key works.'
                : 'The key works, but this address was not found. Try a fuller one.';
        } catch (Throwable $e) {
            $this->testResult = 'Did not work: '.str($e->getMessage())->limit(220);
        }
    }

    public function toggleAi(): void
    {
        if ($this->notFull()) {
            return;
        }
        $row = AiSetting::query()->first() ?? new AiSetting(['model_fast' => 'claude-haiku-5-5', 'model_smart' => 'claude-sonnet-5-5', 'monthly_limit' => 20]);
        $on = collect($row->features ?? []);
        $row->features = $on->contains('addresses') ? $on->reject(fn ($f) => $f === 'addresses')->values()->all() : $on->push('addresses')->values()->all();
        $row->save();
    }

    public function togglePriority(): void
    {
        if ($this->notFull()) {
            return;
        }
        AppSetting::put('maps.priority_first', MapSettings::priorityFirst() ? 0 : 1);
    }

    public function toggleEarly(): void
    {
        if ($this->notFull()) {
            return;
        }
        AppSetting::put('maps.warn_early', MapSettings::warnEarly() ? 0 : 1);
    }

    public function saveStarts(): void
    {
        $bad = [];
        $allowed = $this->warehousesInScope()->map(fn ($w) => 'wh:'.$w->id)->merge($this->hubsInScope()->map(fn ($h) => 'hub:'.$h->id))->all();
        foreach ($this->starts as $k => $text) {
            if (! in_array($k, $allowed, true)) {
                continue;
            }
            [$kind, $id] = explode(':', $k);
            if (filled($text) && ! MapSettings::parsePin($text)) {
                $bad[] = $k;

                continue;
            }
            MapSettings::putStartPin($kind, (int) $id, $text);
        }
        $bad
            ? Notification::make()->title('Some pins could not be read')->body('Paste them like 10.3157, 123.8854 (in Google Maps: right-click the place, click the numbers).')->warning()->send()
            : Notification::make()->title('Start pins saved')->success()->send();
    }

    public function savePin(int $id): void
    {
        $place = $this->placesQuery()->find($id);
        $pin = MapSettings::parsePin($this->pins[$id] ?? '');
        if (! $place || ! $pin) {
            Notification::make()->title('Paste the pin like 10.3157, 123.8854')->warning()->send();

            return;
        }
        $place->update(['lat' => $pin[0], 'lng' => $pin[1], 'exact' => true, 'status' => 'manual', 'source' => 'manual', 'suggested_lat' => null, 'suggested_lng' => null, 'suggested_at' => null]);
        unset($this->pins[$id]);
        Notification::make()->title('Pin saved. Trips with this address use it from now on.')->success()->send();
    }

    public function acceptSuggestion(int $id): void
    {
        $place = $this->placesQuery()->whereNotNull('suggested_at')->find($id);
        $place?->update(['lat' => $place->suggested_lat, 'lng' => $place->suggested_lng, 'exact' => true, 'status' => 'manual', 'source' => 'driver', 'suggested_lat' => null, 'suggested_lng' => null, 'suggested_at' => null]);
    }

    public function rejectSuggestion(int $id): void
    {
        $this->placesQuery()->whereKey($id)->update(['suggested_lat' => null, 'suggested_lng' => null, 'suggested_at' => null, 'suggested_by' => null]);
    }

    protected function getViewData(): array
    {
        $provider = MapSettings::provider();
        $ai = Ai::enabled('addresses');
        $aiOn = Ai::switchedOn('addresses');
        $hasAiKey = AiSetting::current()->hasKey();

        return [
            'providers' => collect(MapSettings::PROVIDERS)->map(fn ($name, $k) => [
                'key' => $k, 'name' => $name, 'masked' => $k === 'none' ? null : MapSettings::masked($k),
                'text' => [
                    'google' => 'Best match for Philippine addresses and real road times. Paid per use after a free monthly amount.',
                    'ors' => 'Free plan, good for most daily trips. Uses OpenStreetMap. Fewer street-level matches.',
                    'none' => 'Uses the barangay order (Route areas). No map, no cost.',
                ][$k],
            ])->values(),
            'inUse' => $provider,
            'chain' => [
                ['Clean addresses', $ai ? 'AI (Claude)' : 'Off', $ai ? 'Messy addresses are fixed before the map looks them up.' : ($aiOn && ! $hasAiKey ? 'Switched on, but no AI key in Settings → AI.' : 'Addresses are used as typed.'), $ai],
                ['Find locations', $provider === 'none' ? 'Not used' : MapSettings::providerName($provider), $provider === 'none' ? 'No map key: stops are placed by barangay.' : 'Each address is looked up once and saved.', $provider !== 'none'],
                ['Order of stops', $provider === 'none' ? 'Barangay order' : MapSettings::providerName($provider).' routes', $provider === 'none' ? 'Route area, then city and barangay, from the warehouse.' : 'Shortest road route from the start pin.', true],
            ],
            'fallback' => MapSettings::chosen() !== 'none' && $provider !== MapSettings::chosen(),
            'aiOn' => $aiOn, 'aiReady' => $ai, 'hasAiKey' => $hasAiKey,
            'priorityFirst' => MapSettings::priorityFirst(),
            'warnEarly' => MapSettings::warnEarly(),
            'full' => static::$full,
            'warehouses' => $this->warehousesInScope(),
            'hubs' => $this->hubsInScope(),
            'stats' => [
                'found' => $this->placesQuery()->whereIn('status', ['found', 'manual'])->count(),
                'month' => $this->placesQuery()->where('tries', '>', 0)->where('updated_at', '>=', now()->startOfMonth())->whereIn('source', ['google', 'ors'])->count(),
                'missing' => $this->placesQuery()->where('status', 'not_found')->count(),
                'waiting' => $this->placesQuery()->where('status', 'pending')->count(),
            ],
            'fix' => $this->placesQuery()->where('status', 'not_found')->latest('updated_at')->limit(20)->get(),
            'suggested' => $this->placesQuery()->whereNotNull('suggested_at')->latest('suggested_at')->limit(20)->get(),
        ];
    }
}
