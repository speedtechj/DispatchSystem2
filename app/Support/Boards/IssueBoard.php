<?php

namespace App\Support\Boards;

use App\Models\Invoice;
use App\Models\Invoiceissue;
use App\Models\Unmanifested;
use Illuminate\Database\Eloquent\Builder;
use Illuminate\Support\Collection;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Storage;

/** Box problems reported while unloading, and unmanifested boxes. Cards: this week. Charts: last 30 days. */
class IssueBoard extends Board
{
    public function __construct(protected ?int $warehouseId = null) {}

    protected function inScope(Builder $query): Builder
    {
        return $query->when($this->warehouseId, fn (Builder $q) => $q->whereHas('container', fn (Builder $c) => $c->where('warehouse_id', $this->warehouseId)));
    }

    protected function issues(): Builder
    {
        return $this->inScope(Invoiceissue::query());
    }

    public function cards(): array
    {
        $week = now()->startOfWeek();
        $lastWeek = $week->copy()->subWeek();

        $thisWeek = $this->issues()->where('created_at', '>=', $week)->count();
        $before = $this->issues()->whereBetween('created_at', [$lastWeek, $week])->count();
        $unmanifested = $this->inScope(Unmanifested::query())->where('created_at', '>=', $week)->count();
        $containers = $this->issues()->where('created_at', '>=', $week)->distinct()->count('container_id');

        $scanned = Invoice::where('verified_at', '>=', $week)
            ->when($this->warehouseId, fn (Builder $q) => $q->whereHas('container', fn (Builder $c) => $c->where('warehouse_id', $this->warehouseId)))
            ->count();

        $diff = $thisWeek - $before;

        return [
            static::card('Issues this week', $thisWeek, $diff === 0 ? 'Same as last week' : abs($diff).($diff > 0 ? ' more' : ' fewer').' than last week', 'warn'),
            static::card('Unmanifested boxes', $unmanifested, 'Scanned but not on a manifest', 'bad'),
            static::card('Containers with issues', $containers, 'This week', 'navy'),
            // Too few boxes give a misleading rate (1 issue in 1 box = 1,000 per 1,000).
            $scanned >= 100
                ? static::card('Issues per 1,000 boxes', round($thisWeek / $scanned * 1000, 1), number_format($scanned).' boxes scanned this week', 'steel')
                : static::card('Issues per 1,000 boxes', '—', 'Shows after 100 boxes are scanned this week ('.number_format($scanned).' so far)', 'steel'),
        ];
    }

    public function charts(): array
    {
        $since = now()->subDays(30);

        $byType = DB::table('invoiceissues')
            ->leftJoin('boxissues', 'boxissues.id', '=', 'invoiceissues.boxissue_id')
            ->when($this->warehouseId, fn ($q) => $q->join('containers', 'containers.id', '=', 'invoiceissues.container_id')->where('containers.warehouse_id', $this->warehouseId))
            ->where('invoiceissues.created_at', '>=', $since)
            ->selectRaw("COALESCE(boxissues.issue_type, 'Other') as label, count(*) as n")
            ->groupBy('label')->orderByDesc('n')->limit(5)->get()
            ->map(fn ($r) => ['label' => $r->label, 'count' => (int) $r->n]);

        $byContainer = DB::table('invoiceissues')
            ->join('containers', 'containers.id', '=', 'invoiceissues.container_id')
            ->leftJoin('consolidators', 'consolidators.id', '=', 'containers.consolidator_id')
            ->when($this->warehouseId, fn ($q) => $q->where('containers.warehouse_id', $this->warehouseId))
            ->where('invoiceissues.created_at', '>=', $since)
            ->selectRaw("containers.container_no as no, COALESCE(consolidators.company_name, '') as by_name, count(*) as n")
            ->groupBy('containers.container_no', 'consolidators.company_name')->orderByDesc('n')->limit(5)->get()
            ->map(fn ($r) => ['label' => trim($r->no.($r->by_name ? ' · '.$r->by_name : '')), 'count' => (int) $r->n]);

        return [
            ['type' => 'bars', 'title' => 'Issues by type', 'note' => 'Last 30 days', 'rows' => $byType, 'tone' => 'warn', 'empty' => 'No problems reported in the last 30 days.'],
            ['type' => 'bars', 'title' => 'Containers with the most issues', 'note' => 'Last 30 days', 'rows' => $byContainer, 'tone' => 'bad', 'empty' => 'No problems reported in the last 30 days.'],
        ];
    }

    public function photosTitle(): string
    {
        return 'Open issues';
    }

    /** Issues whose box is not marked resolved yet (Resolved switch in the list). */
    public function openIssues(): Builder
    {
        return $this->issues()->whereDoesntHave('invdata', fn (Builder $q) => $q->where('is_resolved', true));
    }

    /** Every open issue, newest first, for the slider. Resolved ones drop out. */
    public function photos(): Collection
    {
        return $this->openIssues()->with(['boxissue:id,issue_type', 'container:id,container_no'])->latest()->get()
            ->map(function (Invoiceissue $issue) {
                $pic = $issue->attachment_pic;
                $path = is_array($pic) ? (array_values($pic)[0] ?? null) : $pic;

                return [
                    'id' => $issue->id,
                    'url' => $path && Storage::disk('public')->exists($path) ? Storage::disk('public')->url($path) : null,
                    'title' => $issue->invoice,
                    'label' => $issue->boxissue?->issue_type ?? 'Problem',
                    'meta' => trim(($issue->container?->container_no ?? '').' · '.$issue->created_at?->diffForHumans(['parts' => 1]), ' ·'),
                    'note' => str(strip_tags((string) $issue->remarks))->squish()->limit(90)->toString(),
                ];
            });
    }

    /** Mark the box of one open issue resolved. Returns the invoice number, or null if not found. */
    public function resolve(int $issueId): ?string
    {
        $issue = $this->openIssues()->with('invdata')->find($issueId);

        if (! $issue || ! $issue->invdata) {
            return null;
        }

        $issue->invdata->forceFill(['is_resolved' => true])->save();

        return $issue->invoice;
    }

    public function openCount(): int
    {
        return $this->openIssues()->count();
    }
}
