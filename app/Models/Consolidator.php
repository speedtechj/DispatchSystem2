<?php

namespace App\Models;

use Illuminate\Database\Eloquent\Model;

class Consolidator extends Model
{
    protected $casts = [
        'company_document' => 'array',
        'logo' => 'array',
    ];

    //
    /** @var array<string, string>|null company name per code, loaded once per request */
    protected static ?array $namesByCode = null;

    /**
     * Company name for an invoice's location code. All consolidators are loaded
     * once per request, so tables can call this for every row without extra queries.
     */
    public static function nameForCode(?string $code): ?string
    {
        if (blank($code)) {
            return null;
        }

        static::$namesByCode ??= static::query()->pluck('company_name', 'code')->all();

        return static::$namesByCode[$code] ?? null;
    }

    public static function flushNameCache(): void
    {
        static::$namesByCode = null;
    }

    protected static function booted(): void
    {
        static::saved(fn () => static::flushNameCache());
        static::deleted(fn () => static::flushNameCache());
    }

    public function user()
    {
        return $this->belongsTo(User::class);
    }
}
