<?php

namespace App\Models;

use Illuminate\Database\Eloquent\Model;
use Illuminate\Database\Eloquent\Relations\BelongsTo;
use Illuminate\Database\Eloquent\Relations\HasMany;
use Illuminate\Database\Eloquent\Relations\HasOne;

class Tripinvoice extends Model
{
    //
    /**
     * Trip steps: when the last box of a trip is delivered or returned (taken off the trip),
     * the trip closes and the truck is released by itself.
     */
    protected static function booted(): void
    {
        $check = function (Tripinvoice $row, array $tripIds): void {
            foreach (array_unique(array_filter($tripIds)) as $id) {
                \App\Support\TripFlow::maybeClose(Deliverylog::find($id));
            }
        };
        static::updated(function (Tripinvoice $row) use ($check): void {
            if ($row->wasChanged('is_delivered') && $row->is_delivered) {
                $check($row, [$row->deliverylog_id, $row->deliveryloghub_id]);
            } elseif ($row->wasChanged('deliveryloghub_id') && ! $row->deliveryloghub_id) {
                $check($row, [$row->getOriginal('deliveryloghub_id')]);
            }
        });
        static::deleted(fn (Tripinvoice $row) => $check($row, [$row->deliverylog_id, $row->deliveryloghub_id]));
    }

    protected function casts(): array
    {
        return [
            'delivery_picture' => 'array',
            'is_loaded' => 'boolean',
            'is_delivered' => 'boolean',
            'is_loaded_hub' => 'boolean',
            'hub_assigned' => 'boolean',
            'delivered_at' => 'datetime',
        ];
    }

    /** The box (invoices row). Use this instead of invoice(): the "invoice" column (box number) hides that relation. */
    public function box()
    {
        return $this->belongsTo(Invoice::class, 'invoice_id');
    }

    /** The partner hub's own trip this box is on (deliveryloghub_id). */
    public function hubTrip()
    {
        return $this->belongsTo(Deliverylog::class, 'deliveryloghub_id');
    }

    public function deliverylog()
    {
        return $this->belongsTo(Deliverylog::class);
    }

    public function invoice()
    {
        return $this->belongsTo(Invoice::class);
    }

    public function invdata()
    {
        return $this->belongsTo(Invoice::class, 'invoice_id', 'id');
    }

    public function logistichub()
    {
        return $this->belongsTo(Logistichub::class);
    }

    public function route()
    {
        return $this->hasOneThrough(
            Routearea::class,   // Final model
            Invoice::class, // Intermediate model
            'id',           // Foreign key on Invoice table
            'id',           // Foreign key on Route table
            'invoice_id',   // Local key on TripInvoice
            'routearea_id'      // Local key on Invoice
        );
    }

    public function container()
    {
        return $this->belongsTo(Container::class);
    }

    public function invoiceissue()
    {
        return $this->hasMany(Invoiceissue::class, 'invoice_id', 'invoice_id');
    }

    /** Failed delivery attempts for this box, newest first. */
    public function deliveryAttempts(): HasMany
    {
        return $this->hasMany(DeliveryAttempt::class, 'invoice_id', 'invoice_id')->latest('id');
    }

    public function latestDeliveryAttempt(): HasOne
    {
        return $this->hasOne(DeliveryAttempt::class, 'invoice_id', 'invoice_id')->latestOfMany();
    }

    /** Deliveries of this box that were undone, newest first. */
    public function deliveryReversals(): HasMany
    {
        return $this->hasMany(DeliveryReversal::class, 'invoice_id', 'invoice_id')->latest('id');
    }

    public function deliverer(): BelongsTo
    {
        return $this->belongsTo(User::class, 'delivered_by');
    }
}
