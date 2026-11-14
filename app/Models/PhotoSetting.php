<?php

namespace App\Models;

use Illuminate\Database\Eloquent\Model;

class PhotoSetting extends Model
{
    protected $guarded = [];

    protected function casts(): array
    {
        return ['places' => 'array', 'batch_every' => 'integer', 'keep_months' => 'integer'];
    }

    public static function current(): self
    {
        return once(fn () => static::query()->first() ?? static::create(['places' => array_fill_keys(array_keys(BoxPhoto::STEPS), true)])->refresh());
    }

    /** Photos can be added at this scan point. */
    public function allows(string $step): bool
    {
        return (bool) (($this->places ?? [])[$step] ?? true);
    }
}
