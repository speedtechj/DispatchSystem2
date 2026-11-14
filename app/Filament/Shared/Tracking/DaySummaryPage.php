<?php

namespace App\Filament\Shared\Tracking;

use App\Support\Ai\Ai;
use App\Support\Tracking\DaySummary;
use BackedEnum;
use Filament\Notifications\Notification;
use Filament\Pages\Page;
use Filament\Support\Icons\Heroicon;
use Illuminate\Support\Carbon;
use Illuminate\Support\Facades\Auth;
use Livewire\Attributes\Url;

/** Trucks · end of day: the day in short, and each truck with its grade and summary. */
abstract class DaySummaryPage extends Page
{
    use TracksTrucks;

    protected string $view = 'filament.tracking.day';

    protected static string|BackedEnum|null $navigationIcon = Heroicon::OutlinedDocumentChartBar;

    protected static ?string $navigationLabel = 'Trucks · end of day';

    protected static ?string $title = 'Trucks · end of day';

    protected static ?string $slug = 'truck-tracking/end-of-day';

    protected static ?int $navigationSort = 4;

    #[Url]
    public string $day = '';

    public ?int $sel = null;

    public static function canAccess(): bool
    {
        return (bool) Auth::user();
    }

    public function mount(): void
    {
        $this->day = $this->date()->toDateString();
    }

    protected function date(): Carbon
    {
        try {
            $d = $this->day ? Carbon::parse($this->day)->startOfDay() : today();
        } catch (\Throwable) {
            $d = today();
        }

        return $d->gt(today()) ? today() : $d;
    }

    public function move(int $days): void
    {
        $this->day = $this->date()->addDays($days)->min(today())->toDateString();
        $this->sel = null;
    }

    public function write(): void
    {
        DaySummary::build($this->date(), $this->hub());
        Notification::make()->title('Summary written')->success()->send();
    }

    protected function getViewData(): array
    {
        $s = DaySummary::get($this->date(), $this->hub()) ?? DaySummary::build($this->date(), $this->hub());
        $trucks = collect($s?->data['trucks'] ?? []);

        return [
            'date' => $this->date(),
            'summary' => $s,
            'trucks' => $trucks,
            'cur' => $trucks->firstWhere('truck_id', $this->sel) ?? $trucks->first(),
            'aiOn' => Ai::enabled('day_summary'),
            'truckUrl' => fn (int $id) => static::truckPageClass()::getUrl(['truck' => $id]),
        ];
    }

    /** @return class-string<TruckPage> */
    abstract protected static function truckPageClass(): string;
}
