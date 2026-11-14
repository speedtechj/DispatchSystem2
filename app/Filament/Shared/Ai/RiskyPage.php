<?php

namespace App\Filament\Shared\Ai;

use App\Models\Ai\AiRiskMark;
use App\Models\Tripinvoice;
use App\Services\TripAssignment;
use App\Support\Ai\AiUnavailable;
use App\Support\Ai\Risk;
use BackedEnum;
use Filament\Notifications\Notification;
use Filament\Support\Icons\Heroicon;
use Illuminate\Support\Collection;
use Illuminate\Support\Facades\Auth;
use Throwable;

/** Risky deliveries: boxes on active trips that will likely fail, so the office can text the receiver first. */
abstract class RiskyPage extends AiPage
{
    protected string $view = 'filament.ai.risky';

    protected static string $feature = 'risky';

    protected static string|BackedEnum|null $navigationIcon = Heroicon::OutlinedExclamationTriangle;

    protected static ?string $navigationLabel = 'Risky deliveries';

    protected static ?string $title = 'Risky deliveries';

    protected static ?string $slug = 'ai-risky';

    protected static ?int $navigationSort = 4;

    public ?int $sel = null;

    public string $lang = 'en';

    public string $message = '';

    public ?string $error = null;

    /** @return Collection<int, array{box: Tripinvoice, risk: array, mark: ?AiRiskMark}> */
    protected function risky(): Collection
    {
        $hub = $this->hub();
        $refusals = Risk::pastRefusals();
        $boxes = Tripinvoice::query()->where('is_delivered', false)
            ->whereHas('deliverylog', fn ($q) => $q->where('is_active', true))
            ->when($hub, fn ($q) => $q->where('logistichub_id', $hub))
            ->with(['invdata', 'deliverylog.truck', 'deliveryAttempts'])->limit(1500)->get();
        $marks = AiRiskMark::whereIn('tripinvoice_id', $boxes->pluck('id'))->get()->keyBy('tripinvoice_id');

        return $boxes->map(fn ($b) => ['box' => $b, 'risk' => Risk::of($b, $b->deliveryAttempts, $refusals), 'mark' => $marks[$b->id] ?? null])
            ->filter(fn ($r) => $r['risk']['score'] >= Risk::SHOW_FROM)
            ->sortByDesc(fn ($r) => $r['risk']['score'])->values();
    }

    public function pick(int $id): void
    {
        $this->sel = $id;
        $this->message = AiRiskMark::where('tripinvoice_id', $id)->value('message') ?? '';
        $this->error = null;
    }

    protected function box(): ?Tripinvoice
    {
        $hub = $this->hub();

        return $this->sel ? Tripinvoice::when($hub, fn ($q) => $q->where('logistichub_id', $hub))->with(['invdata', 'deliverylog'])->find($this->sel) : null;
    }

    public function write(): void
    {
        if (! $box = $this->box()) {
            return;
        }
        $this->error = null;
        try {
            $this->message = Risk::message($box, $this->lang);
        } catch (AiUnavailable $e) {
            $this->error = $e->getMessage();
        }
    }

    public function markTexted(): void
    {
        if (! $box = $this->box()) {
            return;
        }
        AiRiskMark::updateOrCreate(['tripinvoice_id' => $box->id], ['status' => 'texted', 'message' => $this->message, 'user_id' => Auth::id()]);
        Notification::make()->title("Box {$box->invoice} marked as texted")->success()->send();
    }

    public function markOk(): void
    {
        if (! $box = $this->box()) {
            return;
        }
        AiRiskMark::updateOrCreate(['tripinvoice_id' => $box->id], ['status' => 'ok', 'user_id' => Auth::id()]);
    }

    public function removeFromTrip(): void
    {
        if (! $box = $this->box()) {
            return;
        }
        if ($box->is_loaded) {
            Notification::make()->title('Already loaded on the truck')->body('Unload it and scan it at Return Boxes instead.')->warning()->send();

            return;
        }
        try {
            app(TripAssignment::class)->removeFromDeliveryTrip($box);
            AiRiskMark::updateOrCreate(['tripinvoice_id' => $box->id], ['status' => 'removed', 'user_id' => Auth::id()]);
            Notification::make()->title("Box {$box->invoice} taken off trip {$box->deliverylog?->trip_number}")->success()->send();
            $this->sel = null;
        } catch (Throwable $e) {
            Notification::make()->title('Could not take it off the trip')->body($e->getMessage())->danger()->send();
        }
    }

    protected function getViewData(): array
    {
        $list = $this->risky();
        if (! $this->sel && $list->isNotEmpty()) {
            $this->pick($list->first()['box']->id);
        }
        $sel = $list->first(fn ($r) => $r['box']->id === $this->sel);

        return ['paused' => $this->pausedReason(), 'list' => $list, 'cur' => $sel];
    }
}
