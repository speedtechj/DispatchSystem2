<?php

namespace App\Filament\Concerns;

use Filament\Notifications\Notification;
use Illuminate\Database\Eloquent\Builder;
use Illuminate\Database\Eloquent\Model;
use Livewire\Attributes\Locked;
use Throwable;

/**
 * For pages opened from a trip with "?ownerRecord={id}" (the invoice-assignment
 * screens). The id is checked against the trip resource's own query on mount and
 * then locked, so it cannot be swapped from the browser afterwards.
 */
trait ResolvesOwnerTrip
{
    #[Locked]
    public ?int $ownerRecord = null;

    /** Query of trips the current user may assign invoices to. */
    abstract protected function ownerTripQuery(): Builder;

    public function mountResolvesOwnerTrip(): void
    {
        $id = request()->integer('ownerRecord') ?: $this->ownerRecord;

        abort_unless($id && $this->ownerTripQuery()->whereKey($id)->exists(), 404);

        $this->ownerRecord = $id;
    }

    protected function ownerTrip(): Model
    {
        return $this->ownerTripQuery()->findOrFail($this->ownerRecord);
    }

    public function getSubheading(): ?string
    {
        $trip = $this->ownerTripQuery()->find($this->ownerRecord);

        return $trip ? "Trip {$trip->trip_number}" : null;
    }

    /**
     * Run an assignment and tell the user what happened.
     */
    protected function assignAndNotify(callable $assign, int $selected): void
    {
        try {
            $added = $assign();
        } catch (Throwable $exception) {
            report($exception);
            Notification::make()->title('Could not add invoices')->body($exception->getMessage())->danger()->send();

            return;
        }

        $skipped = $selected - $added;

        Notification::make()
            ->title($added === 1 ? '1 invoice added to the trip' : "{$added} invoices added to the trip")
            ->body($skipped > 0 ? "{$skipped} skipped because they are already on a trip." : null)
            ->color($added > 0 ? 'success' : 'warning')
            ->icon($added > 0 ? 'heroicon-o-check-circle' : 'heroicon-o-exclamation-triangle')
            ->send();
    }
}
