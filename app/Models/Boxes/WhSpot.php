<?php

namespace App\Models\Boxes;

use App\Models\Invoice;
use Illuminate\Database\Eloquent\Model;
use Illuminate\Database\Eloquent\Relations\BelongsTo;
use Illuminate\Database\Eloquent\Relations\HasMany;

/** A spot inside a warehouse section (a rack, a pallet, part of the floor): C1, C2… Optional. */
class WhSpot extends Model
{
    protected $table = 'wh_spots';

    protected $guarded = [];

    public function section(): BelongsTo
    {
        return $this->belongsTo(WhSection::class, 'wh_section_id');
    }

    public function invoices(): HasMany
    {
        return $this->hasMany(Invoice::class, 'wh_spot_id');
    }

    /** What the QR label on this spot says. */
    public function qrText(): string
    {
        return 'SPOT-'.$this->id;
    }
}
