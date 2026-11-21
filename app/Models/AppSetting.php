<?php

namespace App\Models;

use Illuminate\Database\Eloquent\Model;
use Illuminate\Support\Facades\Cache;
use Illuminate\Support\Facades\Schema;

/** Small settings changed in Admin, read with AppSetting::get('key', default). */
class AppSetting extends Model
{
    protected $table = 'app_settings';

    protected $fillable = ['key', 'value'];

    protected static ?array $memo = null;

    /** The app the memo belongs to (a new app per test or per worker restart starts clean). */
    protected static ?int $memoApp = null;

    public static function get(string $key, mixed $default = null): mixed
    {
        if (static::$memoApp !== spl_object_id(app())) {
            static::$memoApp = spl_object_id(app());
            static::$memo = null;
        }
        $all = static::$memo ??= Cache::remember('app.settings', 600, fn () => Schema::hasTable('app_settings') ? static::pluck('value', 'key')->all() : []);

        return array_key_exists($key, $all) && $all[$key] !== null ? $all[$key] : $default;
    }

    public static function put(string $key, mixed $value): void
    {
        static::updateOrCreate(['key' => $key], ['value' => $value]);
        Cache::forget('app.settings');
        static::$memo = null;
    }
}
