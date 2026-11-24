<?php

namespace App\Filament\Shared\People;

use App\Models\Truck;
use App\Models\Truckcrew;
use App\Models\User;
use App\Models\Workposition;
use App\Support\People\People;
use App\Support\Tracking\Tracker;
use Filament\Actions\Action;
use Filament\Facades\Filament;
use Filament\Forms\Components\Select;
use Filament\Forms\Components\TextInput;
use Filament\Forms\Components\Toggle;
use Filament\Forms\Components\ToggleButtons;
use Filament\Notifications\Notification;
use Filament\Pages\Page;
use Filament\Schemas\Components\Grid;
use Filament\Schemas\Components\Section;
use Filament\Schemas\Components\Text;
use Filament\Schemas\Components\Utilities\Get;
use Filament\Schemas\Components\Utilities\Set;
use Illuminate\Support\Collection;
use Illuminate\Support\Facades\Auth;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Hash;
use Illuminate\Support\HtmlString;
use Illuminate\Support\Str;

/**
 * Crew (board 60): the trucks of this warehouse or partner hub with their crew, and the people.
 * Positions are the work positions with Truck crew ticked (Settings → Work positions); the hub is the user's own.
 */
class CrewPage extends Page
{
    protected string $view = 'filament.people.crew';

    protected static ?string $navigationLabel = 'Crew';

    protected static ?string $title = 'Crew';

    protected static ?string $slug = 'crew';

    protected static string|\BackedEnum|null $navigationIcon = 'heroicon-o-user-group';

    /** trucks | people */
    public string $tab = 'trucks';

    /** The truck whose "Add crew" list is open. */
    public ?int $picking = null;

    /** Lists read once per request; emptied after a change. */
    protected array $cache = [];

    public static function canAccess(): bool
    {
        return is_int(Tracker::hubFor(Auth::user(), Filament::getCurrentPanel()?->getId()));
    }

    protected function hub(): ?int
    {
        $h = Tracker::hubFor(Auth::user(), Filament::getCurrentPanel()?->getId());

        return is_int($h) ? $h : null;
    }

    public function setTab(string $tab): void
    {
        $this->tab = in_array($tab, ['trucks', 'people'], true) ? $tab : 'trucks';
        $this->picking = null;
    }

    public function togglePick(int $truckId): void
    {
        $this->picking = $this->picking === $truckId ? null : $truckId;
    }

    /** @return Collection<int, Truck> */
    protected function trucks(): Collection
    {
        return $this->cache['trucks'] ??= \App\Support\Rentals::usable(Truck::where('is_active', 1)->where('logistichub_id', $this->hub() ?? 0))->orderBy('plate_no')->get();
    }

    /** @return Collection<int, User> every crew member of this hub (turned off too) */
    protected function people(): Collection
    {
        return $this->cache['people'] ??= User::with('workposition.panelcategory')->where('is_crew', true)->where('logistichub_id', $this->hub() ?? 0)
            ->orderByDesc('is_active')->orderBy('first_name')->get();
    }

    /** crew user id => truck id */
    protected function onTruck(): array
    {
        return $this->cache['on'] ??= Truckcrew::whereIn('truck_id', $this->trucks()->pluck('id'))->orderBy('id')->pluck('truck_id', 'crew')->map(fn ($t) => (int) $t)->all();
    }

    public function addToTruck(int $truckId, int $userId): void
    {
        $truck = $this->trucks()->firstWhere('id', $truckId);
        $user = $this->people()->first(fn ($u) => $u->id === $userId && $u->is_active);
        if (! $truck || ! $user) {
            return;
        }
        DB::transaction(function () use ($truck, $user) {
            // one person, one truck
            Truckcrew::where('crew', $user->id)->where('truck_id', '!=', $truck->id)->get()->each->delete();
            Truckcrew::firstOrCreate(['truck_id' => $truck->id, 'crew' => $user->id], ['user_id' => Auth::id()]);
            $user->forceFill(['is_assigned' => true])->saveQuietly();
        });
        $this->cache = [];
        Notification::make()->title(People::name($user).' is on '.$truck->plate_no)->success()->send();
    }

    public function removeFromTruck(int $truckId, int $userId): void
    {
        if (! $this->trucks()->contains('id', $truckId)) {
            return;
        }
        Truckcrew::where('truck_id', $truckId)->where('crew', $userId)->get()->each->delete();
        User::whereKey($userId)->update(['is_assigned' => Truckcrew::where('crew', $userId)->exists()]);
        $this->cache = [];
    }

    // ------------------------------------------------------------------ New / Edit crew member

    protected function crewSchema(?User $record): array
    {
        $positions = People::crewPositions();

        return [
            Grid::make(2)->schema([
                TextInput::make('first_name')->required()->maxLength(255),
                TextInput::make('last_name')->required()->maxLength(255),
            ]),
            TextInput::make('mobile_number')->label('Mobile · the office and the Driver app use it')->tel()->required()->maxLength(255),
            Section::make('Position')->description('Crew positions from Settings → Work positions')->compact()->schema([
                ToggleButtons::make('workposition_id')->hiddenLabel()->required()->inline()->live()
                    ->options($positions->mapWithKeys(fn ($w) => [$w->id => $w->position_description.(People::usesDriverApp($w) ? ' · Driver app' : '')])->all()
                        + ($record?->workposition && ! $positions->contains('id', $record->workposition_id) ? [$record->workposition_id => $record->workposition->position_description] : []))
                    ->extraAttributes(['class' => 'ds-us__chips']),
                Text::make(new HtmlString('<small class="ds-cr__hint">Missing a position? The office adds it in Settings → Work positions (tick Truck crew). It shows here right away.</small>')),
                Select::make('truck_id')->label('Truck · optional')->placeholder('No truck yet')
                    ->options($this->trucks()->pluck('plate_no', 'id')->all()),
            ]),
            Section::make('Driver app sign-in')->compact()->schema([
                TextInput::make('email')->email()->maxLength(255)
                    ->unique('users', 'email', ignoreRecord: true, ignorable: $record)
                    ->required(fn (Get $get) => $this->driverApp($get('workposition_id')))
                    ->helperText(fn (Get $get) => $this->driverApp($get('workposition_id')) ? 'Needed: this position uses the Driver app' : 'Optional for this position'),
                TextInput::make('password')->label($record ? 'New password · leave empty to keep it' : 'Password')
                    ->password()->revealable()->minLength(8)->maxLength(255)
                    ->required(fn (Get $get) => ! $record && $this->driverApp($get('workposition_id')))
                    ->hintAction(Action::make('makePassword')->label('Make one')->icon('heroicon-m-sparkles')->action(function (Set $set) {
                        $pw = People::randomPassword();
                        $set('password', $pw);
                        Notification::make()->title('Password made: '.$pw)->body('Give it to them, then save. Click the eye to see it.')->success()->persistent()->send();
                    })),
                Toggle::make('is_active')->label('Active')->helperText('Off: cannot sign in, cannot be put on a truck')->default(true),
            ]),
            Text::make(new HtmlString('<span class="ds-cr__where">📍 Added to '.e($this->hubName()).'. Only your '.(Filament::getCurrentPanel()?->getId() === 'company' ? 'hub' : 'warehouse').' sees them.</span>')),
        ];
    }

    protected function driverApp($positionId): bool
    {
        return $positionId ? People::usesDriverApp(Workposition::with('panelcategory')->find((int) $positionId)) : false;
    }

    protected function hubName(): string
    {
        return (string) (\App\Models\Logistichub::whereKey($this->hub())->value('hub_name') ?? 'your hub');
    }

    protected function saveCrew(array $data, ?User $user): User
    {
        $pos = Workposition::find((int) $data['workposition_id']);
        $u = Auth::user();
        $user ??= new User;
        $email = trim((string) ($data['email'] ?? ''));
        $user->forceFill([
            'first_name' => trim($data['first_name']), 'last_name' => trim($data['last_name']), 'mobile_number' => trim($data['mobile_number']),
            'workposition_id' => $pos?->id, 'is_active' => (bool) ($data['is_active'] ?? true), 'is_crew' => true,
        ]);
        if (! $user->exists) {
            $user->forceFill([
                'middle_name' => null, 'address' => '', 'is_admin' => false,
                'logistichub_id' => $this->hub(), 'company_id' => $u->company_id, 'warehouse_id' => $u->warehouse_id,
                'panelcategory_id' => $pos?->panelcategory_id ?? $u->panelcategory_id,
                // a helper without sign-in still needs a unique email: one that cannot receive mail
                'email' => $email ?: Str::slug($data['first_name'].'-'.$data['last_name']).'-'.Str::lower(Str::random(5)).'@crew.invalid',
                'password' => Hash::make(filled($data['password'] ?? null) ? $data['password'] : Str::random(32)),
            ]);
        } else {
            if ($email !== '') {
                $user->email = $email;
            }
            if (filled($data['password'] ?? null)) {
                $user->password = Hash::make($data['password']);
            }
            if ($pos?->panelcategory_id) {
                $user->panelcategory_id = $pos->panelcategory_id;
            }
        }
        $user->save();
        $this->cache = [];

        $truck = (int) ($data['truck_id'] ?? 0);
        $now = $this->onTruck()[$user->id] ?? null;
        if (! $user->is_active || ! $truck) {
            if ($now) {
                $this->removeFromTruck($now, $user->id);
            }
        } elseif ($truck !== $now) {
            $this->addToTruck($truck, $user->id);
        }

        return $user;
    }

    public function newCrewAction(): Action
    {
        return Action::make('newCrew')->label('New crew member')->icon('heroicon-m-plus')
            ->slideOver()->modalWidth('xl')->modalHeading('Add crew')->modalDescription('Only a name, mobile and position are needed.')
            ->modalSubmitActionLabel('Add crew member')
            ->schema(fn () => $this->crewSchema(null))
            ->action(function (array $data) {
                $u = $this->saveCrew($data, null);
                Notification::make()->title(People::name($u).' added')->success()->send();
            });
    }

    public function editCrewAction(): Action
    {
        return Action::make('editCrew')
            ->slideOver()->modalWidth('xl')->modalSubmitActionLabel('Save changes')
            ->modalHeading(fn (array $arguments) => ($u = $this->member($arguments['id'] ?? 0)) ? People::name($u) : 'Crew member')
            ->modalDescription(fn (array $arguments) => ($u = $this->member($arguments['id'] ?? 0))
                ? ($u->workposition?->position_description ?? 'Crew').' · '.(($t = $this->onTruck()[$u->id] ?? null) ? 'on '.$this->trucks()->firstWhere('id', $t)?->plate_no : 'no truck') : null)
            ->fillForm(fn (array $arguments) => ($u = $this->member($arguments['id'] ?? 0)) ? [
                'first_name' => People::nice($u->first_name), 'last_name' => People::nice($u->last_name), 'mobile_number' => $u->mobile_number,
                'workposition_id' => $u->workposition_id, 'truck_id' => $this->onTruck()[$u->id] ?? null,
                'email' => str_ends_with((string) $u->email, '@crew.invalid') ? null : $u->email, 'is_active' => (bool) $u->is_active,
            ] : [])
            ->schema(fn (array $arguments) => $this->crewSchema($this->member($arguments['id'] ?? 0)))
            ->action(function (array $data, array $arguments) {
                if ($u = $this->member($arguments['id'] ?? 0)) {
                    $this->saveCrew($data, $u);
                    Notification::make()->title('Saved')->success()->send();
                }
            });
    }

    protected function member(int $id): ?User
    {
        return User::with('workposition')->where('is_crew', true)->where('logistichub_id', $this->hub() ?? 0)->find($id);
    }

    // ------------------------------------------------------------------ view

    protected function getViewData(): array
    {
        $people = $this->people();
        $on = $this->onTruck();
        $card = fn (User $u) => ['id' => $u->id, 'name' => People::name($u), 'ini' => People::initials($u), 'av' => People::colour($u),
            'pos' => $u->workposition?->position_description ?? 'Crew', 'app' => People::usesDriverApp($u->workposition), 'mobile' => $u->mobile_number,
            'pic' => $u->profile_picture ? \Illuminate\Support\Facades\Storage::disk('public')->url($u->profile_picture) : null];
        $seen = People::lastActive($people->pluck('id')->all());

        return [
            'hubName' => $this->hubName(),
            'activeCount' => $people->where('is_active', true)->count(),
            'trucks' => $this->trucks()->map(function (Truck $t) use ($people, $on, $card) {
                $crew = $people->filter(fn ($u) => ($on[$u->id] ?? null) === $t->id)->values();
                $driver = $crew->contains(fn ($u) => People::usesDriverApp($u->workposition));

                return ['id' => $t->id, 'plate' => $t->plate_no, 'sub' => trim($t->category.' · '.$t->description, ' ·'),
                    'state' => $crew->isEmpty() ? 'empty' : ($driver ? 'ready' : 'nodriver'), 'crew' => $crew->map($card)->all()];
            })->all(),
            'free' => $people->filter(fn ($u) => $u->is_active && ! isset($on[$u->id]))->map($card)->values()->all(),
            'people' => $people->map(fn (User $u) => $card($u) + ['active' => (bool) $u->is_active,
                'truck' => isset($on[$u->id]) ? $this->trucks()->firstWhere('id', $on[$u->id])?->plate_no : null,
                'seen' => str_ends_with((string) $u->email, '@crew.invalid') ? 'No sign-in' : People::ago($seen[$u->id] ?? null)])->all(),
        ];
    }
}
