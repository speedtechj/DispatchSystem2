<?php

namespace App\Models\Maps;

use Illuminate\Database\Eloquent\Model;
use Illuminate\Support\Str;

/** An address looked up on the map once and saved, so it is never paid for twice. */
class GeoPlace extends Model
{
    protected $table = 'geo_places';

    protected $guarded = [];

    protected function casts(): array
    {
        return ['lat' => 'float', 'lng' => 'float', 'suggested_lat' => 'float', 'suggested_lng' => 'float', 'exact' => 'boolean', 'suggested_at' => 'datetime'];
    }

    public static function keyFor(string $address): string
    {
        return sha1(Str::lower(Str::squish(preg_replace('/[^\pL\pN]+/u', ' ', $address))));
    }

    public function hasPin(): bool
    {
        return $this->lat !== null && $this->lng !== null;
    }
}
