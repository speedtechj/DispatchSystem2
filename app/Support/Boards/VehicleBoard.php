<?php

namespace App\Support\Boards;

use App\Models\Truck;
use Illuminate\Database\Eloquent\Builder;
use Illuminate\Support\Carbon;
use Illuminate\Support\Collection;

/** Vehicles of one hub: active, on a trip, free, and registrations that expired or expire soon. */
class VehicleBoard extends Board
{
    public const EXPIRING_DAYS = 30;

    public function __construct(protected int $hubId, protected ?\Closure $truckUrl = null) {}

    protected function trucks(): Builder
    {
        return Truck::query()->where('logistichub_id', $this->hubId);
    }

    protected function active(): Builder
    {
        return $this->trucks()->where('is_active', true);
    }

    public function cards(): array
    {
        $active = $this->active()->count();
        $inactive = $this->trucks()->count() - $active;
        $onTrip = $this->active()->where('is_assigned', true)->count();
        $expired = $this->trucks()->whereDate('date_expired', '<', today())->count();
        $expiring = $this->trucks()->whereDate('date_expired', '>=', today())->whereDate('date_expired', '<=', today()->addDays(self::EXPIRING_DAYS))->count();

        return [
            static::card('Active vehicles', $active, $inactive ? "{$inactive} inactive" : 'All vehicles active', 'navy'),
            static::card('On a trip now', $onTrip, (static::pct($onTrip, $active) ?? 0).'% of active vehicles', 'yellow', static::pct($onTrip, $active)),
            static::card('Free', $active - $onTrip, 'Ready to assign to a trip', 'ok'),
            static::card('Registration', $expired + $expiring, "{$expired} expired · {$expiring} expire within ".self::EXPIRING_DAYS.' days', 'bad', alert: $expired > 0),
        ];
    }

    public function attention(): Collection
    {
        $items = collect();

        foreach ($this->trucks()->whereDate('date_expired', '<', today())->orderBy('date_expired')->get() as $t) {
            $items->push($this->item($t, 'Expired', 'bad',
                'Registration expired '.Carbon::parse($t->date_expired)->format('M j, Y').($t->is_assigned ? ' · on a trip now' : ''), 'Update registration', true));
        }

        foreach ($this->trucks()->whereDate('date_expired', '>=', today())->whereDate('date_expired', '<=', today()->addDays(self::EXPIRING_DAYS))->orderBy('date_expired')->get() as $t) {
            $days = (int) today()->diffInDays(Carbon::parse($t->date_expired));
            $items->push($this->item($t, $days === 0 ? 'Expires today' : "Expires in {$days} ".str('day')->plural($days), 'warn',
                'Registration expires '.Carbon::parse($t->date_expired)->format('M j, Y'), 'Open vehicle'));
        }

        foreach ($this->active()->doesntHave('truckcrews')->limit(5)->get() as $t) {
            $items->push($this->item($t, 'No crew', 'gray', 'No driver or helper assigned, so it cannot be loaded', 'Open vehicle'));
        }

        return $items->take(6)->values();
    }

    protected function item(Truck $t, string $tag, string $tone, string $detail, string $action, bool $primary = false): array
    {
        return [
            'tag' => $tag,
            'tone' => $tone,
            'title' => $t->plate_no ?: 'Vehicle #'.$t->id,
            'sub' => $t->category,
            'detail' => $detail,
            'meta' => $t->registration_no,
            'url' => $this->truckUrl ? ($this->truckUrl)($t) : null,
            'action' => $action,
            'primary' => $primary,
        ];
    }

    public function charts(): array
    {
        $byType = $this->active()
            ->selectRaw("COALESCE(NULLIF(category, ''), 'No type') as label, count(*) as n")
            ->groupBy('label')->orderByDesc('n')->limit(6)->get()
            ->map(fn ($r) => ['label' => $r->label, 'count' => (int) $r->n]);

        $due = $this->trucks()
            ->whereDate('date_expired', '>=', today())
            ->whereDate('date_expired', '<', today()->startOfMonth()->addMonths(6))
            ->pluck('date_expired')
            ->countBy(fn ($date) => Carbon::parse($date)->format('Y-m'));

        $months = collect(range(0, 5))->map(function (int $i) use ($due) {
            $month = today()->startOfMonth()->addMonths($i);

            return ['label' => $month->format('F Y'), 'count' => (int) ($due[$month->format('Y-m')] ?? 0)];
        });

        return [
            ['type' => 'bars', 'title' => 'Registrations due', 'note' => 'Not expired yet, next 6 months', 'rows' => $months, 'tone' => 'warn', 'empty' => 'No registrations due in the next 6 months.'],
            ['type' => 'bars', 'title' => 'Vehicles by type', 'note' => 'Active', 'rows' => $byType, 'tone' => 'teal', 'empty' => 'No active vehicles.'],
        ];
    }
}
