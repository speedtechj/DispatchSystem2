<?php

namespace App\Models;

use Illuminate\Database\Eloquent\Model;
use Illuminate\Support\Facades\Schema;
use Illuminate\Support\Facades\Storage;
use Throwable;

/**
 * The uploaded favicon, the Driver and Scan app icons and their names on the phone (a single row).
 * Files live on the public disk under "brand/".
 */
class BrandAsset extends Model
{
    protected $fillable = ['favicon', 'app_icon', 'scan_icon', 'driver_label', 'scan_label'];

    /** The row, or null before the migration ran / before anything was uploaded. Looked up once per request. */
    public static function current(): ?self
    {
        return once(function (): ?self {
            try {
                return Schema::hasTable('brand_assets') ? static::query()->first() : null;
            } catch (Throwable) {
                return null;
            }
        });
    }

    /** Which column holds the uploaded icon / the name of each installable app. */
    public const ICON_FIELDS = ['delivery' => 'app_icon', 'scan' => 'scan_icon'];

    public const LABEL_FIELDS = ['delivery' => 'driver_label', 'scan' => 'scan_label'];

    public static function fileUrl(?string $path): ?string
    {
        return filled($path) && Storage::disk('public')->exists($path)
            ? Storage::disk('public')->url($path)
            : null;
    }
}
