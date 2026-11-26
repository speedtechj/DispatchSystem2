<?php

namespace App\Models\Photos;

use Illuminate\Database\Eloquent\Model;

/** Where a photo is when it is not on this server (no row = on the server, like before). */
class PhotoFile extends Model
{
    protected $table = 'photo_files';
}
