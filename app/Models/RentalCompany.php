<?php

namespace App\Models;

use Illuminate\Database\Eloquent\Model;
use Illuminate\Database\Eloquent\Relations\HasMany;

/** A company you rent trucks from. */
class RentalCompany extends Model
{
    protected $guarded = [];

    public function trucks(): HasMany
    {
        return $this->hasMany(Truck::class);
    }
}
