<?php

namespace App\Filament\Pages;

use App\Models\AppSetting;
use App\Models\BrandAsset;
use App\Support\Pwa;
use BackedEnum;
use Filament\Actions\Action;
use Filament\Forms\Components\FileUpload;
use Filament\Forms\Components\TextInput;
use Filament\Notifications\Notification;
use Filament\Pages\Page;
use Filament\Schemas\Components\Actions;
use Filament\Schemas\Components\Form;
use Filament\Schemas\Components\Section;
use Filament\Schemas\Schema;
use Filament\Support\Icons\Heroicon;
use Illuminate\Support\Facades\Auth;
use Illuminate\Support\Facades\Storage;
use Illuminate\Support\Str;
use Livewire\Features\SupportFileUploads\TemporaryUploadedFile;
use UnitEnum;

/**
 * Upload the browser tab icon (all panels), and the name and icon of the Driver and Scan apps.
 * Both take effect straight away: the files get new names, so browsers and
 * phones see new links. Android then offers drivers the icon update; iPhone
 * keeps the icon it saved when the app was added (remove and add it again).
 */
class AppIcons extends Page
{
    protected string $view = 'filament.pages.app-icons';

    protected static string|UnitEnum|null $navigationGroup = 'Settings';

    protected static string|BackedEnum|null $navigationIcon = Heroicon::OutlinedDevicePhoneMobile;

    protected static ?string $navigationLabel = 'App icon & favicon';

    protected static ?string $title = 'App icon & favicon';

    protected static ?string $slug = 'app-icons';

    public ?array $data = [];

    /** Install QR codes: the online address phones open (empty = the app's own address, APP_URL). */
    public string $installBase = '';

    public static function canAccess(): bool
    {
        return (bool) Auth::user()?->hasRole('super_admin');
    }

    public function mount(): void
    {
        $this->form->fill(BrandAsset::current()?->only(['favicon', 'app_icon', 'scan_icon', 'driver_label', 'scan_label']) ?? []);
        $this->installBase = (string) AppSetting::get('install.base_url', '');
    }

    public function saveInstallBase(): void
    {
        $this->installBase = rtrim(trim($this->installBase), '/');
        $this->validate(['installBase' => ['nullable', 'url:http,https', 'max:200']], ['installBase.url' => 'Type the full address, for example https://app.icargoxpress.net']);
        AppSetting::put('install.base_url', $this->installBase ?: null);
        Notification::make()->title($this->installBase ? 'The QR codes now use '.$this->installBase : 'The QR codes use the app\'s own address again')->success()->send();
    }

    public function getSubheading(): ?string
    {
        return 'The favicon shows in the browser tab of every panel. Each phone app (Driver and Scan) can have its own name and icon.';
    }

    protected static function uniqueName(string $prefix): \Closure
    {
        return fn (TemporaryUploadedFile $file): string => $prefix.'-'.Str::lower(Str::random(8)).'.'.strtolower($file->getClientOriginalExtension());
    }

    public function form(Schema $schema): Schema
    {
        return $schema
            ->statePath('data')
            ->components([
                Form::make([
                    Section::make('Favicon')
                        ->description('Square, at least 32 × 32 px. PNG, ICO or SVG.')
                        ->icon(Heroicon::OutlinedWindow)
                        ->schema([
                            FileUpload::make('favicon')
                                ->hiddenLabel()
                                ->disk('public')
                                ->directory('brand')
                                ->visibility('public')
                                ->acceptedFileTypes(['image/png', 'image/x-icon', 'image/vnd.microsoft.icon', 'image/svg+xml', 'image/webp'])
                                ->maxSize(512)
                                ->getUploadedFileNameForStorageUsing(static::uniqueName('favicon')),
                        ]),
                    static::appSection('delivery', 'Driver app', 'app_icon', 'driver_label', 'app-icon', 'Speedtech Driver'),
                    static::appSection('scan', 'Scan app', 'scan_icon', 'scan_label', 'scan-icon', 'Speedtech Scan'),
                ])
                    ->columns(2)
                    ->livewireSubmitHandler('save')
                    ->footer([
                        Actions::make([
                            Action::make('save')->label('Save')->submit('save'),
                        ]),
                    ]),
            ]);
    }

    /** Name on the phone + icon for one installable app. */
    protected static function appSection(string $panel, string $title, string $iconField, string $labelField, string $prefix, string $example): Section
    {
        return Section::make($title)
            ->description('The name and icon on the phone\'s home screen. Leave them empty to use "'.Pwa::shortCompany().' '.Pwa::app($panel)['label'].'" and the icon drawn from your company logo.')
            ->icon(Heroicon::OutlinedDevicePhoneMobile)
            ->schema([
                TextInput::make($labelField)
                    ->label('Name on the phone')
                    ->placeholder($example)
                    ->maxLength(30)
                    ->helperText('Up to 30 letters; phones show about 12 under the icon.'),
                FileUpload::make($iconField)
                    ->label('Icon')
                    ->helperText('Square, at least 512 × 512 px, PNG or JPG. Keep the logo away from the edges: Android may show it in a circle.')
                    ->image()
                    ->disk('public')
                    ->directory('brand')
                    ->visibility('public')
                    ->acceptedFileTypes(['image/png', 'image/jpeg', 'image/webp'])
                    ->maxSize(2048)
                    ->rules(['dimensions:min_width=192,min_height=192'])
                    ->validationMessages(['dimensions' => 'The app icon must be at least 192 × 192 px (512 × 512 px looks best).'])
                    ->getUploadedFileNameForStorageUsing(static::uniqueName($prefix)),
            ]);
    }

    public function save(): void
    {
        $data = $this->form->getState();
        $asset = BrandAsset::current() ?? new BrandAsset;

        foreach (['favicon', 'app_icon', 'scan_icon'] as $field) {
            $old = $asset->getOriginal($field);
            if ($old && $old !== ($data[$field] ?? null)) {
                Storage::disk('public')->delete($old);
            }
        }

        $asset->fill([
            'favicon' => $data['favicon'] ?? null,
            'app_icon' => $data['app_icon'] ?? null,
            'scan_icon' => $data['scan_icon'] ?? null,
            'driver_label' => filled($data['driver_label'] ?? null) ? trim($data['driver_label']) : null,
            'scan_label' => filled($data['scan_label'] ?? null) ? trim($data['scan_label']) : null,
        ])->save();

        Notification::make()
            ->title('Saved')
            ->body('Reload a page to see the new favicon. On Android, the Driver and Scan apps get the new name and icon the next time they are opened.')
            ->success()
            ->send();

        $this->redirect(static::getUrl());
    }

    protected function getViewData(): array
    {
        return [
            'installAuto' => (string) config('app.url'),
            'faviconUrl' => Pwa::faviconUrl(),
            'apps' => collect(['delivery', 'scan'])->map(fn ($p) => [
                'icon' => url("/pwa/{$p}/icon-192.png?v=".Pwa::version()),
                'name' => Pwa::name($p),
                'what' => $p === 'delivery' ? 'Driver app' : 'Scan app',
            ])->all(),
        ];
    }
}
