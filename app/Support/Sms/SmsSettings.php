<?php

namespace App\Support\Sms;

use App\Models\AppSetting;
use App\Models\Sms\SmsMessage;
use Illuminate\Support\Facades\Crypt;
use Throwable;

/** Admin → Settings → SMS. Keys are saved encrypted. With no key nothing is sent. */
class SmsSettings
{
    public const PROVIDERS = [
        'semaphore' => ['Semaphore', 'Philippine company, used by many local businesses. Paste the API key from semaphore.co.', true],
        'twilio' => ['Twilio', 'International. Paste "Account SID:Auth Token"; the sender is your Twilio number or Messaging Service SID. Usually costs more.', true],
        'm360' => ['M360', 'Philippine SMS provider for businesses. Send us their API details and we connect it.', false],
        'itexmo' => ['iTexMo / Movider', 'Local and regional options. Send us their API details and we connect it.', false],
    ];

    public const KINDS = [
        'out_for_delivery' => ['Out for delivery', 'When the truck is loaded and the trip is on the road', true],
        'driver_next' => ['Driver is next', 'When the receiver is the next 1–2 stops', true],
        'delivered' => ['Delivered', 'When the last box of the receiver is delivered', true],
        'not_delivered' => ['Not delivered', 'When the driver marks it not delivered', true],
        'hub_arrived' => ['Arrived at partner hub', 'When the box is handed to a partner hub', false],
        'set_split' => ['Rest of the boxes follow', 'When some of a customer\'s boxes stay behind at loading', false],
    ];

    public static function provider(): string
    {
        $p = (string) AppSetting::get('sms.provider', 'semaphore');

        return isset(self::PROVIDERS[$p]) ? $p : 'semaphore';
    }

    public static function key(?string $provider = null): ?string
    {
        $v = AppSetting::get('sms.key.'.($provider ?? static::provider()));
        try {
            return $v ? Crypt::decryptString($v) : null;
        } catch (Throwable) {
            return null;
        }
    }

    public static function putKey(string $provider, ?string $key): void
    {
        AppSetting::put('sms.key.'.$provider, filled($key) ? Crypt::encryptString(trim($key)) : null);
    }

    public static function masked(string $provider): ?string
    {
        $k = static::key($provider);

        return $k ? substr($k, 0, 4).str_repeat('•', 10).substr($k, -3) : null;
    }

    public static function ready(): bool
    {
        return (bool) static::key() && (self::PROVIDERS[static::provider()][2] ?? false);
    }

    public static function sender(): string
    {
        return (string) AppSetting::get('sms.sender', '');
    }

    public static function limit(): int
    {
        return (int) AppSetting::get('sms.limit', 3000);
    }

    public static function on(string $kind): bool
    {
        return (bool) AppSetting::get('sms.on.'.$kind, self::KINDS[$kind][2] ?? false);
    }

    /** auto (by province), en, tl, ceb */
    public static function language(): string
    {
        return (string) AppSetting::get('sms.language', 'auto');
    }

    public static function officePhone(): string
    {
        return (string) AppSetting::get('sms.office_phone', '');
    }

    /** Texts (SMS parts) used this month. */
    public static function usedThisMonth(): int
    {
        return (int) SmsMessage::where('status', 'sent')->where('created_at', '>=', now()->startOfMonth())->sum('parts');
    }
}
