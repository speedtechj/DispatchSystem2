<?php

namespace App\Models;

use App\Models\Boxes\WhSection;
use App\Models\Boxes\WhSpot;
use App\Models\Maps\BarangayFill;
use App\Support\Boxes\BoxSets;
use App\Support\Maps\Barangays;
use Illuminate\Database\Eloquent\Casts\Attribute;
use Illuminate\Database\Eloquent\Model;
use Illuminate\Database\Eloquent\Relations\HasMany;
use Illuminate\Database\Eloquent\Relations\HasOne;

class Invoice extends Model
{
    protected function casts(): array
    {
        return [
            'is_verified' => 'boolean',
            'is_delivered' => 'boolean',
            'is_assigned' => 'boolean',
            'is_returned' => 'boolean',
            'is_priority' => 'boolean',
            'is_resolved' => 'boolean',
            'wh_is_assigned' => 'boolean',
            'sectioned_at' => 'datetime',
        ];
    }

    protected static function booted(): void
    {
        // the customer's set: all boxes for the same receiver, phone and city
        static::saving(function (Invoice $invoice): void {
            if (! $invoice->set_key || $invoice->isDirty(['receiver_name', 'receiver_mobile_no', 'receiver_city'])) {
                $invoice->set_key = BoxSets::keyFor($invoice->receiver_name, $invoice->receiver_mobile_no, $invoice->receiver_city);
            }
        });
        // no barangay on the manifest: queue it so the system fills it in (Addresses to check)
        static::created(fn (Invoice $invoice) => Barangays::queue($invoice));
    }

    public function barangayFill()
    {
        return $this->hasOne(BarangayFill::class);
    }

    public function whSection()
    {
        return $this->belongsTo(WhSection::class, 'wh_section_id');
    }

    /** The spot inside its section (C2), when spots are used. */
    public function whSpot()
    {
        return $this->belongsTo(WhSpot::class, 'wh_spot_id');
    }

    public function verifiedBy()
    {
        return $this->belongsTo(User::class, 'verified_by');
    }

    public function container()
    {
        return $this->belongsTo(Container::class);
    }

    public function warehouse()
    {
        return $this->belongsTo(Warehouse::class);
    }

    public function user()
    {
        return $this->belongsTo(User::class);
    }

    public function routearea()
    {
        return $this->belongsTo(Routearea::class);
    }

    protected function FullAddress(): Attribute
    {
        return new Attribute(
            get: fn () => $this->receiver_address.' '.$this->receiver_province.' '.$this->receiver_city.' '.$this->receiver_barangay
        );
    }

    public function consolidator()
    {
        return $this->belongsTo(
            Consolidator::class,
            'location_code', // FK on invoices
            'code'           // UNIQUE key on consolidators
        );

    }

    public function tripInvoices()
    {
        return $this->hasMany(Tripinvoice::class);
    }

    public function deliverylogs()
    {
        return $this->hasManyThrough(Deliverylog::class, Tripinvoice::class);
    }

    public function invoiceissue()
    {
        return $this->hasMany(Invoiceissue::class);
    }

    public function whtripinvoice()
    {
        return $this->hasOne(Whtripinvoice::class, 'invoice_id', 'id');
    }

    public function deliveryAttempts(): HasMany
    {
        return $this->hasMany(DeliveryAttempt::class)->latest('id');
    }

    public function latestDeliveryAttempt(): HasOne
    {
        return $this->hasOne(DeliveryAttempt::class)->latestOfMany();
    }
}
