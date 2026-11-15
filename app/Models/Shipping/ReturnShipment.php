<?php

namespace App\Models\Shipping;

use App\Models\Logistichub;
use App\Models\Warehouse;
use Illuminate\Database\Eloquent\Model;
use Illuminate\Database\Eloquent\Relations\BelongsTo;
use Illuminate\Database\Eloquent\Relations\HasMany;

/** Boxes going back from a partner hub to the warehouse. */
class ReturnShipment extends Model
{
    protected $guarded = [];

    public const STATUS = ['preparing' => 'Preparing at the hub', 'sent' => 'On the way back', 'received' => 'Received at the warehouse'];

    protected function casts(): array
    {
        return ['status_log' => 'array', 'eta' => 'date', 'cost' => 'float'];
    }

    public function hub(): BelongsTo
    {
        return $this->belongsTo(Logistichub::class, 'logistichub_id');
    }

    public function warehouse(): BelongsTo
    {
        return $this->belongsTo(Warehouse::class);
    }

    public function boxes(): HasMany
    {
        return $this->hasMany(WrongHubBox::class);
    }
}
