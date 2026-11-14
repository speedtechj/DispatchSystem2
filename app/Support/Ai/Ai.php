<?php

namespace App\Support\Ai;

use App\Models\Ai\AiSetting;
use App\Models\Ai\AiUsage;
use Illuminate\Http\Client\ConnectionException;
use Illuminate\Support\Facades\Auth;
use Illuminate\Support\Facades\Http;
use Illuminate\Support\Facades\Storage;
use Illuminate\Support\Str;

/**
 * Talks to Claude (Anthropic). One place for the key, the models, the spending limit and the usage log.
 * Every call names the feature it is for, so Admin can see where the money goes.
 */
class Ai
{
    /** The feature is switched on and can run (has a key if it needs one, monthly limit not reached). */
    public static function enabled(string $feature): bool
    {
        $s = AiSetting::current();
        if (! $s->isOn($feature)) {
            return false;
        }
        $needsKey = AiFeatures::ALL[$feature][3] ?? true;

        return ! $needsKey || ($s->hasKey() && ! static::overLimit());
    }

    /** The feature is switched on (it may still be paused by the limit or a missing key). */
    public static function switchedOn(string $feature): bool
    {
        return AiSetting::current()->isOn($feature);
    }

    public static function overLimit(): bool
    {
        $limit = (float) AiSetting::current()->monthly_limit;

        return $limit > 0 && AiUsage::spentThisMonth() >= $limit;
    }

    public static function model(string $kind): string
    {
        $s = AiSetting::current();

        return $kind === 'smart' ? ($s->model_smart ?: 'claude-sonnet-5-5') : ($s->model_fast ?: 'claude-haiku-5-5');
    }

    /**
     * One request to Claude. Returns the full response (content blocks, stop_reason, usage).
     *
     * @param  array<int, array{role: string, content: mixed}>  $messages
     * @param  array<int, array<string, mixed>>  $tools
     */
    public static function call(string $feature, string $system, array $messages, string $kind = 'fast', int $maxTokens = 1024, array $tools = [], bool $check = true): array
    {
        $s = AiSetting::current();
        if ($check && ! static::enabled($feature)) {
            throw new AiUnavailable(static::whyOff($feature));
        }
        if (! $s->hasKey()) {
            throw new AiUnavailable('Add the AI key in Admin → Settings → AI first.');
        }

        $model = static::model($kind);
        $body = ['model' => $model, 'max_tokens' => $maxTokens, 'system' => $system, 'messages' => $messages];
        if ($tools) {
            $body['tools'] = $tools;
        }

        try {
            $res = Http::withHeaders([
                'x-api-key' => $s->api_key,
                'anthropic-version' => config('ai.version'),
            ])->acceptJson()->timeout(config('ai.timeout'))->post(config('ai.url'), $body);
        } catch (ConnectionException $e) {
            static::log($feature, $model, 0, 0, false, 'No connection');
            throw new AiUnavailable('The AI could not be reached. Check the internet connection and try again.');
        }

        if (! $res->successful()) {
            $msg = (string) ($res->json('error.message') ?? 'HTTP '.$res->status());
            static::log($feature, $model, 0, 0, false, Str::limit($msg, 240));
            throw new AiUnavailable(match (true) {
                $res->status() === 401 => 'The AI key was not accepted. Check it in Admin → Settings → AI.',
                $res->status() === 404 => "The AI model \"{$model}\" was not found. Check the model names in Admin → Settings → AI.",
                $res->status() === 429 => 'The AI is busy (too many requests). Try again in a minute.',
                $res->status() === 400 && str_contains($msg, 'credit') => 'Your Anthropic account has no credit left. Add credit in the Anthropic Console.',
                default => 'The AI could not answer: '.Str::limit($msg, 160),
            });
        }

        $data = $res->json();
        static::log($feature, $model, (int) data_get($data, 'usage.input_tokens', 0), (int) data_get($data, 'usage.output_tokens', 0), true);

        return $data;
    }

    /** Ask and get the text answer. */
    public static function text(string $feature, string $system, string|array $content, string $kind = 'fast', int $maxTokens = 1024): string
    {
        $data = static::call($feature, $system, [['role' => 'user', 'content' => $content]], $kind, $maxTokens);

        return static::textOf($data);
    }

    /** Ask for JSON and get it as an array. */
    public static function json(string $feature, string $system, string|array $content, string $kind = 'fast', int $maxTokens = 1024): array
    {
        $text = static::text($feature, $system."\n\nReply with JSON only, no other text.", $content, $kind, $maxTokens);

        return static::parseJson($text);
    }

    public static function textOf(array $data): string
    {
        return trim(collect($data['content'] ?? [])->where('type', 'text')->pluck('text')->join("\n"));
    }

    public static function parseJson(string $text): array
    {
        $text = trim(preg_replace('/^```(?:json)?|```$/m', '', $text));
        $start = strcspn($text, '{[');
        $json = json_decode(substr($text, $start), true);
        if (! is_array($json)) {
            // cut after the last closing bracket and try again
            $end = max(strrpos($text, '}') ?: 0, strrpos($text, ']') ?: 0);
            $json = json_decode(substr($text, $start, $end - $start + 1), true);
        }
        if (! is_array($json)) {
            throw new AiUnavailable('The AI answer could not be read. Try again.');
        }

        return $json;
    }

    /** A picture for Claude to look at. */
    public static function image(string $disk, string $path): ?array
    {
        if (! Storage::disk($disk)->exists($path)) {
            return null;
        }
        $bytes = Storage::disk($disk)->get($path);
        $type = (new \finfo(FILEINFO_MIME_TYPE))->buffer($bytes) ?: 'image/jpeg';
        if (! in_array($type, ['image/jpeg', 'image/png', 'image/gif', 'image/webp'], true)) {
            return null;
        }

        return ['type' => 'image', 'source' => ['type' => 'base64', 'media_type' => $type, 'data' => base64_encode($bytes)]];
    }

    public static function whyOff(string $feature): string
    {
        $s = AiSetting::current();

        return match (true) {
            ! $s->isOn($feature) => AiFeatures::title($feature).' is switched off in Admin → Settings → AI.',
            ! $s->hasKey() => 'Add the AI key in Admin → Settings → AI first.',
            static::overLimit() => 'This month\'s AI spending limit is reached. Raise it in Admin → Settings → AI.',
            default => 'AI is not available right now.',
        };
    }

    public static function cost(string $model, int $in, int $out): float
    {
        $prices = config('ai.prices');
        $p = $prices[$model] ?? collect($prices)->first(fn ($v, $k) => $k !== 'default' && str_starts_with($model, $k)) ?? $prices['default'];

        return round(($in * $p[0] + $out * $p[1]) / 1_000_000, 5);
    }

    protected static function log(string $feature, string $model, int $in, int $out, bool $ok, ?string $error = null): void
    {
        try {
            AiUsage::create([
                'feature' => $feature, 'model' => $model, 'input_tokens' => $in, 'output_tokens' => $out,
                'cost' => static::cost($model, $in, $out), 'ok' => $ok, 'error' => $error,
                'user_id' => Auth::id(), 'created_at' => now(),
            ]);
        } catch (\Throwable) {
            // never let the usage log stop the work
        }
    }
}
