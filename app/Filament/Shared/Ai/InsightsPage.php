<?php

namespace App\Filament\Shared\Ai;

use App\Models\Logistichub;
use App\Support\Ai\AiUnavailable;
use App\Support\Ai\Insights;
use BackedEnum;
use Filament\Support\Icons\Heroicon;
use Illuminate\Support\Facades\Auth;
use Livewire\Attributes\Url;

/** Insights: boxes expected in the coming weeks, and a weekly report per partner hub. */
abstract class InsightsPage extends AiPage
{
    protected string $view = 'filament.ai.insights';

    protected static string $feature = 'insights';

    protected static string|BackedEnum|null $navigationIcon = Heroicon::OutlinedPresentationChartLine;

    protected static ?string $navigationLabel = 'Insights';

    protected static ?string $title = 'Insights';

    protected static ?string $slug = 'ai-insights';

    protected static ?int $navigationSort = 6;

    #[Url]
    public ?int $hubId = null;

    public ?string $advice = null;

    public ?string $report = null;

    public ?string $error = null;

    protected function hubs()
    {
        $hub = $this->hub();

        return Logistichub::where('is_active', true)->where('is_company', true)
            ->when($hub, fn ($q) => $q->whereKey($hub))->orderBy('hub_name')->get();
    }

    protected function warehouseId(): ?int
    {
        $u = Auth::user();

        return $u->hasRole('super_admin') ? null : ($u->warehouse_id ?: null);
    }

    public function writeAdvice(bool $fresh = false): void
    {
        try {
            $this->advice = Insights::forecastAdvice($this->warehouseId(), $fresh);
        } catch (AiUnavailable $e) {
            $this->error = $e->getMessage();
        }
    }

    public function writeReport(bool $fresh = false): void
    {
        $hub = $this->hubs()->firstWhere('id', $this->hubId);
        if (! $hub) {
            return;
        }
        try {
            $this->report = Insights::hubReport($hub, $fresh);
        } catch (AiUnavailable $e) {
            $this->error = $e->getMessage();
        }
    }

    public function updatedHubId(): void
    {
        $this->report = null;
    }

    protected function getViewData(): array
    {
        $hubs = $this->hubs();
        if (! $this->hubId || ! $hubs->contains('id', $this->hubId)) {
            $this->hubId = $hubs->first()?->id;
        }
        $hub = $hubs->firstWhere('id', $this->hubId);
        $isHubUser = (bool) $this->hub();

        return [
            'paused' => $this->pausedReason(),
            'forecast' => $isHubUser ? null : Insights::forecast($this->warehouseId()),
            'hubs' => $hubs,
            'stats' => $hub ? Insights::hubStats($hub) : null,
        ];
    }
}
