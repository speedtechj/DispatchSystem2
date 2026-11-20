<?php

namespace App\Models\Maps;

use App\Models\Invoice;
use Illuminate\Database\Eloquent\Model;

/** A barangay the system filled in for a box whose manifest had none. */
class BarangayFill extends Model
{
    protected $guarded = [];

    protected function casts(): array
    {
        return ['clues' => 'array', 'candidates' => 'array', 'checked_at' => 'datetime', 'confidence' => 'integer'];
    }

    public function invoice()
    {
        return $this->belongsTo(Invoice::class);
    }

    public function isUsed(): bool
    {
        return in_array($this->status, ['used', 'checked'], true) && filled($this->barangay);
    }
}
