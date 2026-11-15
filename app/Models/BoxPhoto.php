<?php

namespace App\Models;

use Illuminate\Database\Eloquent\Builder;
use Illuminate\Database\Eloquent\Model;
use Illuminate\Database\Eloquent\Relations\BelongsTo;
use Illuminate\Support\Facades\Storage;

/** One photo taken while scanning. Every capture is its own row and file; nothing is replaced. */
class BoxPhoto extends Model
{
    public const STEPS = [
        'unload' => 'Unloading a container',
        'load' => 'Loading a delivery truck',
        'hub_load' => 'Loading at a partner hub',
        'wh_load' => 'Warehouse to warehouse: loading',
        'wh_unload' => 'Warehouse to warehouse: unloading',
        'return' => 'Returning boxes',
        'hub_receive' => 'Receiving at a partner hub',
    ];

    public const SHORT = [
        'unload' => 'Unload', 'load' => 'Load', 'hub_load' => 'Hub load',
        'wh_load' => 'WH transfer load', 'wh_unload' => 'WH transfer unload', 'return' => 'Return', 'hub_receive' => 'Hub receive',
    ];

    public const CONDITIONS = ['good' => 'Good', 'damaged' => 'Damaged', 'wet' => 'Wet', 'open' => 'Open'];

    protected $guarded = [];

    protected function casts(): array
    {
        return ['taken_at' => 'datetime', 'is_batch' => 'boolean'];
    }

    public function box(): BelongsTo
    {
        return $this->belongsTo(Invoice::class, 'invoice_id');
    }

    public function container(): BelongsTo
    {
        return $this->belongsTo(Container::class);
    }

    public function deliverylog(): BelongsTo
    {
        return $this->belongsTo(Deliverylog::class);
    }

    public function whdeliverylog(): BelongsTo
    {
        return $this->belongsTo(Whdeliverylog::class);
    }

    public function user(): BelongsTo
    {
        return $this->belongsTo(User::class);
    }

    public function warehouse(): BelongsTo
    {
        return $this->belongsTo(Warehouse::class);
    }

    public function logistichub(): BelongsTo
    {
        return $this->belongsTo(Logistichub::class);
    }

    /**
     * Who may see which photos: admin and warehouse staff see all;
     * partner hub staff see photos of boxes sent to their hub or taken by them.
     */
    public function scopeVisibleTo(Builder $query, ?User $user): Builder
    {
        if (! $user) {
            return $query->whereRaw('1 = 0');
        }
        if ($user->hasRole('super_admin')) {
            return $query;
        }
        $hub = $user->logistichub_id ? Logistichub::find($user->logistichub_id) : null;
        if (! $hub || ! $hub->is_company) {
            // admin and warehouse staff
            return ($hub || $user->warehouse_id) ? $query : $query->whereRaw('1 = 0');
        }

        return $query->where(fn (Builder $q) => $q->where('logistichub_id', $hub->id)
            ->orWhereIn('invoice_id', Tripinvoice::where('logistichub_id', $hub->id)->select('invoice_id')));
    }

    public function scopeSearch(Builder $query, string $term): Builder
    {
        $term = trim($term);
        if ($term === '') {
            return $query;
        }

        return $query->where(fn (Builder $q) => $q->where('invoice', 'like', "%{$term}%")
            ->orWhereHas('container', fn (Builder $c) => $c->where('container_no', 'like', "%{$term}%"))
            ->orWhereHas('deliverylog', fn (Builder $d) => $d->where('trip_number', 'like', "%{$term}%"))
            ->orWhereHas('whdeliverylog', fn (Builder $d) => $d->where('trip_number', 'like', "%{$term}%")));
    }

    public function url(): string
    {
        return route('box-photos.show', $this);
    }

    public function downloadUrl(): string
    {
        return route('box-photos.download', $this);
    }

    /** Where it was taken: container or trip. */
    public function reference(): string
    {
        return match (true) {
            (bool) $this->deliverylog_id => 'Trip '.($this->deliverylog?->trip_number ?? '#'.$this->deliverylog_id),
            (bool) $this->whdeliverylog_id => 'WH trip '.($this->whdeliverylog?->trip_number ?? '#'.$this->whdeliverylog_id),
            (bool) $this->container_id => 'Container '.($this->container?->container_no ?? '#'.$this->container_id),
            default => '—',
        };
    }

    public function place(): string
    {
        return $this->warehouse?->name ?? $this->logistichub?->hub_name ?? '';
    }

    /** INV004521_unload_2.jpg — position among the photos of this box at this step. */
    public function fileName(): string
    {
        $n = static::where('invoice_id', $this->invoice_id)->where('step', $this->step)->where('is_batch', $this->is_batch)
            ->where('id', '<=', $this->id)->count();
        $base = $this->is_batch ? 'batch_'.str($this->reference())->slug('_') : ($this->invoice ?: 'box');

        return $base.'_'.$this->step.'_'.max(1, $n).'.jpg';
    }

    public function exists(): bool
    {
        return Storage::disk('local')->exists($this->path);
    }

    protected static function booted(): void
    {
        static::deleting(fn (BoxPhoto $p) => Storage::disk('local')->delete($p->path));
    }
}
