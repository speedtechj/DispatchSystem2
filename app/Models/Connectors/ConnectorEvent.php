<?php

namespace App\Models\Connectors;

use App\Models\Invoice;
use App\Models\User;
use Illuminate\Database\Eloquent\Model;
use Illuminate\Database\Eloquent\Relations\BelongsTo;

/** One status in the Outbox (Part 47): made here first, then sent to the connector. */
class ConnectorEvent extends Model
{
    protected $guarded = ['id'];

    /** States that are finished: nothing more is sent. */
    public const DONE = ['saved', 'skipped', 'refused', 'cancelled'];

    /** States the connector keeps and retries by itself (we only read the result later). */
    public const AT_CONNECTOR = ['needs_mapping', 'not_found', 'failed', 'sent'];

    protected function casts(): array
    {
        return [
            'payload' => 'array',
            'manual' => 'boolean',
            'send_after' => 'datetime',
            'next_try_at' => 'datetime',
            'sent_at' => 'datetime',
            'happened_at' => 'datetime',
        ];
    }

    public function link(): BelongsTo
    {
        return $this->belongsTo(ConnectorLink::class, 'connector_link_id');
    }

    public function invoiceRow(): BelongsTo
    {
        return $this->belongsTo(Invoice::class, 'invoice_id');
    }

    public function user(): BelongsTo
    {
        return $this->belongsTo(User::class);
    }

    public function isUndo(): bool
    {
        return filled($this->corrects);
    }
}
