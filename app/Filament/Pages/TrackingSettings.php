<?php

namespace App\Filament\Pages;

use App\Models\AppSetting;
use App\Models\Truck;
use App\Support\Tracking\TrackSettings;
use BackedEnum;
use Filament\Notifications\Notification;
use Filament\Pages\Page;
use Filament\Support\Icons\Heroicon;
use Illuminate\Support\Facades\Auth;
use UnitEnum;

/** Admin → Settings → Truck tracking: where each truck's location comes from, how often, alerts. */
class TrackingSettings extends Page
{
    protected string $view = 'filament.tracking.settings';

    protected static string|UnitEnum|null $navigationGroup = 'Settings';

    protected static string|BackedEnum|null $navigationIcon = Heroicon::OutlinedSignal;

    protected static ?string $navigationLabel = 'Truck tracking';

    protected static ?string $title = 'Settings · Truck tracking';

    protected static ?string $slug = 'tracking-settings';

    protected static ?int $navigationSort = 91;

    public string $defaultSource = 'app';

    /** truck id => app | android | tracker */
    public array $sources = [];

    public array $values = [];

    public string $googleKey = '';

    public string $summaryEmails = '';

    public static function canAccess(): bool
    {
        return (bool) Auth::user()?->hasRole('super_admin');
    }

    public function mount(): void
    {
        foreach (Truck::orderBy('plate_no')->get(['id']) as $t) {
            $this->sources[$t->id] = TrackSettings::source($t->id);
        }
        $this->summaryEmails = (string) AppSetting::get('track.summary_emails', '');
        foreach (array_keys(TrackSettings::DEFAULTS) as $k) {
            $this->values[$k] = (string) TrackSettings::get($k);
        }
    }

    public function setAll(string $source): void
    {
        if (! isset(TrackSettings::SOURCES[$source])) {
            return;
        }
        foreach (array_keys($this->sources) as $id) {
            $this->sources[$id] = $source;
        }
    }

    public function save(): void
    {
        $this->validate([
            'values.interval' => 'required|integer|in:15,30,60,120',
            'values.keep_days' => 'required|integer|in:30,90,180,365',
            'values.stopped' => 'required|integer|min:5|max:240',
            'values.no_signal' => 'required|integer|min:5|max:240',
            'values.off_route' => 'required|numeric|min:1|max:50',
            'values.back' => 'required|in:0,1',
            'values.map' => 'required|in:osm,google',
            'googleKey' => ['nullable', 'string', 'max:300', 'regex:/^\S+$/'],
            'summaryEmails' => ['nullable', 'string', 'max:500'],
        ]);
        AppSetting::put('track.summary_emails', trim($this->summaryEmails));
        foreach ($this->values as $k => $v) {
            TrackSettings::put($k, $k === 'map' ? $v : (int) $v);
        }
        foreach ($this->sources as $id => $s) {
            AppSetting::put('track.source.'.(int) $id, isset(TrackSettings::SOURCES[$s]) ? $s : 'app');
        }
        if (trim($this->googleKey) !== '') {
            TrackSettings::putGoogleKey($this->googleKey);
            $this->googleKey = '';
        }
        if ($this->values['map'] === 'google' && ! TrackSettings::googleKey()) {
            Notification::make()->title('Saved · Google Maps needs a browser key')->body('Until it is added, the tracking map uses OpenStreetMap.')->warning()->send();

            return;
        }
        Notification::make()->title('Truck tracking saved')->success()->send();
    }

    public function removeGoogleKey(): void
    {
        TrackSettings::putGoogleKey(null);
        Notification::make()->title('Google Maps key removed: the map uses OpenStreetMap')->send();
    }

    public function newTrackerLink(): void
    {
        AppSetting::put('track.tracker_token', null);
        TrackSettings::trackerToken();
        Notification::make()->title('New tracker link made')->body('Put the new link in every tracker. The old one stops working now.')->warning()->send();
    }

    protected function getViewData(): array
    {
        return [
            'trucks' => Truck::orderBy('plate_no')->get(['id', 'plate_no', 'description', 'category']),
            'options' => TrackSettings::SOURCES,
            'hasGoogle' => (bool) TrackSettings::googleKey(),
            'trackerLink' => url('/track/in/'.TrackSettings::trackerToken()),
        ];
    }
}
