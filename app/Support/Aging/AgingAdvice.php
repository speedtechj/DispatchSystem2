<?php

namespace App\Support\Aging;

use App\Models\Ai\AiSetting;
use App\Support\Ai\Ai;
use App\Support\Ai\AiUnavailable;
use Illuminate\Support\Collection;
use Illuminate\Support\Facades\Cache;

/** "Why boxes are late" and "what to do today": written by the AI from the counts, or plain reasons without it. */
class AgingAdvice
{
    /**
     * @param  bool  $call  ask the AI now if there is no answer from today yet (false: only use a saved answer, so the page opens fast)
     * @return array{items: list<array{t: string, act: string}>, ai: bool, canAsk?: bool}
     */
    public static function for(Collection $rows, string $scope, bool $fresh = false, bool $call = true): array
    {
        $late = $rows->where('status', 'late');
        if ($late->isEmpty()) {
            return ['items' => [], 'ai' => false];
        }
        if (! Ai::enabled('aging') || ! AiSetting::current()->hasKey()) {
            return ['items' => BoxAging::reasons($rows), 'ai' => false];
        }
        $key = 'ai.aging.advice.'.$scope.'.'.now()->toDateString();
        if ($fresh) {
            Cache::forget($key);
        }
        if (! $call && ! Cache::has($key)) {
            return ['items' => BoxAging::reasons($rows), 'ai' => false, 'canAsk' => true];
        }

        return Cache::remember($key, now()->addHours(6), function () use ($rows, $late) {
            $group = fn ($field) => $late->groupBy($field)->map->count()->sortDesc()->take(5);
            $facts = [
                'late_boxes' => $late->count(), 'late_tomorrow' => $rows->where('tomorrow', true)->count(),
                'late_by_stage' => $late->groupBy(fn ($r) => BoxAging::STAGES[$r['stage']])->map->count(),
                'late_by_place_or_trip' => $group('where'), 'late_by_hub' => $group('hub'),
                'late_by_place' => $group(fn ($r) => $r['place'].', '.$r['province']),
                'late_by_container' => $group('container'), 'late_by_consolidator' => $group('consolidator'),
                'oldest' => collect($rows->sortByDesc('total')->first())->only(['invoice', 'name', 'place', 'total', 'stage', 'tried']),
                'limits' => BoxAging::limits(),
            ];
            try {
                $out = Ai::json('aging',
                    'You help the operations manager of a Philippine balikbayan box cargo company. From the counts of late boxes, '
                    .'give the 3 most important reasons boxes are late and one practical action for each (plan trips, unload a container, '
                    .'text receivers, call a hub or driver, send a truck to a region). Plain, short English; mention the place and the number of boxes. '
                    .'Return {"items": [{"t": "reason, max 25 words", "act": "action, max 8 words"}]}. Only use the numbers given.',
                    json_encode($facts, JSON_UNESCAPED_UNICODE), 'smart', 600);

                return ['items' => array_values(array_slice(array_filter((array) ($out['items'] ?? []), fn ($i) => ! empty($i['t'])), 0, 4)), 'ai' => true];
            } catch (AiUnavailable) {
                return ['items' => BoxAging::reasons($rows), 'ai' => false];
            }
        });
    }
}
