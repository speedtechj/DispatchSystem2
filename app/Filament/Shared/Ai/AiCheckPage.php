<?php

namespace App\Filament\Shared\Ai;

use App\Models\Ai\AiPhotoCheck;
use App\Support\Ai\PhotoCheck;
use BackedEnum;
use Filament\Notifications\Notification;
use Filament\Support\Icons\Heroicon;
use Illuminate\Database\Eloquent\Builder;
use Illuminate\Support\Facades\Auth;
use Livewire\Attributes\Url;

/** AI photo check: photos the AI thinks look damaged, wet, opened or blurry. A person decides. */
abstract class AiCheckPage extends AiPage
{
    protected string $view = 'filament.ai.check';

    protected static string $feature = 'photo_check';

    protected static string|BackedEnum|null $navigationIcon = Heroicon::OutlinedEye;

    protected static ?string $navigationLabel = 'AI photo check';

    protected static ?string $title = 'AI photo check';

    protected static ?string $slug = 'ai-photo-check';

    protected static ?int $navigationSort = 1;

    #[Url]
    public string $show = 'open';

    #[Url]
    public string $period = 'week';

    public ?int $sel = null;

    public static function getNavigationBadge(): ?string
    {
        $n = AiPhotoCheck::visibleTo(Auth::user())->where('flagged', true)->whereNull('decision')->count();

        return $n ? (string) $n : null;
    }

    protected function base(): Builder
    {
        $from = match ($this->period) {
            'today' => now()->startOfDay(),
            'month' => now()->subDays(30),
            default => now()->subDays(7),
        };

        return AiPhotoCheck::visibleTo(Auth::user())->where('created_at', '>=', $from);
    }

    public function pick(int $id): void
    {
        $this->sel = $id;
    }

    protected function selected(): ?AiPhotoCheck
    {
        return $this->sel ? AiPhotoCheck::visibleTo(Auth::user())->find($this->sel) : null;
    }

    public function confirmDamaged(): void
    {
        if (! $c = $this->selected()) {
            return;
        }
        $issue = PhotoCheck::confirm($c, Auth::user());
        Notification::make()->title($issue ? "Invoice Issue opened for box {$c->invoice}" : 'Marked as damaged')->success()->send();
    }

    public function looksFine(): void
    {
        if (! $c = $this->selected()) {
            return;
        }
        PhotoCheck::dismiss($c, Auth::user());
        Notification::make()->title('Marked as fine')->success()->send();
    }

    public function undoDecision(): void
    {
        if (($c = $this->selected()) && ! $c->invoiceissue_id) {
            $c->update(['decision' => null, 'decided_by' => null, 'decided_at' => null]);
        }
    }

    protected function getViewData(): array
    {
        $flagged = (clone $this->base())->where('flagged', true);
        $list = (clone $flagged)
            ->when($this->show === 'open', fn ($q) => $q->whereNull('decision'))
            ->when($this->show === 'missed', fn ($q) => $q->where('source', 'scan')->where(fn ($w) => $w->whereNull('worker_said')->orWhere('worker_said', 'good')))
            ->when($this->show === 'delivery', fn ($q) => $q->where('source', 'delivery'))
            ->latest('id')->limit(200)->get();

        $sel = $this->selected() ?? $list->first();
        $this->sel = $sel?->id;

        return [
            'paused' => $this->pausedReason(),
            'stats' => [
                'checked' => (clone $this->base())->whereNotNull('checked_at')->count(),
                'waiting' => (clone $this->base())->whereNull('checked_at')->count(),
                'flagged' => (clone $flagged)->count(),
                'missed' => (clone $flagged)->where('source', 'scan')->where(fn ($w) => $w->whereNull('worker_said')->orWhere('worker_said', 'good'))->count(),
                'decided' => (clone $flagged)->whereNotNull('decision')->count(),
            ],
            'list' => $list,
            'cur' => $sel,
        ];
    }
}
