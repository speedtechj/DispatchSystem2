<?php

namespace App\Filament\Shared\Hubs;

use App\Models\Hubs\HubArea;
use App\Models\Hubs\HubAreaRequest;
use App\Models\Logistichub;
use App\Support\Hubs\HubAreas;
use Filament\Notifications\Notification;
use Filament\Pages\Page;
use Illuminate\Contracts\Support\Htmlable;
use Illuminate\Support\Facades\Auth;

/** Partner hub › My area: the places this hub delivers; ask the office for another place. */
class MyAreaPage extends Page
{
    protected string $view = 'filament.hubs.my-area';

    protected static ?string $slug = 'my-area';

    protected static ?string $title = 'My area';

    protected static string|\BackedEnum|null $navigationIcon = 'heroicon-o-map';

    public array $ask = ['province' => '', 'city' => '', 'barangay' => '', 'reason' => ''];

    public static function canAccess(): bool
    {
        $u = Auth::user();

        return HubAreas::ready() && $u?->logistichub_id && Logistichub::whereKey($u->logistichub_id)->value('is_company');
    }

    public function getHeading(): string|Htmlable
    {
        return '';
    }

    public function send(): void
    {
        if (blank($this->ask['province']) || blank($this->ask['reason'])) {
            Notification::make()->title('Type the place and why')->warning()->send();

            return;
        }
        HubAreas::request((int) Auth::user()->logistichub_id, $this->ask['province'], $this->ask['city'], $this->ask['barangay'], $this->ask['reason'], Auth::user());
        $this->ask = ['province' => '', 'city' => '', 'barangay' => '', 'reason' => ''];
        Notification::make()->title('Sent to the office')->success()->send();
    }

    protected function getViewData(): array
    {
        $hub = Logistichub::find(Auth::user()->logistichub_id);
        $areas = HubArea::where('logistichub_id', $hub->id)->orderBy('province')->orderBy('city')->get();

        return [
            'hub' => $hub,
            'provinces' => $areas->where('c_key', ''),
            'cities' => $areas->where('c_key', '!=', '')->where('b_key', ''),
            'brgys' => $areas->where('b_key', '!=', '')->groupBy(fn ($a) => $a->city.', '.$a->province),
            'requests' => HubAreaRequest::where('logistichub_id', $hub->id)->latest('id')->limit(6)->get(),
            'list' => collect(HubAreas::REGIONS)->flatten()->sort()->values(),
        ];
    }
}
