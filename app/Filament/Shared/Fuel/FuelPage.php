<?php

namespace App\Filament\Shared\Fuel;

use App\Models\Fuel\FuelFill;
use App\Models\Fuel\FuelStatement;
use App\Models\Fuel\FuelStatementLine;
use App\Support\Fuel\Fuel;
use App\Support\Fuel\FuelReport;
use App\Support\Fuel\FuelStatements;
use App\Support\Tracking\Tracker;
use BackedEnum;
use Filament\Facades\Filament;
use Filament\Notifications\Notification;
use Filament\Pages\Page;
use Filament\Support\Icons\Heroicon;
use Illuminate\Support\Facades\Auth;
use Livewire\Attributes\Url;
use Livewire\WithFileUploads;

/**
 * Fuel: what each truck used and spent, alerts, fuel card statements, this week's price
 * and VAT. Admin sees every hub; Warehouse and Partner hub see their own trucks.
 */
abstract class FuelPage extends Page
{
    use WithFileUploads;

    protected string $view = 'filament.fuel.page';

    protected static string|BackedEnum|null $navigationIcon = Heroicon::OutlinedBeaker;

    protected static ?string $navigationLabel = 'Fuel';

    protected static ?string $title = 'Fuel';

    protected static ?string $slug = 'fuel';

    #[Url]
    public string $tab = 'trucks';

    #[Url]
    public string $month = '';

    #[Url]
    public ?int $truck = null;

    /** statement import */
    public $statementFile = null;

    public string $provider = 'petron';

    public ?int $statementId = null;

    public string $lineStatus = '';

    public string $priceDiesel = '';

    public string $priceGasoline = '';

    public static function canAccess(): bool
    {
        return Fuel::ready() && Tracker::hubFor(Auth::user(), Filament::getCurrentPanel()?->getId()) !== false;
    }

    public function mount(): void
    {
        $this->month = preg_match('/^\d{4}-\d{2}$/', $this->month) ? $this->month : now()->format('Y-m');
        $this->provider = (string) Fuel::setting('card_brand', 'petron');
    }

    protected function hub(): int|false|null
    {
        return Tracker::hubFor(Auth::user(), Filament::getCurrentPanel()?->getId());
    }

    protected function isAdmin(): bool
    {
        return $this->hub() === null;
    }

    public function setTab(string $tab): void
    {
        $this->tab = in_array($tab, ['trucks', 'fills', 'alerts', 'cards', 'prices', 'vat'], true) ? $tab : 'trucks';
    }

    public function showTruck(?int $id): void
    {
        $this->truck = $id;
        $this->tab = 'fills';
    }

    public function importStatement(): void
    {
        $this->validate(['statementFile' => 'required|file|max:10240', 'provider' => 'required|in:'.implode(',', array_keys(Fuel::PROVIDERS))]);
        $hub = $this->hub();
        $s = FuelStatements::import($this->statementFile->getRealPath(), $this->provider, Auth::id(), $hub ?: null, $this->statementFile->getClientOriginalName());
        $this->statementFile = null;
        $this->statementId = $s->id;
        if (! $s->lines) {
            Notification::make()->title('No charges found in the file')->body('Save the statement as CSV, with the column titles (date, card or plate, liters, amount) in the first rows.')->warning()->send();

            return;
        }
        $m = $s->lines()->where('status', 'matched')->count();
        Notification::make()->title("{$s->lines} charges imported · {$m} matched")->success()->send();
    }

    public function savePrices(): void
    {
        abort_unless($this->isAdmin(), 403);
        $week = Fuel::weekStart()->toDateString();
        foreach (['diesel' => $this->priceDiesel, 'gasoline' => $this->priceGasoline] as $type => $v) {
            $v = (float) str_replace(',', '', $v);
            Fuel::put("price.{$type}", $v > 0 ? ['week' => $week, 'price' => round($v, 2)] : null);
        }
        $this->priceDiesel = $this->priceGasoline = '';
        Notification::make()->title('This week\'s price saved')->success()->send();
    }

    protected function getViewData(): array
    {
        $report = new FuelReport($this->hub(), $this->month);
        $truckIds = $report->trucks()->pluck('id');
        $statements = FuelStatement::query()->when(! $this->isAdmin(), fn ($q) => $q->where('logistichub_id', $this->hub()))->latest()->take(8)->get();
        $statement = $this->statementId ? $statements->firstWhere('id', $this->statementId) : $statements->first();

        return [
            'report' => $report,
            'totals' => $report->totals(),
            'rows' => $this->tab === 'trucks' ? $report->perTruck() : collect(),
            'alerts' => in_array($this->tab, ['alerts', 'trucks'], true) ? $report->alerts() : [],
            'fills' => $this->tab === 'fills' || $this->tab === 'vat'
                ? $report->fills()->with(['truck', 'driver', 'trip'])->when($this->truck && $this->tab === 'fills', fn ($q) => $q->where('truck_id', $this->truck))->orderByDesc('filled_at')->get()
                : collect(),
            'statements' => $statements,
            'statement' => $statement,
            'lines' => $statement ? FuelStatementLine::where('fuel_statement_id', $statement->id)
                ->where(fn ($q) => $q->whereIn('truck_id', $truckIds->all() ?: [0])->orWhereNull('truck_id'))
                ->when($this->lineStatus, fn ($q) => $q->where('status', $this->lineStatus))->with(['truck', 'fuelFill'])->orderBy('charged_at')->get() : collect(),
            'lineCounts' => $statement ? $statement->lines()->selectRaw('status, count(*) n')->groupBy('status')->pluck('n', 'status') : collect(),
            'prices' => ['diesel' => Fuel::price('diesel'), 'gasoline' => Fuel::price('gasoline')],
            'weeks' => $this->tab === 'prices' ? Fuel::priceWeeks() : [],
            'isAdmin' => $this->isAdmin(),
            'truckName' => $this->truck ? $report->trucks()->firstWhere('id', $this->truck)?->plate_no : null,
            'months' => collect(range(0, 11))->map(fn ($i) => now()->startOfMonth()->subMonths($i))->mapWithKeys(fn ($d) => [$d->format('Y-m') => $d->format('F Y')]),
            'vatUrl' => route('fuel.vat-export', ['month' => $this->month, 'panel' => Filament::getCurrentPanel()?->getId()]),
            'companyTin' => Fuel::companyTin(),
        ];
    }
}
