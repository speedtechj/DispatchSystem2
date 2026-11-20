<?php

namespace App\Models\Hubs;

use App\Models\Logistichub;
use App\Models\User;
use Illuminate\Database\Eloquent\Model;
use Illuminate\Database\Eloquent\Relations\BelongsTo;

/** A hub asks the office for a place. */
class HubAreaRequest extends Model
{
    protected $guarded = [];

    protected function casts(): array
    {
        return ['decided_at' => 'datetime'];
    }

    public function hub(): BelongsTo
    {
        return $this->belongsTo(Logistichub::class, 'logistichub_id');
    }

    public function user(): BelongsTo
    {
        return $this->belongsTo(User::class);
    }

    public function label(): string
    {
        return collect([$this->barangay ? 'Brgy. '.preg_replace('/^(brgy\.?|barangay)\s+/i', '', $this->barangay) : null, $this->city, $this->province])->filter()->join(', ');
    }
}
