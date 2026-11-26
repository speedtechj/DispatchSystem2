<?php

namespace App\Models\Photos;

use Illuminate\Database\Eloquent\Model;

class PhotoTaskItem extends Model
{
    protected $table = 'photo_task_items';

    protected function casts(): array
    {
        return ['tried' => 'boolean', 'checked' => 'boolean'];
    }
}
