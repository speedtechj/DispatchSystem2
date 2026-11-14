<?php

namespace App\Models;

use App\Enums\UndoDeliveryReason;
use Illuminate\Database\Eloquent\Model;
use Illuminate\Database\Eloquent\Relations\BelongsTo;

/** A delivery that was undone, by the driver or the office. */
class DeliveryReversal extends Model
{
    protected function casts(): array
    {
        return [
            'reason' => UndoDeliveryReason::class,
            'photos' => 'array',
            'delivered_at' => 'datetime',
            'by_office' => 'boolean',
        ];
    }

    public function user(): BelongsTo
    {
        return $this->belongsTo(User::class);
    }

    public function deliverer(): BelongsTo
    {
        return $this->belongsTo(User::class, 'delivered_by');
    }

    public function deliverylog(): BelongsTo
    {
        return $this->belongsTo(Deliverylog::class);
    }
}
