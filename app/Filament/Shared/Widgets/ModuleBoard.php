<?php

namespace App\Filament\Shared\Widgets;

use App\Support\Boards\Board;
use App\Support\Boards\ContainerBoard;
use App\Support\Boards\IssueBoard;
use App\Support\Boards\VehicleBoard;
use Filament\Facades\Filament;
use Filament\Notifications\Notification;
use Filament\Widgets\Widget;
use Illuminate\Database\Eloquent\Model;
use Illuminate\Support\Facades\Auth;
use Livewire\Attributes\Locked;
use Livewire\Attributes\On;

/**
 * Cards, "Needs attention" and charts on top of the Containers, Vehicles and
 * Invoice Issue lists. The numbers come from App\Support\Boards\*.
 *
 *   ModuleBoard::make(['board' => 'containers', 'resource' => ContainerResource::class])
 */
class ModuleBoard extends Widget
{
    protected string $view = 'filament.widgets.module-board';

    protected int|string|array $columnSpan = 'full';

    protected static bool $isLazy = false;

    /** containers, vehicles or issues */
    #[Locked]
    public string $board = 'containers';

    /** The list's resource, for links to each record. */
    #[Locked]
    public string $resource = '';

    public function makeBoard(): Board
    {
        $user = Auth::user();
        $warehouse = Filament::getCurrentPanel()?->getId() === 'warehouse' ? (int) $user->warehouse_id : null;

        return match ($this->board) {
            'containers' => new ContainerBoard($warehouse, $this->recordUrl(...)),
            'vehicles' => new VehicleBoard((int) $user->logistichub_id, $this->recordUrl(...)),
            'issues' => new IssueBoard($warehouse),
        };
    }

    public function recordUrl(Model $record): ?string
    {
        if (! $this->resource || ! class_exists($this->resource)) {
            return null;
        }

        foreach (['edit', 'view'] as $page) {
            if ($this->resource::hasPage($page)) {
                return $this->resource::getUrl($page, ['record' => $record]);
            }
        }

        return null;
    }

    /** "Mark resolved" on a slide in the Invoice Issue widget. */
    public function resolveIssue(int $issueId): void
    {
        $board = $this->makeBoard();

        if (! $board instanceof IssueBoard) {
            return;
        }

        $invoice = $board->resolve($issueId);

        if (! $invoice) {
            Notification::make()->title('That issue is already resolved')->warning()->send();

            return;
        }

        Notification::make()->title("{$invoice} marked resolved")->success()->send();
        $this->dispatch('issue-resolved'); // refresh the list under the widget
    }

    /** The Resolved switch in the list was changed: redraw so the slide appears or disappears. */
    #[On('issue-resolved')]
    public function refreshBoard(): void {}

    protected function getViewData(): array
    {
        $board = $this->makeBoard();

        return [
            'cards' => $board->cards(),
            'attention' => $board->attention(),
            'charts' => $board->charts(),
            'photos' => $board->photos(),
            'photosTitle' => $board->photosTitle(),
            'openCount' => $board instanceof IssueBoard ? $board->openCount() : null,
        ];
    }
}
