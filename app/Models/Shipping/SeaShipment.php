<?php

namespace App\Models\Shipping;

use App\Models\Deliverylog;
use App\Models\Logistichub;
use App\Models\Tripinvoice;
use App\Models\User;
use Illuminate\Database\Eloquent\Model;
use Illuminate\Database\Eloquent\Relations\BelongsTo;
use Illuminate\Database\Eloquent\Relations\HasMany;
use Illuminate\Support\Facades\Storage;

/** A container van (or a RoRo truck) taking a trip's boxes by sea to a partner hub. */
class SeaShipment extends Model
{
    protected $guarded = [];

    protected function casts(): array
    {
        return ['status_log' => 'array', 'etd' => 'date', 'eta' => 'date', 'port_at' => 'datetime',
            'cost_freight' => 'float', 'cost_trucking' => 'float', 'cost_port' => 'float', 'cost_other' => 'float', 'charge_rate' => 'float'];
    }

    public function trip(): BelongsTo
    {
        return $this->belongsTo(Deliverylog::class, 'deliverylog_id');
    }

    public function hub(): BelongsTo
    {
        return $this->belongsTo(Logistichub::class, 'logistichub_id');
    }

    public function creator(): BelongsTo
    {
        return $this->belongsTo(User::class, 'created_by');
    }

    public function scans(): HasMany
    {
        return $this->hasMany(SeaShipmentScan::class);
    }

    /** The boxes: the trip's boxes. */
    public function boxes(): HasMany
    {
        return $this->hasMany(Tripinvoice::class, 'deliverylog_id', 'deliverylog_id');
    }

    /** The hubs of this container in unloading order (one stop for a normal shipment). */
    public function forwarderRow(): BelongsTo
    {
        return $this->belongsTo(Forwarder::class, 'forwarder_id');
    }

    public function handOverBranch(): BelongsTo
    {
        return $this->belongsTo(ForwarderBranch::class, 'hand_over_branch_id');
    }

    public function pickUpBranch(): BelongsTo
    {
        return $this->belongsTo(ForwarderBranch::class, 'pick_up_branch_id');
    }

    public function stops(): HasMany
    {
        return $this->hasMany(SeaShipmentStop::class)->orderBy('stop');
    }

    public function cost(): float
    {
        // + the trucking of a second truck (board 62)
        $extra = \App\Support\Shipping\Shipments::stopsReady() && \Illuminate\Support\Facades\Schema::hasColumn('sea_shipment_stops', 'trucking_cost')
            ? (float) $this->stops()->sum('trucking_cost') : 0.0;

        return (float) $this->cost_freight + (float) $this->cost_trucking + (float) $this->cost_port + (float) $this->cost_other + $extra;
    }

    public function fileUrl(?string $path): ?string
    {
        return $path ? Storage::disk('public')->url($path) : null;
    }
}
