<?php

namespace App\Models\Shipping;

use App\Models\Invoice;
use App\Models\Logistichub;
use App\Models\Tripinvoice;
use Illuminate\Database\Eloquent\Model;
use Illuminate\Database\Eloquent\Relations\BelongsTo;

/** A box at a partner hub that is not theirs, or could not be delivered and goes back. */
class WrongHubBox extends Model
{
    protected $guarded = [];

    public const REASONS = ['wrong_hub' => 'Wrong hub', 'refused' => 'Refused by receiver', 'moved' => 'Receiver moved', 'wrong_address' => 'Wrong address', 'other' => 'Other'];

    public const STATUS = ['waiting' => 'Waiting', 'sent_hub' => 'Sent to the right hub', 'back' => 'Back to the warehouse', 'done' => 'Done'];

    protected function casts(): array
    {
        return ['done_at' => 'datetime'];
    }

    public function invoice(): BelongsTo
    {
        return $this->belongsTo(Invoice::class);
    }

    public function tripinvoice(): BelongsTo
    {
        return $this->belongsTo(Tripinvoice::class);
    }

    public function hub(): BelongsTo
    {
        return $this->belongsTo(Logistichub::class, 'logistichub_id');
    }

    public function correctHub(): BelongsTo
    {
        return $this->belongsTo(Logistichub::class, 'correct_hub_id');
    }

    public function shipment(): BelongsTo
    {
        return $this->belongsTo(SeaShipment::class, 'sea_shipment_id');
    }
}
