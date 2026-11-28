<?php

namespace App\Http\Controllers;

use App\Models\Connectors\ConnectorEvent;
use App\Models\Connectors\ConnectorLink;
use App\Support\Connectors\Rules;
use App\Support\Connectors\Sender;
use App\Support\Connectors\Signer;
use Illuminate\Http\Request;
use Symfony\Component\HttpFoundation\Response;
use Illuminate\Support\Facades\DB;

/**
 * What a consolidator's connector calls on Dispatch System (Part 47).
 * Pull mode: GET events, POST results. Both modes: GET hello.
 * Every request is signed with the pairing secret (X-Connector-Key / -Time / -Signature);
 * every answer is signed too (METHOD = RESPONSE, the path without the query).
 */
class ConnectorApiController extends Controller
{
    /** GET /api/connector/v1/events?after=CURSOR&limit=100 */
    public function events(Request $request): Response
    {
        $link = $this->check($request);
        if ($link instanceof Response) {
            return $link;
        }
        Sender::releaseHeld();
        Sender::resendLost();
        $limit = max(1, min(Rules::BATCH, (int) $request->query('limit', 100)));
        $rows = Sender::waiting($link)->orderBy('priority')->orderBy('id')->limit($limit + 1)->get();
        $more = $rows->count() > $limit;
        $rows = $rows->take($limit);
        $events = $rows->map(fn (ConnectorEvent $e) => Sender::payload($e))->values()->all();
        if ($rows->isNotEmpty()) {
            ConnectorEvent::query()->whereKey($rows->modelKeys())->update(['state' => 'sent', 'sent_at' => now(), 'tries' => DB::raw('tries + 1'), 'updated_at' => now()]);
        }
        $cursor = max((int) $link->pull_cursor, (int) ($rows->max('id') ?? 0));
        $link->forceFill(['pull_cursor' => $cursor, 'state' => 'online', 'last_seen_at' => now(), 'fails' => 0, 'paused_at' => null])->save();

        return $this->answer($request, ['events' => $events, 'cursor' => (string) $cursor, 'more' => $more]);
    }

    /** POST /api/connector/v1/results  {results: [...]} */
    public function results(Request $request): Response
    {
        $link = $this->check($request);
        if ($link instanceof Response) {
            return $link;
        }
        $results = $request->json('results');
        $n = Sender::applyResults($link, is_array($results) ? $results : []);
        $link->forceFill(['last_seen_at' => now(), 'last_results_at' => now()])->save();

        return $this->answer($request, ['ok' => true, 'applied' => $n]);
    }

    /** GET /api/connector/v1/hello (asked every hour): newest connector version and what we offer. */
    public function hello(Request $request): Response
    {
        $link = $this->check($request);
        if ($link instanceof Response) {
            return $link;
        }
        $link->forceFill(['last_seen_at' => now()] + ($link->state === 'setup' ? ['state' => 'online'] : []))->save();

        return $this->answer($request, [
            'latest_version' => (string) config('connectors.latest_version', '2.5.0'),
            'min_version' => (string) config('connectors.min_version', '2.0.0'),
            'features' => ['explain' => false],
        ]);
    }

    /** The key id, a fresh time and a valid signature, or a refusal. */
    protected function check(Request $request): ConnectorLink|Response
    {
        $key = (string) $request->header(Signer::KEY);
        $link = $key === '' ? null : ConnectorLink::query()->where('key_id', $key)->first();
        if (! $link || blank($link->secret) || $link->state === 'off') {
            return response()->json(['message' => 'Unknown key'], 401);
        }
        $time = (string) $request->header(Signer::TIME);
        if (! ctype_digit($time) || abs(time() - (int) $time) > Signer::WINDOW) {
            return response()->json(['message' => 'Request too old or clock off'], 401);
        }
        if (! Signer::valid((string) $link->secret, $request->header(Signer::SIGN), (int) $time, $request->method(), $request->getRequestUri(), $request->getContent())) {
            return response()->json(['message' => 'Bad signature'], 401);
        }
        if ($link->mode !== 'pull' && $request->is('api/connector/v1/events')) {
            $link->forceFill(['mode' => 'pull'])->save(); // their connector is set to pull: follow it
        }
        $request->attributes->set('connector_link', $link);

        return $link;
    }

    protected function answer(Request $request, array $data): Response
    {
        $link = $request->attributes->get('connector_link');
        $body = json_encode($data, JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE);
        $time = time();

        return response($body, 200, [
            'Content-Type' => 'application/json',
            Signer::TIME => (string) $time,
            Signer::SIGN => Signer::make((string) $link->secret, $time, 'RESPONSE', '/'.ltrim($request->path(), '/'), $body),
        ]);
    }
}
