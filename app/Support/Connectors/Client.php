<?php

namespace App\Support\Connectors;

use App\Models\Connectors\ConnectorLink;
use Illuminate\Http\Client\Response;
use Illuminate\Support\Facades\Http;
use RuntimeException;

/** Calls a consolidator's connector (push mode). Every call is signed. */
class Client
{
    public function __construct(protected ConnectorLink $link) {}

    public static function base(string $url): string
    {
        $url = rtrim(trim($url), '/');

        return preg_replace('#/api/v1$#', '', $url);
    }

    /**
     * Pair with the code shown on their connector. Returns the connector's answer
     * (token, secret, key_id, connector{…}); the caller stores it encrypted.
     *
     * @return array<string, mixed>
     */
    public static function pair(string $url, string $code): array
    {
        try {
            $res = Http::acceptJson()->timeout(20)->post(static::base($url).'/api/v1/pair', [
                'code' => strtoupper(trim($code)),
                'dispatch_url' => rtrim((string) config('app.url'), '/'),
                'dispatch_name' => (string) config('app.name', 'Dispatch System'),
            ]);
        } catch (\Illuminate\Http\Client\ConnectionException $e) {
            throw new RuntimeException(static::short($e->getMessage(), static::base($url)), 0, $e);
        }
        if ($res->status() !== 201) {
            throw new RuntimeException($res->json('message') ?: 'The connector answered HTTP '.$res->status());
        }
        $data = $res->json();
        foreach (['token', 'secret', 'key_id'] as $k) {
            if (blank($data[$k] ?? null)) {
                throw new RuntimeException('The connector did not send a '.$k);
            }
        }

        return $data;
    }

    /** @return array<mixed> */
    public function get(string $path, int $timeout = 20): array
    {
        return $this->call('GET', $path, null, $timeout)->json() ?? [];
    }

    /** @return array<mixed> */
    public function send(string $method, string $path, array $data, int $timeout = 30): array
    {
        return $this->call($method, $path, $data, $timeout)->json() ?? [];
    }

    /** The raw answer (Sender reads Retry-After and HTTP 503 itself). */
    public function call(string $method, string $path, ?array $data = null, int $timeout = 30): Response
    {
        if (! $this->link->isPaired() || blank($this->link->token)) {
            throw new RuntimeException('Not paired yet');
        }
        if (blank($this->link->url)) {
            throw new RuntimeException('No connector address (pull mode: their connector asks us)');
        }
        $url = static::base($this->link->url).$path;
        $body = $data === null ? '' : json_encode($data, JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE);
        $time = time();
        $req = Http::withToken((string) $this->link->token)->acceptJson()->timeout($timeout)->connectTimeout(8)->withHeaders([
            Signer::TIME => (string) $time,
            Signer::SIGN => Signer::make((string) $this->link->secret, $time, $method, Signer::pathOf($url), $body),
        ]);
        try {
            $res = match ($method) {
                'GET' => $req->get($url),
                default => $req->withBody($body, 'application/json')->send($method, $url),
            };
        } catch (\Illuminate\Http\Client\ConnectionException $e) {
            throw new RuntimeException(static::short($e->getMessage(), $url), 0, $e);
        }
        if ($res->status() === 401) {
            throw new RuntimeException('The connector refused our token or signature: '.($res->json('message') ?: 'HTTP 401'));
        }
        if (! $res->successful() && $res->status() !== 503) {
            throw new ConnectorError($res->json('message') ?: 'The connector answered HTTP '.$res->status().' for '.parse_url($url, PHP_URL_PATH), $res->status(), $res->json() ?: []);
        }

        return $res;
    }

    /** A cURL error in plain words, with the address that was tried and the original reason. */
    public static function short(string $error, ?string $url = null): string
    {
        $host = $url ? (parse_url($url, PHP_URL_HOST) ?: $url) : 'the connector';
        $why = match (true) {
            str_contains($error, 'cURL error 6') => "$host was not found (DNS): this server cannot look up that name yet",
            str_contains($error, 'cURL error 7') => "Could not connect to $host (server down or port closed)",
            str_contains($error, 'cURL error 28') => "$host did not answer in time",
            str_contains($error, 'cURL error 60'), str_contains($error, 'cURL error 35') => "HTTPS problem on $host: its certificate is not trusted from this server (often the chain, the CA bundle, is missing)",
            default => null,
        };
        preg_match('/cURL error (\d+): ([^(]{0,120})/', $error, $m);
        $raw = $m ? ' [cURL '.$m[1].': '.trim($m[2]).']' : '';

        return $why ? $why.$raw : mb_substr($error, 0, 200);
    }
}
