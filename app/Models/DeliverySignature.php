<?php

namespace App\Models;

use Illuminate\Database\Eloquent\Model;
use Illuminate\Database\Eloquent\Relations\BelongsTo;
use Illuminate\Support\Facades\Storage;

/** Part 44: a delivery signed on the driver's phone (damaged box, or no paper receipt). */
class DeliverySignature extends Model
{
    public const DAMAGE = ['torn' => 'Torn', 'crushed' => 'Crushed', 'wet' => 'Wet', 'open' => 'Opened', 'dented' => 'Dented', 'missing' => 'Items missing'];

    public const PAPER = ['wet_torn' => 'Paper wet or torn', 'left_at_hub' => 'Left at the hub', 'no_more' => 'No more receipts'];

    public const RELATIONSHIP = ['Self', 'Spouse', 'Parent', 'Child', 'Sibling', 'Relative', 'Helper', 'Neighbor', 'Other'];

    protected function casts(): array
    {
        return ['damage' => 'array', 'cant_sign' => 'boolean', 'signed_at' => 'datetime'];
    }

    public function tripinvoice(): BelongsTo
    {
        return $this->belongsTo(Tripinvoice::class);
    }

    public function invoice(): BelongsTo
    {
        return $this->belongsTo(Invoice::class);
    }

    public function user(): BelongsTo
    {
        return $this->belongsTo(User::class);
    }

    public function isDamaged(): bool
    {
        return $this->why === 'damaged';
    }

    /** "Torn, crushed" (and the note). */
    public function damageText(): string
    {
        $list = collect($this->damage ?? [])->map(fn ($d) => self::DAMAGE[$d] ?? $d)->join(', ');

        return trim($list.($this->damage_note ? ($list ? ' · ' : '').$this->damage_note : ''));
    }

    public function link(): string
    {
        return url('/r/'.$this->token);
    }

    public function signatureData(): ?string
    {
        if (! $this->signature || ! Storage::disk('public')->exists($this->signature)) {
            return null;
        }

        return 'data:image/png;base64,'.base64_encode(Storage::disk('public')->get($this->signature));
    }
}
