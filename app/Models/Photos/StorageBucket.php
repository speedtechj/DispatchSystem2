<?php

namespace App\Models\Photos;

use Illuminate\Database\Eloquent\Model;

/** A bucket in Settings → Photo storage: the Temporary or the Real one. The secret is kept encrypted. */
class StorageBucket extends Model
{
    protected $table = 'storage_buckets';

    protected $hidden = ['secret'];

    protected function casts(): array
    {
        return ['secret' => 'encrypted', 'test_ok' => 'boolean', 'is_off' => 'boolean', 'tested_at' => 'datetime'];
    }

    public function isSet(): bool
    {
        return filled($this->bucket) && filled($this->access_key) && filled($this->secret)
            && match ($this->provider) {
                'r2' => filled($this->account_id),
                's3' => filled($this->region),
                default => filled($this->endpoint),
            };
    }

    public function endpointUrl(): ?string
    {
        return match ($this->provider) {
            'r2' => $this->account_id ? 'https://'.trim($this->account_id).'.r2.cloudflarestorage.com' : null,
            's3' => null,
            default => $this->endpoint ? rtrim(trim($this->endpoint), '/') : null,
        };
    }
}
