<?php

namespace App\Models\Boxes;

use App\Support\BoxSizes;
use Illuminate\Database\Eloquent\Model;

/** One box type from the manifests and the truck space it takes (normal box = 1). */
class BoxSize extends Model
{
    protected $table = 'box_sizes';

    protected $guarded = [];

    protected function casts(): array
    {
        return ['spellings' => 'array', 'kept_apart' => 'array', 'space' => 'float', 'is_base' => 'boolean', 'is_set' => 'boolean'];
    }

    protected static function booted(): void
    {
        static::saved(fn () => BoxSizes::forget());
        static::deleted(fn () => BoxSizes::forget());
    }
}
