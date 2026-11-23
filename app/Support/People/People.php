<?php

namespace App\Support\People;

use App\Models\Panelcategory;
use App\Models\User;
use App\Models\Workposition;
use Illuminate\Support\Collection;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Schema;
use Illuminate\Support\Str;

/**
 * Users and crew (board 59/60). Everything people pick comes from the database:
 * panels from Settings → Panel categories, positions from Settings → Work positions.
 * Only the look of the four known panels is set here; a new one gets a plain look.
 */
class People
{
    /** Panel code => [label, app, icon, chip background, chip text, avatar colour]. */
    public const LOOK = [
        'adm' => ['Office', 'Admin app', 'heroicon-o-building-office-2', '#e7f0fb', '#1d5fa8', '#1d6fb8'],
        'whse' => ['Warehouse', 'Warehouse + Scan app', 'heroicon-o-archive-box', '#e6f6ef', '#17895e', '#17895e'],
        'co' => ['Partner hub', 'Partner hub app', 'heroicon-o-building-storefront', '#f1eafb', '#7a4fb0', '#7a4fb0'],
        'drv' => ['Driver & crew', 'Driver app', 'heroicon-o-truck', '#fff1c2', '#7a5600', '#e2700c'],
    ];

    /** Panel codes that open an app (User::canAccessPanel). */
    public const WITH_APP = ['adm', 'whse', 'co', 'drv'];

    /** @return Collection<int, Panelcategory> */
    public static function panels(): Collection
    {
        return once(fn () => Panelcategory::query()->orderBy('id')->get());
    }

    /** @return array{label: string, app: string, icon: string, bg: string, fg: string, avatar: string} */
    public static function look(?Panelcategory $p): array
    {
        $l = static::LOOK[$p?->code ?? ''] ?? [$p ? Str::title($p->description) : 'No panel', 'No app yet', 'heroicon-o-squares-2x2', '#eef2f5', '#33424e', '#5b6b78'];

        return ['label' => $l[0], 'app' => $l[1], 'icon' => $l[2], 'bg' => $l[3], 'fg' => $l[4], 'avatar' => $l[5]];
    }

    public static function panelCode(?int $panelId): ?string
    {
        return $panelId ? static::panels()->firstWhere('id', $panelId)?->code : null;
    }

    /** Positions of a panel (and positions with no panel), from Settings → Work positions. */
    public static function positions(?int $panelId): array
    {
        return Workposition::query()
            ->when($panelId, fn ($q) => $q->where(fn ($q) => $q->where('panelcategory_id', $panelId)->orWhereNull('panelcategory_id')))
            ->orderBy('position_description')->pluck('position_description', 'id')->all();
    }

    /** Crew positions (Truck crew ticked). */
    public static function crewPositions(): Collection
    {
        return Workposition::with('panelcategory')->where('is_crew', true)->orderBy('position_description')->get();
    }

    /** The position uses the Driver app: its panel is Delivery. */
    public static function usesDriverApp(?Workposition $w): bool
    {
        return $w?->panelcategory?->code === 'drv';
    }

    /** New position from a form (admin): saved in Settings → Work positions. */
    public static function addPosition(string $name, ?int $panelId, bool $crew, int $byUserId): Workposition
    {
        $name = trim(preg_replace('/\s+/', ' ', $name));
        $have = Workposition::whereRaw('lower(position_description) = ?', [mb_strtolower($name)])
            ->where(fn ($q) => $q->where('panelcategory_id', $panelId)->orWhereNull('panelcategory_id'))->first();
        if ($have) {
            return $have;
        }
        $code = mb_strtoupper(Str::substr(preg_replace('/[^A-Za-z]/', '', $name), 0, 3)) ?: 'POS';

        return Workposition::create(['code' => $code, 'position_description' => $name, 'is_crew' => $crew, 'panelcategory_id' => $panelId, 'user_id' => $byUserId]);
    }

    /** "CANDIDO" → "Candido": names look the same however they were typed. */
    public static function nice(?string $s): string
    {
        return Str::title(Str::lower(trim((string) $s)));
    }

    public static function name(User $u, bool $middle = false): string
    {
        $m = $middle && $u->middle_name ? ' '.mb_substr(static::nice($u->middle_name), 0, 1).'.' : '';

        return trim(static::nice($u->first_name).$m.' '.static::nice($u->last_name));
    }

    public static function initials(User $u): string
    {
        return mb_strtoupper(mb_substr(trim((string) $u->first_name), 0, 1).mb_substr(trim((string) $u->last_name), 0, 1)) ?: '?';
    }

    /** Stable avatar colour per person. */
    public static function colour(User $u): string
    {
        $c = ['#1d6fb8', '#8a4bd1', '#c8372d', '#17895e', '#e2700c', '#0f8a8a', '#a0465c', '#5b6b78', '#8a6d3b'];

        return $c[crc32((string) $u->getKey()) % count($c)];
    }

    /** Last activity per user (database sessions), in one question. @param  list<int>  $ids */
    public static function lastActive(array $ids): array
    {
        if (! $ids || config('session.driver') !== 'database' || ! Schema::hasTable('sessions')) {
            return [];
        }

        return DB::table('sessions')->whereIn('user_id', $ids)->groupBy('user_id')->selectRaw('user_id, max(last_activity) as t')->pluck('t', 'user_id')->map(fn ($t) => (int) $t)->all();
    }

    public static function ago(?int $ts): string
    {
        if (! $ts) {
            return '—';
        }
        $s = now()->timestamp - $ts;

        return match (true) {
            $s < 300 => 'Online now',
            $s < 3600 => intdiv($s, 60).' min ago',
            $s < 86400 => intdiv($s, 3600).' h ago',
            default => \Illuminate\Support\Carbon::createFromTimestamp($ts)->diffForHumans(),
        };
    }

    public static function randomPassword(): string
    {
        $words = ['cargo', 'truck', 'manila', 'cebu', 'box', 'route', 'hub', 'sea'];

        return Str::ucfirst($words[array_rand($words)]).'-'.random_int(1000, 9999).'-'.Str::lower(Str::random(4));
    }
}
