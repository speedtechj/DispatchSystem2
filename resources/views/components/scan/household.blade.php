@props([
    'rows' => [],          // array of ['invoice','receiver','box','trip','done']
    'doneLabel' => 'Loaded',
])

@if (count($rows) > 1)
    <div {{ $attributes->class('ds-household') }}>
        <div class="ds-household__head">
            <x-filament::icon icon="heroicon-o-home-modern" class="h-5 w-5" />
            <span>Same household — {{ count($rows) }} boxes</span>
            <span class="ds-household__sub">
                {{ collect($rows)->where('done', true)->count() }} {{ strtolower($doneLabel) }}
            </span>
        </div>
        <ul class="ds-household__list">
            @foreach ($rows as $row)
                <li @class(['is-done' => $row['done']])>
                    <x-filament::icon
                        :icon="$row['done'] ? 'heroicon-s-check-circle' : 'heroicon-o-minus-circle'"
                        class="h-5 w-5 shrink-0"
                    />
                    <span class="ds-household__invoice">{{ $row['invoice'] }}</span>
                    <span class="ds-household__box">{{ $row['box'] }}</span>
                    <span class="ds-household__trip">{{ $row['trip'] ?? 'No trip yet' }}</span>
                </li>
            @endforeach
        </ul>
    </div>
@endif
