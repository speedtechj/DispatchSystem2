<?php

namespace App\Models;

use Illuminate\Database\Eloquent\Model;

class OfflineSubmission extends Model
{
    protected $guarded = [];

    protected function casts(): array
    {
        return ['payload' => 'array', 'happened_at' => 'datetime'];
    }
}
