<?php

namespace App\Filament\Company\Pages;

use App\Support\HubDesk;
use BackedEnum;
use Filament\Pages\Page;
use Filament\Support\Icons\Heroicon;
use Illuminate\Support\Facades\Auth;
use Livewire\Attributes\Url;

/** Everything that happened to one of this hub's boxes. Handy when a receiver calls. */
class TrackBox extends Page
{
    protected string $view = 'filament.company.pages.track-box';

    protected static string|BackedEnum|null $navigationIcon = Heroicon::OutlinedMagnifyingGlass;

    protected static ?string $navigationLabel = 'Track a box';

    protected static ?string $title = 'Track a box';

    protected static ?string $slug = 'track';

    protected static ?int $navigationSort = 6;

    #[Url]
    public string $code = '';

    public string $search = '';

    public function mount(): void
    {
        $this->search = $this->code;
    }

    public function getSubheading(): ?string
    {
        return 'Scan or type a box number to see everything that happened to it.';
    }

    public function find(): void
    {
        $this->code = strtoupper(trim($this->search));
    }

    /** Called by the scanner box (camera or typed). */
    public function scanCode(string $code): void
    {
        $this->search = $code;
        $this->find();
    }


    protected function getViewData(): array
    {
        return ['result' => $this->code !== '' ? (new HubDesk((int) Auth::user()->logistichub_id))->track($this->code) : null];
    }
}
