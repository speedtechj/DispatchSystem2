<?php

namespace App\Models\Ai;

use App\Models\User;
use App\Support\Ai\AiScope;
use Illuminate\Database\Eloquent\Builder;
use Illuminate\Database\Eloquent\Model;

class AiAlert extends Model
{
    protected $table = 'ai_alerts';

    protected function casts(): array
    {
        return ['handled_at' => 'datetime'];
    }

    public function scopeVisibleTo(Builder $q, ?User $user): Builder
    {
        $hub = AiScope::hubId($user);
        if ($hub === false) {
            return $q->whereRaw('1 = 0');
        }

        return $hub ? $q->where('logistichub_id', $hub) : $q;
    }

    /** Add or refresh an alert. An alert someone already handled is not reopened. */
    public static function raise(string $key, array $data): self
    {
        $alert = static::firstOrNew(['key' => $key]);
        if ($alert->exists && $alert->status !== 'open') {
            return $alert;
        }
        $alert->fill($data + ['status' => 'open'])->save();

        return $alert;
    }
}
