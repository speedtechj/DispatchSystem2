<?php

namespace App\Support;

use Illuminate\Database\Schema\Builder;

/**
 * Speed: remembers Schema::hasTable / hasColumn / hasColumns answers.
 *
 * Many screens check "is this feature's table there yet?" for every row. On MySQL each check is an
 * information_schema query. The answers are kept for the request and in bootstrap/cache/schema-memo.php,
 * and forgotten whenever migrations run, a table is created, changed or dropped, or on optimize:clear.
 * Every other Schema call goes straight to Laravel.
 */
class SchemaMemo
{
    /** @var array<string, bool> */
    protected static array $memo = [];

    protected static ?int $app = null;

    protected static bool $loaded = false;

    protected static bool $dirty = false;

    public function __construct(protected Builder $schema) {}

    public static function file(): string
    {
        return app()->bootstrapPath('cache/schema-memo.php');
    }

    protected static function useFile(): bool
    {
        return ! app()->runningUnitTests();
    }

    protected function connectionKey(): string
    {
        $c = $this->schema->getConnection();

        return $c->getName().':'.$c->getDatabaseName();
    }

    protected function remember(string $key, \Closure $ask): bool
    {
        if (static::$app !== spl_object_id(app())) {
            static::$app = spl_object_id(app());
            static::$memo = [];
            static::$loaded = false;
        }
        if (! static::$loaded) {
            static::$loaded = true;
            if (static::useFile() && is_file(static::file())) {
                $saved = @include static::file();
                static::$memo = is_array($saved) ? $saved + static::$memo : static::$memo;
            }
        }
        $key = $this->connectionKey().'|'.$key;
        if (! array_key_exists($key, static::$memo)) {
            static::$memo[$key] = (bool) $ask();
            if (static::useFile() && ! static::$dirty) {
                static::$dirty = true;
                app()->terminating(fn () => static::save());
            }
        }

        return static::$memo[$key];
    }

    public static function save(): void
    {
        if (! static::$dirty) {
            return;
        }
        static::$dirty = false;
        $tmp = static::file().'.'.getmypid();
        if (@file_put_contents($tmp, '<?php return '.var_export(static::$memo, true).';', LOCK_EX) !== false) {
            @rename($tmp, static::file());
            if (function_exists('opcache_invalidate')) {
                @opcache_invalidate(static::file(), true);
            }
        }
    }

    /** Read the saved answers again on the next check (long-running queue workers). */
    public static function reset(): void
    {
        static::$memo = [];
        static::$loaded = false;
    }

    /** Forget every answer (migrations ran, a table changed, optimize:clear). */
    public static function flush(): void
    {
        static::$memo = [];
        static::$loaded = true;
        static::$dirty = false;
        if (is_file(static::file())) {
            @unlink(static::file());
            if (function_exists('opcache_invalidate')) {
                @opcache_invalidate(static::file(), true);
            }
        }
    }

    public function hasTable($table)
    {
        return $this->remember('t:'.$table, fn () => $this->schema->hasTable($table));
    }

    public function hasColumn($table, $column)
    {
        return $this->remember('c:'.$table.'.'.strtolower($column), fn () => $this->schema->hasColumn($table, $column));
    }

    public function hasColumns($table, array $columns)
    {
        foreach ($columns as $column) {
            if (! $this->hasColumn($table, $column)) {
                return false;
            }
        }

        return true;
    }

    public function __call($method, $args)
    {
        // anything that can change tables (create, table, drop, rename, ...) forgets the answers
        if (! preg_match('/^(has|get|whenTableHas|whenTableDoesntHave|connection|getConnection)/', $method)) {
            static::flush();
        }

        return $this->schema->{$method}(...$args);
    }
}
