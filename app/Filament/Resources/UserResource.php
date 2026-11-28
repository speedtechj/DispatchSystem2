<?php

namespace App\Filament\Resources;

use App\Filament\Resources\UserResource\Pages\ListUsers;
use App\Models\Company;
use App\Models\Logistichub;
use App\Models\User;
use App\Models\Warehouse;
use App\Support\People\People;
use Filament\Actions\Action;
use Filament\Actions\BulkActionGroup;
use Filament\Actions\DeleteBulkAction;
use Filament\Actions\EditAction;
use Filament\Forms\Components\FileUpload;
use Filament\Forms\Components\Select;
use Filament\Forms\Components\TextInput;
use Filament\Forms\Components\Toggle;
use Filament\Forms\Components\ToggleButtons;
use Filament\Notifications\Notification;
use Filament\Resources\Resource;
use Filament\Schemas\Components\Grid;
use Filament\Schemas\Components\Section;
use Filament\Schemas\Components\Text;
use Filament\Schemas\Components\Utilities\Get;
use Filament\Schemas\Components\Utilities\Set;
use Filament\Schemas\Schema;
use Filament\Tables\Columns\TextColumn;
use Filament\Tables\Columns\ViewColumn;
use Filament\Tables\Table;
use Illuminate\Database\Eloquent\Builder;
use Illuminate\Support\Facades\Auth;
use Illuminate\Support\Facades\Hash;
use Illuminate\Support\HtmlString;
use Illuminate\Support\Str;
use UnitEnum;

/**
 * Users (board 59): a list with a tab per panel, and New user / Edit user in a panel on the right.
 * Panels and work positions come from Settings (Panel categories, Work positions): nothing is fixed here.
 */
class UserResource extends Resource
{
    protected static ?string $model = User::class;

    protected static string|UnitEnum|null $navigationGroup = 'Settings';

    public static function form(Schema $schema): Schema
    {
        return $schema->columns(1)->components([
            Section::make('Personal')->compact()->schema([
                FileUpload::make('profile_picture')
                    ->hiddenLabel()->image()->avatar()->imageEditor()->circleCropper()
                    ->getUploadedFileNameForStorageUsing(fn ($file, Get $get) => Str::slug($get('last_name') ?: 'user').'-'.Str::random(8).'.'.$file->getClientOriginalExtension())
                    ->maxSize(1024)->disk('public')->directory('people')->visibility('private')
                    ->extraAttributes(['class' => 'ds-us__photo']),
                Grid::make(3)->schema([
                    TextInput::make('first_name')->required()->maxLength(255),
                    TextInput::make('middle_name')->maxLength(255)->placeholder('Optional'),
                    TextInput::make('last_name')->required()->maxLength(255),
                ]),
                Grid::make(2)->schema([
                    TextInput::make('mobile_number')->label('Mobile')->tel()->maxLength(255),
                    TextInput::make('email')->label('Email · used to sign in')->email()->required()->maxLength(255)->unique(ignoreRecord: true),
                ]),
                TextInput::make('address')->required()->maxLength(255),
            ]),

            Section::make('Works in')->description('Which app they open · from Settings → Panel categories')->compact()->schema([
                ToggleButtons::make('panelcategory_id')->hiddenLabel()->required()->inline()->live()
                    ->options(fn () => People::panels()->mapWithKeys(fn ($p) => [$p->id => People::look($p)['label']])->all())
                    ->icons(fn () => People::panels()->mapWithKeys(fn ($p) => [$p->id => People::look($p)['icon']])->all())
                    ->afterStateUpdated(function (Set $set, Get $get, $state) {
                        // a position of another panel does not fit any more
                        if ($get('workposition_id') && ! array_key_exists((int) $get('workposition_id'), People::positions((int) $state))) {
                            $set('workposition_id', null);
                        }
                        if (People::panelCode((int) $state) === 'drv') {
                            $set('is_crew', true);
                            $set('is_admin', false);
                        }
                    })
                    ->extraAttributes(['class' => 'ds-us__panels']),
                Text::make(fn (Get $get) => new HtmlString('<span class="ds-us__noapp">⚠ This panel has no app yet: they can be saved, but cannot sign in anywhere.</span>'))
                    ->visible(fn (Get $get) => $get('panelcategory_id') && ! in_array(People::panelCode((int) $get('panelcategory_id')), People::WITH_APP, true)),
                Grid::make(2)->schema([
                    Select::make('logistichub_id')->label('Hub / location')->required()->searchable()
                        ->options(fn () => Logistichub::query()->orderBy('hub_name')->pluck('hub_name', 'id')->all())
                        ->helperText(fn (Get $get) => People::panelCode((int) $get('panelcategory_id')) === 'co' ? 'The partner hub: they only see its boxes and trips.' : 'Where they work. Drivers: the hub their truck goes out from.'),
                    Select::make('warehouse_id')->label('Warehouse')->searchable()
                        ->options(fn () => Warehouse::query()->orderBy('name')->pluck('name', 'id')->all())
                        ->visible(fn (Get $get) => People::panelCode((int) $get('panelcategory_id')) !== 'co'),
                    Select::make('company_id')->label('Company')->required()->searchable()
                        ->options(fn () => Company::query()->where('is_active', true)->orderBy('company_name')->pluck('company_name', 'id')->all())
                        ->default(fn () => Auth::user()?->company_id),
                ]),
                ToggleButtons::make('workposition_id')->label('Work position')->required()->inline()
                    ->hint('From Settings → Work positions')
                    // the panel's positions; a position they already have stays in the list (older data)
                    ->options(fn (Get $get, ?User $record) => People::positions($get('panelcategory_id') ? (int) $get('panelcategory_id') : null)
                        + ($record?->workposition ? [$record->workposition->id => $record->workposition->position_description] : []))
                    ->hintAction(static::newPositionAction())
                    ->extraAttributes(['class' => 'ds-us__chips']),
                Toggle::make('is_crew')->label('Truck crew')->helperText('Can be put on a truck as driver or helper')->default(false),
            ]),

            Section::make('Access')->compact()->schema([
                Toggle::make('is_active')->label('Active')->helperText('Can sign in. Off: cannot sign in, history is kept')->default(true),
                Toggle::make('is_admin')->label('Admin')
                    ->helperText(fn (Get $get) => match (People::panelCode((int) $get('panelcategory_id'))) {
                        'adm' => 'Opens the Admin app. Off: Scan app only.',
                        'drv' => 'Drivers cannot be admin: the Driver app opens only for non-admins.',
                        default => 'Full access to settings and other users',
                    })
                    ->disabled(fn (Get $get) => People::panelCode((int) $get('panelcategory_id')) === 'drv')
                    ->default(false),
                Toggle::make('can_send_status')->label('Send status manually')
                    ->helperText('Part 47: may send a box status to the consolidator by hand (a missed scan). Admins always may; drivers never.')
                    ->visible(fn (Get $get) => \Illuminate\Support\Facades\Schema::hasColumn('users', 'can_send_status') && People::panelCode((int) $get('panelcategory_id')) !== 'drv')
                    ->default(false),
                Select::make('roles')->label('Roles')->multiple()->relationship('roles', 'name')->preload(),
            ]),

            Section::make('Password')->compact()->schema([
                TextInput::make('password')
                    ->label(fn (string $operation) => $operation === 'create' ? 'Password' : 'New password · leave empty to keep it')
                    ->password()->revealable()
                    ->required(fn (string $operation) => $operation === 'create')
                    ->minLength(8)->maxLength(255)
                    ->dehydrateStateUsing(fn ($state) => Hash::make($state))
                    ->dehydrated(fn ($state) => filled($state))
                    ->hintAction(Action::make('makePassword')->label('Make one')->icon('heroicon-m-sparkles')
                        ->action(function (Set $set) {
                            $pw = People::randomPassword();
                            $set('password', $pw);
                            Notification::make()->title('Password made: '.$pw)->body('Give it to them, then press Save. Click the eye to see it.')->success()->persistent()->send();
                        })),
            ]),
        ]);
    }

    /** ＋ New position (admin): saved in Settings → Work positions for the chosen panel. */
    protected static function newPositionAction(): Action
    {
        return Action::make('newPosition')->label('＋ New position')->link()
            ->visible(fn () => (bool) Auth::user()?->is_admin)
            ->modalHeading('New work position')->modalWidth('md')->modalSubmitActionLabel('Add')
            ->schema([
                TextInput::make('name')->label('Position')->required()->maxLength(60)->placeholder('Forklift operator'),
                Toggle::make('crew')->label('Truck crew')->helperText('Shows in Crew, can be put on a truck'),
            ])
            ->action(function (array $data, Get $get, Set $set) {
                $panel = $get('panelcategory_id') ? (int) $get('panelcategory_id') : null;
                $w = People::addPosition($data['name'], $panel, (bool) ($data['crew'] ?? false), (int) Auth::id());
                $set('workposition_id', $w->id);
                Notification::make()->title($w->position_description.' added to Work positions')->success()->send();
            });
    }

    public static function table(Table $table): Table
    {
        return $table
            ->modifyQueryUsing(fn (Builder $query) => $query->with(['panelcategory', 'workposition', 'logistichub:id,hub_name', 'warehouse:id,name', 'company:id,company_name']))
            ->defaultSort('first_name')
            ->recordClasses(fn (User $r) => $r->is_active ? null : 'ds-us__off')
            ->recordAction('edit')
            ->columns([
                ViewColumn::make('person')->label('Person')->view('filament.people.user-cell')
                    ->searchable(query: fn (Builder $query, string $search) => $query->where(fn ($q) => $q
                        ->where('first_name', 'like', "%{$search}%")->orWhere('last_name', 'like', "%{$search}%")
                        ->orWhere('email', 'like', "%{$search}%")->orWhere('mobile_number', 'like', '%'.preg_replace('/\D/', '', $search).'%')))
                    ->sortable(query: fn (Builder $query, string $direction) => $query->orderBy('first_name', $direction)->orderBy('last_name', $direction)),
                ViewColumn::make('works')->label('Works as')->view('filament.people.works-cell'),
                TextColumn::make('where')->label('Where')->color('gray')
                    ->state(fn (User $r) => collect([$r->logistichub?->hub_name, $r->panelcategory?->code === 'co' ? $r->company?->company_name : $r->warehouse?->name])->filter()->unique()->join(' · ') ?: '—'),
                TextColumn::make('mobile_number')->label('Mobile')->color('gray'),
                ViewColumn::make('status')->label('Status')->view('filament.people.status-cell'),
                TextColumn::make('seen')->label('Last active')->color('gray')->size('sm')
                    ->state(fn (User $r, $livewire) => People::ago($livewire->lastActive()[$r->id] ?? null)),
            ])
            ->recordActions([
                EditAction::make()->iconButton()->slideOver()->modalWidth('2xl')
                    ->modalHeading(fn (User $r) => People::name($r))
                    ->modalDescription(fn (User $r) => 'Added '.$r->created_at?->format('M j, Y').($r->updated_at ? ' · changed '.$r->updated_at->diffForHumans() : ''))
                    ->modalSubmitActionLabel('Save changes'),
            ])
            ->toolbarActions([
                BulkActionGroup::make([
                    DeleteBulkAction::make(),
                ]),
            ]);
    }

    public static function getRelations(): array
    {
        return [];
    }

    public static function getPages(): array
    {
        // New user and Edit user open on the right of the list (board 59), not on their own page
        return [
            'index' => ListUsers::route('/'),
        ];
    }
}
