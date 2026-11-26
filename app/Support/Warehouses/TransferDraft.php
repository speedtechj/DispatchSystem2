<?php

namespace App\Support\Warehouses;

use App\Models\User;
use App\Support\Ai\Ai;
use App\Support\Ai\AiUnavailable;
use App\Support\Ai\TripPlanner;
use App\Support\BoxSizes;
use Illuminate\Support\Carbon;
use Illuminate\Support\Collection;
use Illuminate\Support\Str;

/**
 * Transfers to warehouses: the manual groups (one per warehouse, with the space they need)
 * and the "Ask the AI" draft (trucks by space, a second truck when one is not enough).
 * The AI only orders the places onto the trucks; TripPlanner::fill keeps the rules:
 * a receiver is never split, a truck is never filled over its space, free trucks of your hub only.
 */
class TransferDraft
{
    public function __construct(public readonly User $user, public readonly int $here) {}

    public function planner(): TripPlanner
    {
        return new TripPlanner($this->user, 'transfer', $this->here);
    }

    /** Waiting boxes here: id => [home warehouse, days waiting]. */
    public function boxes(): Collection
    {
        return Coverage::waitingTransfer($this->here)->mapWithKeys(fn ($x) => [$x['inv']->id => [
            'home' => (int) $x['home'],
            'days' => (int) floor(Carbon::parse($x['inv']->verified_at ?? $x['inv']->created_at)->diffInHours(now()) / 24),
        ]]);
    }

    /** Receivers waiting here, each with its home warehouse and days waiting. */
    public function units(): Collection
    {
        $boxes = $this->boxes();

        return $this->planner()->units()
            ->map(fn ($u) => $u + [
                'home' => (int) ($boxes[$u['ids'][0]]['home'] ?? 0),
                'days' => (int) collect($u['ids'])->map(fn ($id) => $boxes[$id]['days'] ?? 0)->max(),
            ])
            ->filter(fn ($u) => $u['home'] && $u['home'] !== $this->here);
    }

    /** Free trucks of the hub, biggest first. */
    public function trucks(): Collection
    {
        return $this->planner()->trucks()->sortBy(fn ($t) => [-$t['capacity'], $t['plate']])->values();
    }

    /** Space, boxes and receivers going to each warehouse: dest => [...]. */
    public function needs(): Collection
    {
        return $this->units()->groupBy('home')->map(fn ($g) => [
            'space' => BoxSizes::half($g->sum('space')), 'boxes' => $g->sum('n'), 'receivers' => $g->count(),
        ]);
    }

    /** The smallest free truck that fits $space, else the biggest. */
    public function bestTruck(float $space, Collection $trucks): ?array
    {
        return $trucks->sortBy('capacity')->first(fn ($t) => $t['capacity'] >= $space) ?? $trucks->first();
    }

    /**
     * The draft: trips (dest, truck_id, places with receiver keys, load, why), boxes left, a note.
     *
     * @return array{trips: list<array>, left: int, leftSpace: float, note: string, ai: bool}
     */
    public function make(): array
    {
        $units = $this->units();
        $trucks = $this->trucks();
        if ($units->isEmpty()) {
            return ['trips' => [], 'left' => 0, 'leftSpace' => 0, 'note' => 'No boxes here belong to another warehouse.', 'ai' => false];
        }
        if ($trucks->isEmpty()) {
            return ['trips' => [], 'left' => $units->sum('n'), 'leftSpace' => $units->sum('space'), 'note' => 'No free trucks. Release a truck from a finished trip first.', 'ai' => false];
        }

        $planner = $this->planner();
        $trips = [];
        $usedAi = false;
        $why = '';
        // the warehouse with the most to carry picks its trucks first
        foreach ($units->groupBy('home')->sortByDesc(fn ($g) => $g->sum('space')) as $dest => $g) {
            $free = $trucks->reject(fn ($t) => collect($trips)->contains('truck_id', $t['id']))->values();
            if ($free->isEmpty()) {
                break;
            }
            $places = $g->groupBy(fn ($u) => TripPlanner::placeKey($u))->map(fn ($p, $k) => [
                'place' => $k, 'boxes' => $p->sum('n'), 'space' => $p->sum('space'), 'priority' => $p->sum('prio'),
                'tried_before' => $p->sum('retry'), 'oldest_days' => $p->max('days'), 'biggest_receiver' => $p->max('space'),
            ])->sortBy(fn ($p) => [-($p['priority'] + $p['tried_before']), -$p['oldest_days'], $p['place']])->values();

            [$plan, $ai, $why] = $this->plan((int) $dest, $places, $free);
            $usedAi = $usedAi || $ai;
            $res = $planner->fill($plan, $g, $free, '', $ai);
            foreach ($res['trips'] as $t) {
                $trips[] = ['dest' => (int) $dest, 'truck_id' => $t['truck_id'], 'places' => $t['places'], 'load' => BoxSizes::half($t['load']), 'why' => $t['why'] ?: $why, 'made' => null];
            }
        }

        $planned = collect($trips)->flatMap(fn ($t) => collect($t['places'])->flatMap(fn ($p) => $p['units']))->flip();
        $left = $units->reject(fn ($u) => isset($planned[$u['key']]));
        $perDest = collect($trips)->countBy('dest');
        $note = collect($perDest)->map(fn ($n, $d) => Coverage::name((int) $d).': '.$n.' '.Str::plural('truck', $n))->join(', ');
        $note = count($trips).' transfer '.Str::plural('trip', count($trips)).' for '.($units->sum('n') - $left->sum('n')).' boxes ('.$note.').'
            .($left->isNotEmpty() ? ' '.$left->sum('n').' '.Str::plural('box', $left->sum('n')).' wait for the next truck.' : '')
            .($usedAi ? '' : ' Made without AI: biggest truck first, priority and oldest boxes first.');

        return ['trips' => $trips, 'left' => (int) $left->sum('n'), 'leftSpace' => BoxSizes::half($left->sum('space')), 'note' => $note, 'ai' => $usedAi];
    }

    /** Which places go on which truck: the AI when it is on, else in order (priority, oldest) onto the biggest trucks. */
    protected function plan(int $dest, Collection $places, Collection $trucks): array
    {
        if (Ai::enabled('trips')) {
            try {
                $out = Ai::json('trips',
                    'You plan transfer trucks from one warehouse to another warehouse ('.Coverage::name($dest).') for a Philippine balikbayan box cargo company. '
                    .'Put the places onto the free trucks. Each truck has a capacity in space (a normal box is 1, bigger boxes take more): '
                    .'the total "space" of the places on a truck must not go over its capacity. Use as few trucks as you can, bigger trucks first. '
                    .'Places with priority, tried-before or the oldest boxes go first; keep places of the same province on the same truck when you can. '
                    .'You may leave places out when there is no room (they wait for the next transfer). Use each truck at most once. '
                    .'Return {"trips": [{"truck_id": id, "places": ["exact place text", ...], "why": "one short reason"}]}.',
                    json_encode(['places' => $places, 'trucks' => $trucks->map(fn ($t) => ['truck_id' => $t['id'], 'plate' => $t['plate'], 'capacity' => $t['capacity']])], JSON_UNESCAPED_UNICODE),
                    'smart', 2000);
                $plan = collect($out['trips'] ?? [])->map(fn ($t) => [
                    'truck_id' => (int) ($t['truck_id'] ?? 0), 'dest' => $dest,
                    'places' => array_values(array_filter((array) ($t['places'] ?? []), 'is_string')), 'why' => Str::limit((string) ($t['why'] ?? ''), 160),
                ])->filter(fn ($t) => $t['places'])->values()->all();
                if ($plan) {
                    return [$plan, true, ''];
                }
            } catch (AiUnavailable) {
                // falls back to the plan in order below
            }
        }

        $plan = [];
        $ti = 0;
        $load = 0;
        // a place bigger than the room left goes on this truck and the next (its receivers are never split: fill keeps them whole)
        foreach ($places as $p) {
            $rest = (float) $p['space'];
            while ($rest > 0 && $ti < $trucks->count()) {
                $room = $trucks[$ti]['capacity'] - $load;
                if ($room <= 0) {
                    $ti++;
                    $load = 0;

                    continue;
                }
                $plan[$ti] ??= ['truck_id' => $trucks[$ti]['id'], 'dest' => $dest, 'places' => [], 'why' => ''];
                $plan[$ti]['places'][] = $p['place'];
                $take = min($room, $rest);
                $load += $take;
                $rest -= $take;
            }
        }
        $n = count($plan);
        foreach ($plan as $i => &$t) {
            $t['why'] = $n === 1 ? 'One truck is enough for '.Coverage::name($dest).'.'
                : ($i === 0 ? 'Priority and the oldest boxes go first, on the biggest truck.' : 'The rest did not fit truck '.$i.', so another truck.');
        }

        return [array_values($plan), false, ''];
    }

    /** Rows for a draft trip: province, boxes, oldest days, priority. */
    public function rows(array $trip, Collection $units): Collection
    {
        $keys = collect($trip['places'])->flatMap(fn ($p) => $p['units']);

        return $units->only($keys->all())->groupBy('province')->map(fn ($g, $prov) => [
            'name' => $prov, 'n' => $g->sum('n'), 'days' => $g->max('days'), 'prio' => $g->sum('prio'),
        ])->sortByDesc('n')->values();
    }
}
