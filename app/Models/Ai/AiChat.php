<?php

namespace App\Models\Ai;

use Illuminate\Database\Eloquent\Model;

class AiChat extends Model
{
    protected $table = 'ai_chats';

    protected function casts(): array
    {
        return ['messages' => 'array', 'needs_staff' => 'boolean'];
    }
}
