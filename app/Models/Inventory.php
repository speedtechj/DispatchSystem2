<?php

namespace App\Models;

use Illuminate\Database\Eloquent\Builder;
use Illuminate\Database\Eloquent\Model;
use Illuminate\Database\Eloquent\Relations\BelongsTo;
use Illuminate\Database\Eloquent\Relations\HasMany;
use Illuminate\Database\Eloquent\Relations\HasOne;

/**
 * A box (invoice row) seen from the warehouse floor.
 *
 * A box is "on the floor" of a warehouse when:
 *  - it was scanned off its container (is_verified), and that warehouse is its current warehouse_id;
 *  - it is not delivered;
 *  - it is not loaded on a delivery truck (a trip row whose trip no longer exists is ignored);
 *  - it is not on a warehouse truck between two warehouses. A box sent to another warehouse
 *    (e.g. Tarlac) leaves the sending warehouse when it is loaded, and only joins the
 *    receiving warehouse when it is unloaded there (unloading sets warehouse_id).
 *
 * A box with no trip at all, or on a trip that is not loaded yet, is on the floor.
 */
class Inventory extends Model
{
    public $table = 'invoices';

    protected function casts(): array
    {
        return [
            'is_verified' => 'boolean',
            'is_delivered' => 'boolean',
            'is_returned' => 'boolean',
        ];
    }

    public function tripInvoices(): HasMany
    {
        return $this->hasMany(Tripinvoice::class, 'invoice_id', 'id');
    }

    /** The box's current delivery trip row, ignoring rows whose trip was deleted. */
    public function currentTrip(): HasOne
    {
        return $this->hasOne(Tripinvoice::class, 'invoice_id', 'id')
            ->ofMany(['id' => 'max'], fn (Builder $query) => $query->whereHas('deliverylog'));
    }

    public function whTripInvoices(): HasMany
    {
        return $this->hasMany(Whtripinvoice::class, 'invoice_id', 'id');
    }

    public function container(): BelongsTo
    {
        return $this->belongsTo(Container::class, 'container_id', 'id');
    }

    public function warehouse(): BelongsTo
    {
        return $this->belongsTo(Warehouse::class, 'warehouse_id', 'id');
    }

    public function deliverylogs()
    {
        return $this->hasManyThrough(Deliverylog::class, Tripinvoice::class);
    }

    public function consolidator(): BelongsTo
    {
        return $this->belongsTo(Consolidator::class, 'location_code', 'code');
    }

    /** Boxes physically sitting in a warehouse (all warehouses when $warehouseId is null). */
    public function scopeOnFloor(Builder $query, ?int $warehouseId = null): Builder
    {
        return $query
            ->where('invoices.is_verified', true)
            ->where(fn (Builder $query) => $query->where('invoices.is_delivered', false)->orWhereNull('invoices.is_delivered'))
            ->whereDoesntHave('tripInvoices', fn (Builder $trip) => $trip
                ->whereHas('deliverylog')
                ->where(fn (Builder $trip) => $trip->where('is_loaded', true)->orWhere('is_delivered', true)))
            ->whereDoesntHave('whTripInvoices', fn (Builder $move) => $move
                ->whereHas('whdeliverylog')
                ->where('is_loaded', true)
                ->where('is_unloaded', false))
            ->when($warehouseId !== null, fn (Builder $query) => $query->where('invoices.warehouse_id', $warehouseId));
    }

    /** @deprecated Old name, kept so older code still works. Use onFloor(). */
    public function scopeByReceiverProvince(Builder $query): Builder
    {
        return $query->onFloor();
    }
}
