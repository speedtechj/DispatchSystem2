<?php

namespace App\Filament\Shared\Trips;

use App\Filament\Tables\TripBoxes;
use App\Filament\Tables\TripList;
use Filament\Actions\Action;
use Filament\Facades\Filament;
use Filament\Schemas\Components\Callout;
use Filament\Schemas\Components\Section;
use Filament\Schemas\Components\View;
use Filament\Schemas\Schema;
use Illuminate\Contracts\Support\Htmlable;
use Illuminate\Support\Carbon;
use Illuminate\Support\HtmlString;

/**
 * Edit trip (board 44b): status and made-by pills, a one-line summary, the trip's fields folded
 * under "✎ Edit details", five tiles, then Boxes on this trip. Used by all three panels.
 */
trait EditsTrip
{
    /** A partner hub's own trip: its boxes are the hub-loaded ones. */
    protected function isHubTrip(): bool
    {
        return false;
    }

    public function getTitle(): string|Htmlable
    {
        return 'Trip '.$this->record->trip_number;
    }

    public function getHeading(): string|Htmlable
    {
        $st = TripList::status($this->record);
        $k = TripList::madeKey($this->record);

        return new HtmlString(view('filament.trips.edit-head', [
            'trip' => $this->record, 'st' => $st, 'made' => TripList::MADE[$k][0], 'k' => $k,
            'listUrl' => static::getResource()::getUrl('index'),
        ])->render());
    }

    public function getSubheading(): string|Htmlable|null
    {
        $t = $this->record;
        $g = TripList::goes($t);
        $lead = TripList::crew($t)->first();

        return collect([
            TripList::isHubTrip($t) ? $g['to'].' (the hub delivers)' : ($g['to'] === 'Not set yet' ? null : $g['to'].' (direct to customers)'),
            $t->truck?->plate_no ?? 'No truck yet',
            $lead?->user?->first_name,
            $t->departure_date ? 'leaves '.Carbon::parse($t->departure_date)->format('M j') : null,
        ])->filter()->join(' · ');
    }

    public function getBreadcrumbs(): array
    {
        return [];
    }

    protected function tripPageAction(): ?Action
    {
        $page = collect(Filament::getCurrentPanel()?->getPages() ?? [])->first(fn ($p) => is_subclass_of($p, TripPage::class));

        return $page ? Action::make('tripPage')->label('Open the trip page')->color('gray')->icon('heroicon-m-arrow-top-right-on-square')
            ->url(fn () => $page::getUrl(['trip' => $this->record->id])) : null;
    }

    protected function getHeaderActions(): array
    {
        return array_values(array_filter([$this->tripPageAction(), ...$this->extraHeaderActions()]));
    }

    protected function extraHeaderActions(): array
    {
        return [];
    }

    public function form(Schema $schema): Schema
    {
        $schema = static::getResource()::form($schema);
        $parts = collect($schema->getComponents(withHidden: true))->reject(fn ($c) => $c instanceof Callout)->values()->all();

        return $schema->components($parts)->columns(['default' => 1, 'md' => 2, 'xl' => 4]);
    }

    protected function getSaveFormAction(): Action
    {
        return parent::getSaveFormAction()->label('Save changes');
    }

    public function content(Schema $schema): Schema
    {
        return $schema->components([
            Section::make('✎ Edit details')
                ->description('Truck, dates, going to, waybill, delivered date')
                ->collapsible()->collapsed()->compact()
                ->schema([$this->getFormContentComponent()]),
            View::make('filament.trips.edit-tiles')->viewData(fn () => ['tiles' => TripBoxes::tiles($this->record, $this->isHubTrip())]),
            $this->getRelationManagersContentComponent(),
        ]);
    }
}
