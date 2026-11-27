<?php

namespace App\Models;

use App\Enums\FailedDeliveryReason;
use Illuminate\Database\Eloquent\Model;
use Illuminate\Database\Eloquent\Relations\BelongsTo;

/** A delivery a driver tried and could not complete. */
class DeliveryAttempt extends Model
{
    protected function casts(): array
    {
        return [
            'reason' => FailedDeliveryReason::class,
            'photos' => 'array',
            'needs_office' => 'boolean',
            'handled_at' => 'datetime',
        ];
    }

    public function tripinvoice(): BelongsTo
    {
        return $this->belongsTo(Tripinvoice::class);
    }

    public function invoice(): BelongsTo
    {
        return $this->belongsTo(Invoice::class);
    }

    public function deliverylog(): BelongsTo
    {
        return $this->belongsTo(Deliverylog::class);
    }

    public function user(): BelongsTo
    {
        return $this->belongsTo(User::class);
    }
}
