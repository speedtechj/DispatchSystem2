<?php

namespace App\Filament\Pages;

use App\Models\Ai\AgingLimit;
use App\Support\Aging\AgingNotifier;
use App\Support\Aging\BoxAging;
use App\Support\Aging\LimitSuggester;
use App\Support\Aging\Regions;
use App\Support\Ai\Ai;
use BackedEnum;
use Filament\Notifications\Notification;
use Filament\Pages\Page;
use Filament\Support\Icons\Heroicon;
use Illuminate\Support\Facades\Auth;
use UnitEnum;

/** Admin → Settings → Aging limits: warning and late days per stage, suggested from your history; who gets the morning summary. */
class AgingLimits extends Page
{
    protected string $view = 'filament.pages.aging-limits';

    protected static string|UnitEnum|null $navigationGroup = 'Settings';

    protected static string|BackedEnum|null $navigationIcon = Heroicon::OutlinedClock;

    protected static ?string $navigationLabel = 'Aging limits';

    protected static ?string $title = 'Aging limits';

    protected static ?string $slug = 'aging-limits';

    public array $rows = [];

    public bool $suggested = false;

    public bool $mailAdmin = true;

    public bool $mailWarehouse = false;

    public bool $mailHub = false;

    public int $hour = 7;

    public static function canAccess(): bool
    {
        return (bool) Auth::user()?->hasRole('super_admin') && Ai::switchedOn('aging');
    }

    public function getSubheading(): ?string
    {
        return 'A box is "warning" after the first number of days at a stage and "late" after the second. The total counts from unload to delivered.';
    }

    public function mount(): void
    {
        $this->loadCurrent();
        $s = AgingNotifier::settings();
        $this->mailAdmin = (bool) $s['mail_admin'];
        $this->mailWarehouse = (bool) $s['mail_warehouse'];
        $this->mailHub = (bool) $s['mail_hub'];
        $this->hour = (int) $s['hour'];
    }

    protected function loadCurrent(): void
    {
        $limits = BoxAging::limits();
        $rows = [];
        foreach (array_keys(BoxAging::STAGES) as $stage) {
            foreach (array_keys($limits[$stage] ?? ['all' => 0]) as $region) {
                $rows[] = ['stage' => $stage, 'region' => $region, 'warn' => $limits[$stage][$region][0], 'late' => $limits[$stage][$region][1], 'usual' => '—', 'n' => null, 'reason' => AgingLimit::where(['stage' => $stage, 'region' => $region])->value('reason') ?? 'Standard limit.'];
            }
        }
        foreach (array_keys(Regions::LABELS) as $region) {
            $l = BoxAging::limitFor(BoxAging::TOTAL, $region);
            $rows[] = ['stage' => BoxAging::TOTAL, 'region' => $region, 'warn' => $l[0], 'late' => $l[1], 'usual' => '—', 'n' => null, 'reason' => AgingLimit::where(['stage' => 'total', 'region' => $region])->value('reason') ?? 'Standard limit.'];
        }
        $this->rows = array_map(fn ($r) => $r + ['orig' => [$r['warn'], $r['late']]], $rows);
        $this->suggested = false;
    }

    public function suggest(): void
    {
        $this->rows = array_map(fn ($r) => $r + ['orig' => [$r['warn'], $r['late']]], LimitSuggester::suggest());
        $this->suggested = true;
    }

    public function bump(int $i, string $field, int $by): void
    {
        if (! isset($this->rows[$i]) || ! in_array($field, ['warn', 'late'], true)) {
            return;
        }
        $this->rows[$i][$field] = max(1, min(120, (int) $this->rows[$i][$field] + $by));
        if ($this->rows[$i]['late'] <= $this->rows[$i]['warn']) {
            $field === 'warn' ? $this->rows[$i]['late'] = $this->rows[$i]['warn'] + 1 : $this->rows[$i]['warn'] = max(1, $this->rows[$i]['late'] - 1);
        }
    }

    public function save(): void
    {
        foreach ($this->rows as $r) {
            AgingLimit::updateOrCreate(['stage' => $r['stage'], 'region' => $r['region']], ['warn_days' => $r['warn'], 'late_days' => $r['late'], 'reason' => mb_substr((string) $r['reason'], 0, 250)]);
        }
        $this->saveNotify(false);
        $this->loadCurrent();
        Notification::make()->title('Aging limits saved')->body('Box aging uses them from now on.')->success()->send();
    }

    public function saveNotify(bool $tell = true): void
    {
        AgingNotifier::saveSettings(['mail_admin' => $this->mailAdmin, 'mail_warehouse' => $this->mailWarehouse, 'mail_hub' => $this->mailHub, 'hour' => max(0, min(23, $this->hour))]);
        if ($tell) {
            Notification::make()->title('Saved')->success()->send();
        }
    }

    public function sendNow(): void
    {
        $this->saveNotify(false);
        $n = AgingNotifier::sendSummaries();
        Notification::make()->title("Morning summary sent to {$n} ".str('person')->plural($n))->success()->send();
    }

    protected function getViewData(): array
    {
        return [
            'stageLabels' => BoxAging::STAGES + ['total' => 'Total: unload → delivered'],
            'regionLabels' => ['all' => 'All places'] + Regions::LABELS,
            'changed' => collect($this->rows)->filter(fn ($r) => [$r['warn'], $r['late']] !== $r['orig'])->count(),
        ];
    }
}
