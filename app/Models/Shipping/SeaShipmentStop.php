<?php

namespace App\Models\Shipping;

use App\Models\Deliverylog;
use App\Models\Logistichub;
use Illuminate\Database\Eloquent\Model;
use Illuminate\Database\Eloquent\Relations\BelongsTo;

/** One hub's part of a sea shipment: its trip, its place in the unloading order, when it was received. */
class SeaShipmentStop extends Model
{
    protected $guarded = [];

    protected function casts(): array
    {
        return ['received_at' => 'datetime', 'arrived_at' => 'datetime', 'stop' => 'integer', 'trucking_cost' => 'float'];
    }

    public function shipment(): BelongsTo
    {
        return $this->belongsTo(SeaShipment::class, 'sea_shipment_id');
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
