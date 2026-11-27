<?php

namespace App\Filament\Shared\Deliveries;

use App\Models\DeliveryAttempt;
use App\Support\Deliveries\NextTry;
use Carbon\Carbon;
use Filament\Notifications\Notification;
use Filament\Pages\Page;
use Filament\Support\Icons\Heroicon;
use Illuminate\Support\Facades\Auth;
use Illuminate\Support\Facades\Schema;
use Livewire\Attributes\Url;

/**
 * Part 44 (board 69): boxes that could not be delivered, so none is forgotten.
 * Due today / Overdue / On hold (a later day) / Needs office (after 3 tries, or only the office can fix it).
 */
class RedeliveryPage extends Page
{
    protected string $view = 'filament.deliveries.redelivery';

    protected static ?string $slug = 'redelivery';

    protected static string|\BackedEnum|null $navigationIcon = Heroicon::OutlinedArrowPath;

    protected static ?string $title = 'Redelivery';

    #[Url]
    public string $tab = 'today';

    public static function canAccess(): bool
    {
        return Schema::hasColumn('delivery_attempts', 'next_try_on') && (bool) Auth::user();
    }

    public static function getNavigationBadge(): ?string
    {
        if (! static::canAccess()) {
            return null;
        }
        $c = NextTry::counts(NextTry::open()->get(['id', 'next_try_on', 'needs_office']));
        $n = $c['today'] + $c['overdue'] + $c['office'];

        return $n ? (string) $n : null;
    }

    public static function getNavigationBadgeColor(): ?string
    {
        return 'warning';
    }

    public function setTab(string $t): void
    {
        $this->tab = in_array($t, ['today', 'overdue', 'hold', 'office'], true) ? $t : 'today';
    }

    /** The office picks the day of the next try (also takes it off "Needs office"). */
    public function setDay(int $id, string $day): void
    {
        $a = NextTry::open()->find($id);
        $d = rescue(fn () => Carbon::parse($day)->startOfDay(), null, false);
        if (! $a || ! $d) {
            return;
        }
        if ($d->lt(today())) {
            $d = today();
        }
        $a->update(['next_try_on' => $d->toDateString(), 'needs_office' => false]);
        Notification::make()->title("{$a->invoice?->invoice}: next try ".$d->format('D M j'))->success()->send();
    }

    public function toOffice(int $id): void
    {
        NextTry::open()->find($id)?->update(['needs_office' => true, 'next_try_on' => null]);
    }

    /** Closed by the office (returned to the sender, picked up, cancelled): off the list. */
    public function close(int $id): void
    {
        $a = NextTry::open()->find($id);
        if ($a) {
            $a->update(['handled_at' => now(), 'handled_by' => Auth::id()]);
            Notification::make()->title("{$a->invoice?->invoice} is off the redelivery list")->send();
        }
    }

    protected function getViewData(): array
    {
        $all = NextTry::open()->with(['invoice:id,invoice,receiver_name,receiver_barangay,receiver_city,receiver_mobile_no', 'user:id,full_name', 'deliverylog:id,trip_number'])
            ->orderBy('next_try_on')->orderBy('id')->get();
        $tries = DeliveryAttempt::whereIn('invoice_id', $all->pluck('invoice_id'))->selectRaw('invoice_id, count(*) n')->groupBy('invoice_id')->pluck('n', 'invoice_id');
        $rows = $all->filter(fn ($a) => NextTry::tab($a) === $this->tab)->values();

        return [
            'counts' => NextTry::counts($all),
            'rows' => $rows,
            'tries' => $tries,
            'choices' => NextTry::choices(),
            'tabs' => ['today' => 'Due today', 'overdue' => 'Overdue', 'hold' => 'On hold', 'office' => 'Needs office'],
        ];
    }
}
