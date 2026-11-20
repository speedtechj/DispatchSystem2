<?php

namespace App\Models\Hubs;

use App\Models\Logistichub;
use Illuminate\Database\Eloquent\Model;
use Illuminate\Database\Eloquent\Relations\BelongsTo;

/** One place a partner hub delivers: a province, a city, or a barangay. One owner per place. */
class HubArea extends Model
{
    protected $guarded = [];

    public function hub(): BelongsTo
    {
        return $this->belongsTo(Logistichub::class, 'logistichub_id');
    }

    public function label(): string
    {
        return collect([$this->barangay ? 'Brgy. '.preg_replace('/^(brgy\.?|barangay)\s+/i', '', $this->barangay) : null, $this->city, $this->province])->filter()->join(', ');
    }
}
