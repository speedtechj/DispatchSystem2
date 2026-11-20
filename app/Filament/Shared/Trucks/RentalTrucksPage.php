<?php

namespace App\Filament\Shared\Trucks;

use App\Models\RentalCompany;
use App\Models\Truck;
use App\Support\Rentals;
use App\Support\Tracking\Tracker;
use Filament\Facades\Filament;
use Filament\Notifications\Notification;
use Filament\Pages\Page;
use Illuminate\Support\Carbon;
use Illuminate\Support\Facades\Auth;
use Symfony\Component\HttpFoundation\StreamedResponse;

/** Rental trucks: the month's rental trips per company, cost per box compared with own trucks, rental companies. */
class RentalTrucksPage extends Page
{
    protected string $view = 'filament.trucks.rentals';

    protected static ?string $slug = 'rental-trucks';

    protected static ?string $navigationLabel = 'Rental trucks';

    protected static ?string $title = 'Rental trucks';

    protected static string|\BackedEnum|null $navigationIcon = 'heroicon-o-receipt-percent';

    public string $month = '';

    public ?int $company = null;

    public string $newName = '';

    public string $newContact = '';

    public string $newPhone = '';

    public static function canAccess(): bool
    {
        return Rentals::ready() && Tracker::hubFor(Auth::user(), Filament::getCurrentPanel()?->getId()) !== false;
    }

    public function mount(): void
    {
        $this->month = today()->format('Y-m');
    }

    protected function hub(): int|false|null
    {
        return Tracker::hubFor(Auth::user(), Filament::getCurrentPanel()?->getId());
    }

    public function shiftMonth(int $by): void
    {
        $this->month = Carbon::createFromFormat('Y-m', $this->month)->startOfMonth()->addMonths($by)->format('Y-m');
    }

    public function addCompany(): void
    {
        $this->validate(['newName' => 'required|string|max:120']);
        RentalCompany::create(['name' => trim($this->newName), 'contact_name' => $this->newContact ?: null, 'phone' => $this->newPhone ?: null,
            'logistichub_id' => is_int($this->hub()) ? $this->hub() : Auth::user()?->logistichub_id]);
        $this->reset('newName', 'newContact', 'newPhone');
        Notification::make()->title('Rental company added')->success()->send();
    }

    /** Download the month as a CSV file (to check the company's bill). */
    public function download(): StreamedResponse
    {
        $month = Carbon::createFromFormat('Y-m', $this->month)->startOfMonth();
        $rows = Rentals::month($month, $this->company, $this->hub());

        return response()->streamDownload(function () use ($rows) {
            $out = fopen('php://output', 'w');
            fputcsv($out, ['Date', 'Trip', 'Company', 'Truck', 'Charged', 'Rate', 'Boxes', 'Per box']);
            foreach ($rows as $r) {
                fputcsv($out, [$r['date']->toDateString(), $r['trip']->trip_number, $r['company'], $r['plate'], $r['cost'], $r['rate'], $r['boxes'], $r['perBox']]);
            }
            fclose($out);
        }, 'rental-trucks-'.$this->month.'.csv');
    }

    protected function getViewData(): array
    {
        $month = Carbon::createFromFormat('Y-m', $this->month)->startOfMonth();
        $hub = $this->hub();
        $rows = Rentals::month($month, $this->company, $hub);
        $cost = (float) $rows->sum('cost');
        $boxes = (int) $rows->sum('boxes');
        $per = $cost > 0 && $boxes ? round($cost / $boxes) : null;
        $own = Rentals::ownPerBox($month, $hub);
        $companies = Rentals::companies($hub);
        $note = null;
        if ($rows->count() >= 8 && $per && $own && $per > $own) {
            $note = 'You rented '.$rows->count().' times in '.$month->format('F').' (₱'.number_format($cost).'). Rentals cost about ₱'.number_format($per).' per box, your own trucks about ₱'.number_format($own).' (fuel). If this keeps up, another own truck may be worth it.';
        }

        return [
            'rows' => $rows, 'monthLabel' => $month->format('F Y'),
            'kpis' => [
                ['Rental trips', (string) $rows->count(), $rows->groupBy('company')->map->count()->map(fn ($n, $c) => $c.' '.$n)->join(' · ') ?: 'none this month'],
                ['Charged', '₱'.number_format($cost), $rows->pluck('rate')->filter()->unique()->map(fn ($r) => Rentals::RATES[$r] ?? $r)->join(' and ') ?: '—'],
                ['Boxes on rentals', (string) $boxes, $per ? '₱'.number_format($per).' per box' : '—'],
                ['Own trucks', $own ? '₱'.number_format($own) : '—', 'per box (fuel)'],
            ],
            'note' => $note,
            'companies' => $companies->map(fn ($c) => ['c' => $c, 'trucks' => Truck::where('rental_company_id', $c->id)->count()]),
            'companyOptions' => $companies->pluck('name', 'id')->all(),
        ];
    }
}
