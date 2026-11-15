<?php

namespace App\Filament\Shared;

use App\Filament\Concerns\ScansInvoices;
use App\Models\Boxes\WhCountScan;
use App\Models\Boxes\WhSection;
use App\Models\User;
use App\Support\Boxes\SectionCount;
use App\Support\Boxes\Sections;
use Filament\Pages\Page;
use Illuminate\Support\Collection;
use Illuminate\Support\Facades\Auth;

/** Scan app · Count a section: scan the boxes on it; boxes from elsewhere are moved here. */
class SectionCountStation extends Page
{
    use ScansInvoices;

    protected string $view = 'filament.pages.scaninvoice';

    protected static bool $shouldRegisterNavigation = false;

    public ?array $route = null;

    protected function selectionField(): ?string
    {
        return 'wh_section_id';
    }

    protected function selectionLabel(): string
    {
        return 'a section';
    }

    protected function section(): ?WhSection
    {
        return Sections::of(Auth::user()?->warehouse_id)->firstWhere('id', (int) ($this->data['wh_section_id'] ?? 0));
    }

    protected function handleScan(string $code): void
    {
        $s = $this->section();
        if (! $s) {
            $this->scanResult('danger', 'That section is not in your warehouse.');

            return;
        }
        if (str_starts_with($code, 'SEC-')) {
            $this->scanResult('warning', 'That is a section label. Scan the boxes on this section.');

            return;
        }
        $r = SectionCount::scan(SectionCount::open($s), $code, Auth::user()?->warehouse_id);
        $this->route = Sections::tile($s);
        $this->scanResult($r['status'], $r['message'], $r['invoice']);
    }

    public function progress(): array
    {
        $s = $this->section();
        if (! $s) {
            return ['loaded' => 0, 'total' => 0];
        }
        $c = SectionCount::current($s);
        if (! $c) {
            return ['loaded' => 0, 'total' => SectionCount::expected($s)->count()];
        }
        $r = SectionCount::result($c);

        return ['loaded' => $r['found'], 'total' => max($r['expected'], $r['found'])];
    }

    /** Done screen: what is missing, and close the count. */
    public function countResult(): ?array
    {
        $s = $this->section();

        $c = $s ? SectionCount::current($s) : null;

        return $c ? SectionCount::result($c) + ['code' => $s->code] : null;
    }

    public function closeCount(): ?array
    {
        $s = $this->section();

        $c = $s ? SectionCount::current($s) : null;

        return $c ? SectionCount::finish($c) : null;
    }

    public function team(): array
    {
        $s = $this->section();
        if (! $s) {
            return [];
        }
        $c = SectionCount::current($s);
        if (! $c) {
            return [];
        }
        $counts = WhCountScan::where('wh_count_id', $c->id)->whereNotNull('user_id')->selectRaw('user_id, count(*) n')->groupBy('user_id')->pluck('n', 'user_id');
        $names = User::whereIn('id', $counts->keys())->pluck('first_name', 'id');

        return $counts->sortDesc()->map(fn ($n, $uid) => ['name' => (int) $uid === Auth::id() ? 'You' : ($names[$uid] ?? '?'), 'n' => (int) $n, 'me' => (int) $uid === Auth::id()])->values()->all();
    }

    public function household(): array
    {
        return [];
    }

    public function photoStep(): ?string
    {
        return null;
    }

    public function photoContext(): array
    {
        return [];
    }

    public function appChoices(): Collection
    {
        return Sections::of(Auth::user()?->warehouse_id)->map(fn (WhSection $s) => [
            'id' => $s->id, 'name' => 'Section '.$s->code.' · '.$s->name, 'active' => true,
            'sub' => SectionCount::expected($s)->count().' boxes here',
        ])->values();
    }
}
