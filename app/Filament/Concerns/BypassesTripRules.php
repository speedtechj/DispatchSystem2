<?php

namespace App\Filament\Concerns;

use App\Models\Invoice;
use App\Support\Trips\TripRules;
use Illuminate\Support\Facades\Auth;

/**
 * "Load it anyway" on a scan station: free, with a reason, or ask the office (trip rules).
 * Needs $early / $wrongHub / $forceLoad, the scan() method and the selected trip in data.deliverylog_id.
 */
trait BypassesTripRules
{
    /** ['rule', 'code', 'need' => reason|office] while the reason buttons show. */
    public ?array $bypass = null;

    protected function tripKind(): string
    {
        return 'delivery';
    }

    protected function bypassContext(string $code): array
    {
        $tripId = (int) ($this->data['deliverylog_id'] ?? 0) ?: null;
        $model = $this->tripKind() === 'transfer' ? \App\Models\Whdeliverylog::class : \App\Models\Deliverylog::class;

        return ['kind' => $this->tripKind(), 'trip_id' => $tripId, 'trip_number' => $tripId ? $model::whereKey($tripId)->value('trip_number') : null,
            'invoice_id' => Invoice::where('invoice', $code)->latest('id')->value('id'), 'box' => $code];
    }

    public function loadAnyway(): void
    {
        $code = $this->early['code'] ?? $this->wrongHub['code'] ?? null;
        if (! $code) {
            return;
        }
        $rule = TripRules::ruleOf($this->early ?? null, $this->wrongHub ?? null);
        $ctx = $this->bypassContext($code);
        $need = TripRules::need($rule, Auth::user(), $ctx['trip_id'], $ctx['invoice_id']);
        if ($need === 'free') {
            $this->forceScan($code);

            return;
        }
        $this->bypass = ['rule' => $rule, 'code' => $code, 'need' => $need];
    }

    public function bypassWith(string $reason): void
    {
        if (! $this->bypass || ! in_array($reason, TripRules::reasons(), true) || $this->bypass['need'] !== 'reason') {
            return;
        }
        $b = $this->bypass;
        TripRules::record($b['rule'], Auth::user(), $reason, $this->bypassContext($b['code']));
        $this->bypass = null;
        $this->forceScan($b['code']);
    }

    public function askOffice(?string $reason = null): void
    {
        if (! $this->bypass) {
            return;
        }
        $b = $this->bypass;
        TripRules::ask($b['rule'], Auth::user(), $reason, $this->bypassContext($b['code']));
        $this->bypass = null;
        $this->early = null;
        $this->wrongHub = null;
        $this->scanResult('warning', "Asked the office about {$b['code']}. Keep it aside: when they approve, scan it again.", Invoice::where('invoice', $b['code'])->latest('id')->first());
    }

    public function cancelBypass(): void
    {
        $this->bypass = null;
    }

    protected function forceScan(string $code): void
    {
        $this->forceLoad = true;
        $this->scan($code);
        $this->forceLoad = false;
    }

    /** Skip the check: forced now, or the office approved this box on this trip. */
    protected function skips(string $rule, ?int $tripId, ?int $invoiceId): bool
    {
        return $this->forceLoad || TripRules::isApproved($rule, $tripId, $invoiceId);
    }
}
