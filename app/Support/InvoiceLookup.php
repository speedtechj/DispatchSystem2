<?php

namespace App\Support;

use App\Models\Invoice;
use App\Models\Tripinvoice;

class InvoiceLookup
{
    public static function normalize(?string $code): string
    {
        // Remove spaces / hidden characters some scanners add, then uppercase
        $code = preg_replace('/[\s\x00-\x1F\x7F]+/u', '', (string) $code);

        return mb_strtoupper($code);
    }

    public static function find(?string $code): ?Tripinvoice
    {

        $code = static::normalize($code);

        if ($code === '') {
            return null;
        }

        return Tripinvoice::query()
            ->where('invoice', $code)
            ->orderByRaw('coalesce(is_delivered, 0) asc') // a box not delivered first: two boxes can share a number (board 57)
            ->latest('id') // newest trip first, if the same invoice was on several trips
            ->first();
    }
}
