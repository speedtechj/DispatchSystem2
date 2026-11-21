<?php

namespace App\Models\Boxes;

use App\Models\Invoice;
use App\Models\Logistichub;
use App\Models\Warehouse;
use Illuminate\Database\Eloquent\Model;
use Illuminate\Database\Eloquent\Relations\BelongsTo;
use Illuminate\Database\Eloquent\Relations\HasMany;

/** A section of the warehouse floor, for one destination (a partner hub, another warehouse, returns…). */
class WhSection extends Model
{
    protected $table = 'wh_sections';

    protected $guarded = [];

    public const KINDS = ['area' => 'Destination', 'returns' => 'Returns & wrong hub', 'check' => 'Check address'];

    protected function casts(): array
    {
        return ['provinces' => 'array', 'cities' => 'array', 'use_spots' => 'boolean', 'is_active' => 'boolean'];
    }

    public function warehouse(): BelongsTo
    {
        return $this->belongsTo(Warehouse::class);
    }

    public function hub(): BelongsTo
    {
        return $this->belongsTo(Logistichub::class, 'logistichub_id');
    }

    public function toWarehouse(): BelongsTo
    {
        return $this->belongsTo(Warehouse::class, 'to_warehouse_id');
    }

    public function invoices(): HasMany
    {
        return $this->hasMany(Invoice::class, 'wh_section_id');
    }

    public function spots(): HasMany
    {
        return $this->hasMany(WhSpot::class, 'wh_section_id')->orderBy('sort')->orderBy('id');
    }

    /** What the QR label on this section says. */
    public function qrText(): string
    {
        return 'SEC-'.$this->id;
    }

    /** "Cebu hub", "Tarlac warehouse", "Check address" */
    public function goesTo(): string
    {
        return $this->hub?->hub_name ?? $this->toWarehouse?->name ?? (self::KINDS[$this->kind] ?? $this->name);
    }
}
