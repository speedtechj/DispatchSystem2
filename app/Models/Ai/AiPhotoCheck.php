<?php

namespace App\Models\Ai;

use App\Models\BoxPhoto;
use App\Models\Tripinvoice;
use App\Models\User;
use App\Support\Ai\AiScope;
use Illuminate\Database\Eloquent\Builder;
use Illuminate\Database\Eloquent\Model;
use Illuminate\Support\Facades\Storage;

class AiPhotoCheck extends Model
{
    protected $table = 'ai_photo_checks';

    public const VERDICTS = [
        'ok' => 'Looks fine', 'damaged' => 'Damaged', 'wet' => 'Wet', 'open' => 'Open',
        'blurry' => 'Blurry photo', 'no_box' => 'No box in photo', 'unclear' => 'Unclear',
    ];

    protected function casts(): array
    {
        return ['flagged' => 'boolean', 'decided_at' => 'datetime', 'checked_at' => 'datetime'];
    }

    public function boxPhoto()
    {
        return $this->belongsTo(BoxPhoto::class);
    }

    public function tripinvoice()
    {
        return $this->belongsTo(Tripinvoice::class);
    }

    public function decider()
    {
        return $this->belongsTo(User::class, 'decided_by');
    }

    public function scopeVisibleTo(Builder $q, ?User $user): Builder
    {
        $hub = AiScope::hubId($user);
        if ($hub === false) {
            return $q->whereRaw('1 = 0');
        }

        return $hub ? $q->where('logistichub_id', $hub) : $q;
    }

    public const STEPS = [
        'unload' => 'Unload', 'load' => 'Load truck', 'wh_load' => 'Warehouse load', 'wh_unload' => 'Warehouse unload',
        'hub_load' => 'Hub load', 'return' => 'Return', 'delivered' => 'Proof of delivery',
    ];

    public static function stepLabel(?string $step): string
    {
        return self::STEPS[$step] ?? (string) $step;
    }

    public function label(): string
    {
        return self::VERDICTS[$this->verdict] ?? 'Unclear';
    }

    /** Where the photo can be opened in the browser. */
    public function url(): string
    {
        return $this->box_photo_id
            ? route('box-photos.show', $this->box_photo_id)
            : Storage::disk('public')->url($this->path);
    }
}
