<x-filament-widgets::widget>
    <div class="ds-co__today ds-co__today--even">
        <section class="ds-board__panel">
            <div class="ds-board__panel-head">
                <h2>Delivered this week</h2>
                <span>{{ number_format($total) }} {{ str('box')->plural($total) }}{{ $best ? ' · best day '.$best : '' }}</span>
            </div>
            <div class="ds-board__chart" role="img" aria-label="Delivered per day: {{ $week->map(fn ($d) => $d['date']->format('D').' '.$d['boxes'])->join(', ') }}">
                @foreach ($week as $day)
                    <span class="ds-board__col">
                        <span class="ds-board__col-n">{{ $day['boxes'] ?: '' }}</span>
                        <span @class(['ds-board__col-bar', 'is-today' => $day['date']->isToday(), 'is-zero' => ! $day['boxes']]) style="height: {{ max(2, round($day['boxes'] / $max * 120)) }}px"></span>
                        <span class="ds-board__col-day">{{ $day['date']->isToday() ? 'Today' : $day['date']->format('D') }}</span>
                    </span>
                @endforeach
            </div>
        </section>

        <section class="ds-board__panel">
            <div class="ds-board__panel-head"><h2>Your hub score</h2><span>Last 30 days</span></div>
            @php($rows = [
                ['First-try success', $score['firstTry'] !== null ? $score['firstTry'].'%' : '—', $score['firstTry'], $score['network'] !== null ? 'Whole network '.$score['network'].'%' : 'No deliveries yet', ($score['firstTry'] ?? 0) >= ($score['network'] ?? 0) ? 'ok' : 'warn'],
                ['Delivered within '.\App\Support\HubDesk::WAIT_DAYS.' days of arrival', $score['onTime'] !== null ? $score['onTime'].'%' : '—', $score['onTime'], 'Arrival = the main trip\'s ETA', ($score['onTime'] ?? 0) >= 85 ? 'ok' : 'warn'],
                ['Average wait before a trip', $score['wait'] !== null ? round($score['wait'], 1).' days' : '—', $score['wait'] !== null ? max(5, 100 - $score['wait'] * 20) : null, $score['waitBefore'] !== null ? 'Month before: '.round($score['waitBefore'], 1).' days' : 'From arrival to your trip leaving', 'teal'],
            ])
            @foreach ($rows as [$label, $value, $pct, $sub, $tone])
                <div class="ds-board__reason">
                    <span class="ds-board__reason-row"><span>{{ $label }}</span><strong>{{ $value }}</strong></span>
                    <span class="ds-board__bar"><span class="ds-board__bar-fill ds-board__bar-fill--{{ $tone }}" style="width: {{ $pct ?? 0 }}%"></span></span>
                    <span class="ds-board__muted">{{ $sub }}</span>
                </div>
            @endforeach
        </section>
    </div>
</x-filament-widgets::widget>
