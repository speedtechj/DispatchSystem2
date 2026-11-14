<?php

namespace App\Support\Sms;

use App\Models\Sms\SmsMessage;
use App\Models\Sms\SmsOptout;
use Illuminate\Support\Facades\Http;
use Throwable;

/** Sends one text through the chosen provider and keeps it in the SMS log. */
class SmsSender
{
    /** @param array{deliverylog_id?: ?int, receiver_key?: ?string, invoice_ids?: array, user_id?: ?int, lang?: string} $meta */
    public static function send(string $kind, ?string $rawNumber, ?string $name, string $text, array $meta = []): SmsMessage
    {
        $number = Phone::clean($rawNumber);
        $parts = Templates::parts($text);
        $provider = SmsSettings::provider();
        $row = new SmsMessage([
            'kind' => $kind, 'name' => $name, 'raw_number' => mb_substr((string) $rawNumber, 0, 60), 'number' => $number,
            'message' => $text, 'parts' => $parts, 'provider' => $provider,
            'deliverylog_id' => $meta['deliverylog_id'] ?? null, 'receiver_key' => $meta['receiver_key'] ?? null,
            'invoice_ids' => $meta['invoice_ids'] ?? null, 'user_id' => $meta['user_id'] ?? null, 'lang' => $meta['lang'] ?? 'en',
        ]);

        $row->status = match (true) {
            ! $number => 'bad_number',
            SmsOptout::where('number', $number)->exists() => 'opted_out',
            ! SmsSettings::ready() => 'no_key',
            $kind !== 'test' && SmsSettings::usedThisMonth() + $parts > SmsSettings::limit() => 'over_limit',
            default => 'sending',
        };

        if ($row->status === 'sending') {
            try {
                $row->provider_id = static::deliver($provider, $number, $text);
                $row->status = 'sent';
                $row->sent_at = now();
            } catch (Throwable $e) {
                $row->status = 'failed';
                $row->error = mb_substr($e->getMessage(), 0, 490);
            }
        }
        $row->save();

        return $row;
    }

    /** @return string the provider's message id */
    protected static function deliver(string $provider, string $number, string $text): string
    {
        $key = (string) SmsSettings::key($provider);
        $sender = SmsSettings::sender();

        if ($provider === 'semaphore') {
            $res = Http::asForm()->timeout(15)->post('https://api.semaphore.co/api/v4/messages', array_filter([
                'apikey' => $key, 'number' => $number, 'message' => $text, 'sendername' => $sender ?: null,
            ]));
            $body = $res->json();
            if (! $res->successful() || ! is_array($body) || ! isset($body[0]['message_id'])) {
                throw new \RuntimeException('Semaphore: '.(is_array($body) ? json_encode($body) : $res->body()));
            }

            return (string) $body[0]['message_id'];
        }

        if ($provider === 'twilio') {
            [$sid, $token] = array_pad(explode(':', $key, 2), 2, '');
            $from = str_starts_with($sender, 'MG') ? ['MessagingServiceSid' => $sender] : ['From' => $sender];
            $res = Http::asForm()->withBasicAuth($sid, $token)->timeout(15)
                ->post("https://api.twilio.com/2010-04-01/Accounts/{$sid}/Messages.json", ['To' => Phone::international($number), 'Body' => $text] + $from);
            if (! $res->successful()) {
                throw new \RuntimeException('Twilio: '.($res->json('message') ?? $res->body()));
            }

            return (string) $res->json('sid');
        }

        throw new \RuntimeException(SmsSettings::PROVIDERS[$provider][0].' is not connected yet.');
    }

    /** Credits left, when the provider tells (Semaphore). */
    public static function credits(): ?int
    {
        if (SmsSettings::provider() !== 'semaphore' || ! SmsSettings::key()) {
            return null;
        }

        return cache()->store('file')->remember('sms.credits', 300, function () {
            try {
                $r = Http::timeout(8)->get('https://api.semaphore.co/api/v4/account', ['apikey' => SmsSettings::key()]);

                return $r->successful() ? (int) round((float) ($r->json('credit_balance') ?? 0)) : null;
            } catch (Throwable) {
                return null;
            }
        });
    }
}
