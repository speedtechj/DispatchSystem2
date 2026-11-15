<?php

namespace App\Models\Shipping;

use App\Models\Deliverylog;
use App\Models\Logistichub;
use Illuminate\Database\Eloquent\Model;
use Illuminate\Database\Eloquent\Relations\BelongsTo;

/** A partner hub received a truck (trip) from Manila: when, by whom, how many boxes were missing. */
class TruckReceipt extends Model
{
    protected $guarded = [];

    protected function casts(): array
    {
        return ['finished_at' => 'datetime'];
    }

    public function trip(): BelongsTo
    {
        return $this->belongsTo(Deliverylog::class, 'deliverylog_id');
    }

    public function hub(): BelongsTo
    {
        return $this->belongsTo(Logistichub::class, 'logistichub_id');
    }
}
