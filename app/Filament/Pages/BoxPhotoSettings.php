<?php

namespace App\Filament\Pages;

use App\Models\BoxPhoto;
use App\Models\PhotoSetting;
use BackedEnum;
use Filament\Notifications\Notification;
use Filament\Pages\Page;
use Filament\Support\Icons\Heroicon;
use Illuminate\Support\Facades\Auth;
use UnitEnum;

/** Admin → Settings → Box photos: where staff can add photos, batch reminder, how long to keep them. */
class BoxPhotoSettings extends Page
{
    protected string $view = 'filament.pages.box-photo-settings';

    protected static string|UnitEnum|null $navigationGroup = 'Settings';

    protected static string|BackedEnum|null $navigationIcon = Heroicon::OutlinedCamera;

    protected static ?string $navigationLabel = 'Box photos';

    protected static ?string $title = 'Box photos';

    protected static ?string $slug = 'box-photo-settings';

    /** @var array<string, bool> */
    public array $places = [];

    public int $batchEvery = 0;

    public int $keepMonths = 6;

    public static function canAccess(): bool
    {
        return (bool) Auth::user()?->hasRole('super_admin');
    }

    public function getSubheading(): ?string
    {
        return 'Photos are always optional. Scanning never waits for a photo.';
    }

    public function mount(): void
    {
        $s = PhotoSetting::current();
        foreach (array_keys(BoxPhoto::STEPS) as $step) {
            $this->places[$step] = $s->allows($step);
        }
        $this->batchEvery = $s->batch_every;
        $this->keepMonths = $s->keep_months;
    }

    public function save(): void
    {
        $this->validate(['batchEvery' => 'required|integer|min:0|max:500', 'keepMonths' => 'required|integer|min:0|max:120']);

        PhotoSetting::current()->update([
            'places' => array_map('boolval', array_intersect_key($this->places, BoxPhoto::STEPS)),
            'batch_every' => $this->batchEvery,
            'keep_months' => $this->keepMonths,
        ]);

        Notification::make()->title('Box photo settings saved')->success()->send();
    }

    protected function getViewData(): array
    {
        return [
            'steps' => BoxPhoto::STEPS,
            'count' => BoxPhoto::count(),
            'bytes' => (int) BoxPhoto::sum('size'),
            'byStep' => BoxPhoto::selectRaw('step, count(*) as n')->groupBy('step')->pluck('n', 'step'),
        ];
    }
}
