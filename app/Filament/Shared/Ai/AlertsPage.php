<?php

namespace App\Filament\Shared\Ai;

use App\Models\Ai\AiAlert;
use App\Support\Ai\Alerts;
use BackedEnum;
use Filament\Facades\Filament;
use Filament\Support\Icons\Heroicon;
use Illuminate\Support\Facades\Auth;
use Livewire\Attributes\Url;

/** Alerts: unusual scans and deliveries, and receivers who asked for a call. */
abstract class AlertsPage extends AiPage
{
    protected string $view = 'filament.ai.alerts';

    protected static string $feature = 'alerts';

    protected static string|BackedEnum|null $navigationIcon = Heroicon::OutlinedBellAlert;

    protected static ?string $navigationLabel = 'Alerts';

    protected static ?string $title = 'Alerts';

    protected static ?string $slug = 'ai-alerts';

    protected static ?int $navigationSort = 5;

    #[Url]
    public string $kind = '';

    #[Url]
    public string $status = 'open';

    public static function getNavigationBadge(): ?string
    {
        $n = AiAlert::visibleTo(Auth::user())->where('status', 'open')->count();

        return $n ? (string) $n : null;
    }

    public function handle(int $id, string $status): void
    {
        $alert = AiAlert::visibleTo(Auth::user())->find($id);
        if ($alert && in_array($status, ['checked', 'ignored', 'open'], true)) {
            $alert->update(['status' => $status, 'handled_by' => $status === 'open' ? null : Auth::id(), 'handled_at' => $status === 'open' ? null : now()]);
        }
    }

    public function checkNow(): void
    {
        Alerts::run();
    }

    protected function getViewData(): array
    {
        $base = AiAlert::visibleTo(Auth::user());
        $kinds = ['' => 'All', 'drivers' => 'Drivers', 'warehouse' => 'Warehouse', 'trips' => 'Trips', 'customers' => 'Customers'];

        return [
            'kinds' => $kinds,
            'counts' => (clone $base)->where('status', 'open')->selectRaw('kind, count(*) as n')->groupBy('kind')->pluck('n', 'kind'),
            'list' => (clone $base)->when($this->kind, fn ($q) => $q->where('kind', $this->kind))
                ->when($this->status === 'open', fn ($q) => $q->where('status', 'open'), fn ($q) => $q->where('status', '!=', 'open'))
                ->orderByRaw("case severity when 'high' then 0 when 'mid' then 1 else 2 end")->latest('updated_at')->limit(200)->get(),
            'panelUrl' => rtrim(Filament::getCurrentPanel()?->getUrl() ?? url('/'), '/'),
        ];
    }
}
