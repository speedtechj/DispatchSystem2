<?php

namespace App\Support\Boards;

use Illuminate\Support\Carbon;
use Illuminate\Support\Collection;

/**
 * Shared shape for the list-page widgets (Containers, Vehicles, Invoice Issue):
 * a row of cards, a "Needs attention" list, and up to two charts.
 * Rendered by App\Filament\Shared\Widgets\ModuleBoard.
 */
abstract class Board
{
    /** @return list<array{label: string, value: string, sub: string, tone: string, pct?: ?int, alert?: bool}> */
    abstract public function cards(): array;

    /** @return Collection<int, array{tag: string, tone: string, title: string, sub?: ?string, detail: string, meta?: ?string, url?: ?string, action?: ?string, primary?: bool}> */
    public function attention(): Collection
    {
        return collect();
    }

    /** @return list<array{type: string, title: string, note: string, rows: Collection, tone?: string, empty: string}> */
    public function charts(): array
    {
        return [];
    }

    /** @return Collection<int, array{url: string, title: string, label: string, meta: string}> */
    public function photos(): Collection
    {
        return collect();
    }

    public function photosTitle(): string
    {
        return 'Latest';
    }

    protected static function card(string $label, int|float|string $value, string $sub, string $tone, ?int $pct = null, bool $alert = false): array
    {
        return [
            'label' => $label,
            'value' => is_numeric($value) ? number_format((float) $value, is_float($value) ? 1 : 0) : $value,
            'sub' => $sub,
            'tone' => $tone,
            'pct' => $pct,
            'alert' => $alert,
        ];
    }

    /** Fill in missing days with zero, oldest first. @param  Collection<string, int>  $counts  keyed by Y-m-d */
    protected static function lastDays(Collection $counts, int $days = 14): Collection
    {
        $from = today()->subDays($days - 1);

        return collect(range(0, $days - 1))->map(function (int $offset) use ($from, $counts) {
            $date = $from->copy()->addDays($offset);

            return ['date' => $date, 'boxes' => (int) ($counts[$date->toDateString()] ?? 0)];
        });
    }

    protected static function pct(int|float $part, int|float $whole): ?int
    {
        return $whole > 0 ? (int) round($part / $whole * 100) : null;
    }

    protected static function shortDate(?string $date): string
    {
        return $date ? Carbon::parse($date)->format('M j') : '';
    }
}
