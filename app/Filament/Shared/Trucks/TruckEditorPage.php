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
