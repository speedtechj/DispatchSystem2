<?php

namespace App\Models\Sms;

use Illuminate\Database\Eloquent\Model;

/** A number that is not texted again (replied STOP, or stopped by the office). */
class SmsOptout extends Model
{
    protected $table = 'sms_optouts';

    protected $guarded = [];
}
