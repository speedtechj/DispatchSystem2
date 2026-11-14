<?php

namespace App\Support;

use App\Models\Companyprofile;
use Illuminate\Support\Facades\Schema;
use Illuminate\Support\Facades\Storage;
use Throwable;

/**
 * Company name and logo, taken from the Company Info page (companyprofiles table).
 * Used on the sign-in pages so changing them there updates every panel.
 */
class Branding
{
    /** Looked up once per request. */
    protected static function profile(): ?Companyprofile
    {
        return once(function (): ?Companyprofile {
            try {
                return Schema::hasTable('companyprofiles') ? Companyprofile::query()->first() : null;
            } catch (Throwable) {
                return null; // database not reachable yet: fall back to the app name
            }
        });
    }

    public static function companyName(): string
    {
        return static::profile()?->company_name ?: config('app.name', 'Dispatch');
    }

    public static function logoUrl(): ?string
    {
        $logo = static::profile()?->company_logo;
        $path = is_array($logo) ? (array_values($logo)[0] ?? null) : $logo;

        return filled($path) ? Storage::disk('public')->url($path) : null;
    }

    /** Up to two letters for when no logo has been uploaded. */
    public static function initials(): string
    {
        return collect(preg_split('/\s+/', trim(static::companyName())))
            ->filter()
            ->take(2)
            ->map(fn (string $word) => mb_strtoupper(mb_substr($word, 0, 1)))
            ->join('');
    }
}
