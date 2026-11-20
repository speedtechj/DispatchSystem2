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
