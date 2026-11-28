<?php

namespace App\Support\Connectors;

/**
 * The signature between Dispatch System and a connector (same as the connector's Signature):
 *   X-Connector-Signature: sha256=HMAC_SHA256(secret, time \n METHOD \n /path?query \n sha256(body))
 */
class Signer
{
    public const TIME = 'X-Connector-Time';

    public const SIGN = 'X-Connector-Signature';

    public const KEY = 'X-Connector-Key';

    public const WINDOW = 300;

    public static function make(string $secret, int $time, string $method, string $path, string $body): string
    {
        $path = '/'.ltrim($path, '/');

        return 'sha256='.hash_hmac('sha256', $time."\n".strtoupper($method)."\n".$path."\n".hash('sha256', $body), $secret);
    }

    public static function valid(string $secret, ?string $given, int $time, string $method, string $path, string $body): bool
    {
        return is_string($given) && hash_equals(static::make($secret, $time, $method, $path, $body), $given);
    }

    /** /path?query of a full URL. */
    public static function pathOf(string $url): string
    {
        $q = parse_url($url, PHP_URL_QUERY);

        return (parse_url($url, PHP_URL_PATH) ?: '/').($q ? '?'.$q : '');
    }
}
