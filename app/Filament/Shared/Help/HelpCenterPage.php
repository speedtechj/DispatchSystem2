<?php

namespace App\Filament\Shared\Help;

use App\Support\Help\Help;
use App\Support\Help\HelpUi;
use BackedEnum;
use Filament\Pages\Page;
use Filament\Support\Icons\Heroicon;
use Illuminate\Contracts\Support\Htmlable;
use Illuminate\Support\Facades\Auth;
use Livewire\Attributes\Url;

/** Help guide: search, ask in your own words, topics, and each guide step by step (English / Tagalog). */
abstract class HelpCenterPage extends Page
{
    use HelpUi;

    protected string $view = 'filament.help.center';

    protected static string|BackedEnum|null $navigationIcon = Heroicon::OutlinedQuestionMarkCircle;

    protected static ?string $navigationLabel = 'Help guide';

    protected static ?string $title = 'Help guide';

    protected static ?string $slug = 'help';

    protected static ?int $navigationSort = 999;

    #[Url(as: 'g')]
    public ?string $g = null;

    public static function canAccess(): bool
    {
        return (bool) Auth::user();
    }

    public function mount(): void
    {
        $this->bootHelpLang();
        $this->openGuide($this->g);
    }

    protected function helpApp(): string
    {
        return Help::currentApp();
    }

    public function getTitle(): string|Htmlable
    {
        return $this->guide()?->t('title', $this->lang) ?? ($this->lang === 'tl' ? 'Gabay at tulong' : 'Help guide');
    }

    public function getHeading(): string|Htmlable
    {
        return '';
    }

    protected function getViewData(): array
    {
        return $this->helpData();
    }
}
