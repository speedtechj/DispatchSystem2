<?php

namespace App\Filament\Shared\Ai;

use App\Support\Ai\Ai;
use App\Support\Ai\AiFeatures;
use App\Support\Ai\AiScope;
use Filament\Pages\Page;
use Illuminate\Support\Facades\Auth;
use UnitEnum;

/** Base for the AI helper pages: shown only while the helper is switched on in Admin → Settings → AI. */
abstract class AiPage extends Page
{
    protected static string|UnitEnum|null $navigationGroup = 'AI helpers';

    /** The AiFeatures key this page belongs to. */
    protected static string $feature = '';

    public static function canAccess(): bool
    {
        return Ai::switchedOn(static::$feature) && AiScope::hubId(Auth::user()) !== false;
    }

    public static function getNavigationBadgeColor(): ?string
    {
        return 'warning';
    }

    /** A line to show when the helper is on but paused (no key, limit reached). */
    public function pausedReason(): ?string
    {
        return Ai::enabled(static::$feature) ? null : Ai::whyOff(static::$feature);
    }

    protected function hub(): ?int
    {
        $hub = AiScope::hubId(Auth::user());

        return $hub === false ? -1 : $hub;
    }

    public function getSubheading(): ?string
    {
        return AiFeatures::ALL[static::$feature][1] ?? null;
    }
}
