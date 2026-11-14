<?php

namespace App\Livewire;

use App\Support\Help\Help;
use App\Support\Help\HelpUi;
use Illuminate\Support\Collection;
use Livewire\Attributes\Locked;
use Livewire\Attributes\On;
use Livewire\Component;

/**
 * The help panel that opens from "?": the guide for the page you are on, search and
 * "Ask in your own words". On the Scan app and the Driver app it fills the phone screen.
 */
class HelpDrawer extends Component
{
    use HelpUi;

    #[Locked]
    public string $app = 'admin';

    /** The route name of the page it was opened on. */
    #[Locked]
    public ?string $route = null;

    public bool $open = false;

    public ?string $g = null;

    public function mount(string $app, ?string $route = null): void
    {
        $this->app = array_key_exists($app, Help::APP_NAMES) ? $app : 'admin';
        $this->route = $route;
        $this->bootHelpLang();
    }

    protected function helpApp(): string
    {
        return $this->app;
    }

    #[On('open-help')]
    public function show(?string $slug = null): void
    {
        $this->open = true;
        $this->q = '';
        $this->answer = null;
        $page = $this->pageGuides();
        $this->openGuide($slug ?: ($page->count() === 1 ? $page->first()->slug : null));
    }

    public function close(): void
    {
        $this->open = false;
    }

    public function back(): void
    {
        $this->g = null;
    }

    protected function pageGuides(): Collection
    {
        return Help::forRoute($this->route, $this->app);
    }

    public function render()
    {
        $data = $this->helpData();
        // No "Do it now" when you are already on that page.
        if ($data['guide'] && $this->route && str_ends_with($this->route, '.'.(($data['guide']->links ?? [])[$this->app] ?? '-'))) {
            $data['doIt'] = null;
        }

        return view('livewire.help-drawer', $data + [
            'pageGuides' => $this->pageGuides(),
            'phone' => in_array($this->app, ['scan', 'driver'], true),
            'centerUrl' => Help::centerUrl($this->app, $this->g),
        ]);
    }
}
