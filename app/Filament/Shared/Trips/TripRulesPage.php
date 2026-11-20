<?php

namespace App\Filament\Shared\Trips;

use App\Support\Trips\TripRules;
use Filament\Pages\Page;
use Illuminate\Contracts\Support\Htmlable;
use Illuminate\Support\Facades\Auth;

/** Settings → Trip rules: who can bypass each rule, and the reasons the crew picks from. */
class TripRulesPage extends Page
{
    protected string $view = 'filament.trips.rules';

    protected static ?string $slug = 'trip-rules';

    protected static ?string $title = 'Trip rules';

    protected static string|\BackedEnum|null $navigationIcon = 'heroicon-o-scale';

    public string $newReason = '';

    public static function canAccess(): bool
    {
        return TripRules::ready() && TripRules::isOffice(Auth::user());
    }

    public function getHeading(): string|Htmlable
    {
        return '';
    }

    public function setLevel(string $rule, string $level): void
    {
        TripRules::setLevel($rule, $level);
    }

    public function toggleAutoLock(): void
    {
        \App\Support\Trips\TripLock::setAutoOnTake(! \App\Support\Trips\TripLock::autoOnTake());
    }

    public function addReason(): void
    {
        if (trim($this->newReason) !== '') {
            TripRules::setReasons(array_merge(TripRules::reasons(), [$this->newReason]));
            $this->newReason = '';
        }
    }

    public function removeReason(int $i): void
    {
        $r = TripRules::reasons();
        unset($r[$i]);
        TripRules::setReasons($r ?: TripRules::DEFAULT_REASONS);
    }

    protected function getViewData(): array
    {
        return [
            'rules' => collect(TripRules::RULES)->map(fn ($r, $k) => ['key' => $k, 'title' => $r[0], 'sub' => $r[1], 'level' => TripRules::level($k)]),
            'levels' => TripRules::LEVELS, 'reasons' => TripRules::reasons(), 'autoLock' => \App\Support\Trips\TripLock::autoOnTake(),
        ];
    }
}
