<?php

namespace App\Filament\Shared\Trips;

use App\Models\TripOverride;
use App\Support\Trips\TripRules;
use Filament\Pages\Page;
use Illuminate\Contracts\Support\Htmlable;
use Illuminate\Support\Facades\Auth;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Str;

/** Every time a trip rule was bypassed: who, why, and what the system notices. The office approves requests here. */
class OverridesPage extends Page
{
    protected string $view = 'filament.trips.overrides';

    protected static ?string $slug = 'overrides';

    protected static ?string $title = 'Overrides';

    protected static string|\BackedEnum|null $navigationIcon = 'heroicon-o-flag';

    public string $period = 'week';

    public static function canAccess(): bool
    {
        return TripRules::ready() && (bool) Auth::user();
    }

    public static function getNavigationBadge(): ?string
    {
        $n = TripRules::pendingCount();

        return $n ? (string) $n : null;
    }

    public function getHeading(): string|Htmlable
    {
        return '';
    }

    public function decide(int $id, bool $yes): void
    {
        abort_unless(TripRules::isOffice(Auth::user()), 403);
        TripRules::decide(TripOverride::where('status', 'pending')->findOrFail($id), $yes, Auth::user());
    }

    protected function getViewData(): array
    {
        $from = $this->period === 'month' ? today()->startOfMonth() : today()->startOfWeek();
        $q = TripOverride::with(['user', 'decider'])->where('created_at', '>=', $from);
        $all = (clone $q)->get();
        $byRule = $all->countBy('rule')->sortDesc();
        $byReason = $all->whereNotNull('reason')->countBy('reason')->sortDesc();
        $top = $byRule->keys()->first();
        $topReason = $top ? $all->where('rule', $top)->whereNotNull('reason')->countBy('reason')->sortDesc()->keys()->first() : null;

        // what the system notices (part 22 lets the AI act on these, with Undo)
        $learned = [];
        $full = $all->where('rule', 'truck_full')->whereNotNull('trip_id')->groupBy(fn ($o) => DB::table('deliverylogs')->join('trucks', 'trucks.id', '=', 'deliverylogs.truck_id')->where('deliverylogs.id', $o->trip_id)->value('trucks.plate_no') ?? '?');
        foreach ($full as $plate => $g) {
            if ($plate !== '?' && $g->count() >= 3) {
                $learned[] = $plate.' took more than its space '.$g->count().' times: its space may be bigger than set.';
            }
        }
        foreach ($byReason as $reason => $n) {
            if ($n >= 3 && ! Str::contains(Str::lower($reason), ['other', 'still fits'])) {
                $learned[] = '“'.$reason.'” '.$n.' times '.($this->period === 'month' ? 'this month' : 'this week').'.';
            }
        }

        return [
            'rows' => (clone $q)->orderByRaw("case status when 'pending' then 0 else 1 end")->latest('id')->limit(60)->get(),
            'tiles' => [
                ['Bypasses '.($this->period === 'month' ? 'this month' : 'this week'), $all->where('status', '!=', 'pending')->count(), $all->map(fn ($o) => $o->trip_number ?: $o->trip_id)->filter()->unique()->count().' trips, '.$all->pluck('user_id')->filter()->unique()->count().' people', false],
                ['Waiting for the office', TripRules::pendingCount(), 'office-only rules', TripRules::pendingCount() > 0],
                ['Most bypassed', $top ? TripRules::RULES[$top][0] : '—', $top ? $byRule[$top].' times'.($topReason ? ' · “'.$topReason.'”' : '') : 'nothing yet', false],
                ['Refused', $all->where('status', 'refused')->count(), 'by the office', false],
            ],
            'byReason' => $byReason->take(6), 'max' => max(1, $byReason->max() ?? 1),
            'learned' => $learned, 'office' => TripRules::isOffice(Auth::user()), 'rules' => TripRules::RULES,
        ];
    }
}
