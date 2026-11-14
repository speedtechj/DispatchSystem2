<?php

namespace App\Models\Sms;

use Illuminate\Database\Eloquent\Model;

/** One text to a receiver (or a test text), with what happened to it. */
class SmsMessage extends Model
{
    protected $table = 'sms_messages';

    protected $guarded = [];

    public const STATUS = [
        'sent' => ['Sent', 'success'], 'failed' => ['Failed', 'danger'], 'bad_number' => ['Bad number', 'danger'],
        'opted_out' => ['Replied STOP · not sent', 'warning'], 'over_limit' => ['Over the monthly limit', 'warning'], 'no_key' => ['No SMS key', 'gray'],
    ];

    protected function casts(): array
    {
        return ['invoice_ids' => 'array', 'sent_at' => 'datetime'];
    }
}
