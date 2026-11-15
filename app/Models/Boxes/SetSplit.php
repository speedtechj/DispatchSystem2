<?php

namespace App\Models\Boxes;

use App\Models\Invoice;
use Illuminate\Database\Eloquent\Model;
use Illuminate\Database\Eloquent\Relations\BelongsTo;

/** A customer's boxes that leave on different trucks, and why. */
class SetSplit extends Model
{
    protected $guarded = [];

    public const REASONS = ['not_arrived' => 'Not arrived yet', 'held' => 'Damaged or held', 'not_found' => 'Cannot find', 'full' => 'Truck full'];

    public function invoice(): BelongsTo
    {
        return $this->belongsTo(Invoice::class);
    }
}
