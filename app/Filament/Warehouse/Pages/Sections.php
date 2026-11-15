<?php

namespace App\Filament\Warehouse\Pages;

use App\Models\Boxes\WhCount;
use App\Models\Invoice;
use App\Models\Tripinvoice;
use App\Models\Whtripinvoice;
use App\Support\Boxes\SectionCount;
use App\Support\Boxes\Sections as SectionList;
use BackedEnum;
use Filament\Pages\Page;
use Filament\Support\Icons\Heroicon;
use Illuminate\Support\Facades\Auth;
use UnitEnum;

/** Warehouse → Sections: the sections of this warehouse (set by Admin), boxes in each, find a box, print labels. */
class Sections extends Page
{
    protected string $view = 'filament.boxes.sections-view';

    protected static string|UnitEnum|null $navigationGroup = 'Warehouse';

    protected static string|BackedEnum|null $navigationIcon = Heroicon::OutlinedSquares2x2;

    protected static ?string $navigationLabel = 'Sections';

    protected static ?string $title = 'Warehouse sections';

    protected static ?string $slug = 'sections';

    public string $find = '';

    public static function canAccess(): bool
    {
        return SectionList::ready() && (bool) Auth::user()?->warehouse_id;
    }

    protected function getViewData(): array
    {
        $wh = Auth::user()?->warehouse_id;
        $sections = SectionList::of($wh)->map(fn ($s) => [
            's' => $s,
            'boxes' => SectionCount::ready() ? SectionCount::expected($s)->count() : $s->invoices()->count(),
            'counted' => SectionCount::ready() ? WhCount::where('wh_section_id', $s->id)->whereNotNull('finished_at')->latest('finished_at')->first() : null,
        ]);
        $hit = null;
        $code = mb_strtoupper(trim($this->find));
        if ($code !== '') {
            $box = Invoice::with(['whSection', 'verifiedBy:id,first_name,last_name', 'container:id,container_no'])->where('invoice', $code)->latest('id')->first();
            if ($box) {
                $trip = Tripinvoice::with('deliverylog:id,trip_number')->where('invoice_id', $box->id)->latest('id')->first();
                $wtrip = Whtripinvoice::with('whdeliverylog:id,trip_number')->where('invoice_id', $box->id)->where('is_unloaded', false)->latest('id')->first();
                $hit = ['box' => $box, 'where' => match (true) {
                    (bool) $box->is_delivered => 'Delivered',
                    (bool) $trip?->is_loaded => 'Loaded on trip '.$trip->deliverylog?->trip_number,
                    (bool) $wtrip?->is_loaded => 'On the truck to another warehouse (trip '.$wtrip->whdeliverylog?->trip_number.')',
                    (bool) $box->whSection => 'Section '.$box->whSection->code.' · '.$box->whSection->name.($trip ? ' · on trip '.$trip->deliverylog?->trip_number.', not loaded yet' : ''),
                    ! $box->is_verified => 'Not unloaded yet (container '.$box->container?->container_no.')',
                    default => 'In the warehouse, no section',
                }];
            }
        }

        return [
            'sections' => $sections,
            'labelScan' => SectionList::labelScan($wh),
            'labelsUrl' => $wh && $sections->isNotEmpty() ? route('sections.labels', ['warehouse' => $wh]) : null,
            'hit' => $hit, 'code' => $code,
        ];
    }
}
