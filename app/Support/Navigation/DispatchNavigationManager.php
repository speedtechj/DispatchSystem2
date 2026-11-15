<?php

namespace App\Support\Navigation;

use Filament\Navigation\NavigationItem;
use Filament\Navigation\NavigationManager;

/** Filament's side menu, with the groups, names, order and numbers of Menu for our panels. */
class DispatchNavigationManager extends NavigationManager
{
    protected ?string $menuPanel = null;

    public function __construct()
    {
        parent::__construct();

        $id = $this->panel?->getId();
        if (Menu::has($id)) {
            $this->menuPanel = $id;
            $this->navigationGroups = Menu::groups($id);
        }
    }

    /** @return array<NavigationItem> */
    public function getNavigationItems(): array
    {
        $items = parent::getNavigationItems();
        if (! $this->menuPanel) {
            return $items;
        }
        $map = Menu::items($this->menuPanel);
        $badges = Menu::badges($this->menuPanel);

        foreach ($items as $item) {
            $key = $item->getKey();
            if (isset($map[$key])) {
                [$group, $label, $sort] = $map[$key];
                $item->group($group)->sort($sort);
                if ($label) {
                    $item->label($label);
                }
            }
            if (isset($badges[$key]) && $item->getBadge() === null) {
                $panel = $this->menuPanel;
                $counter = $badges[$key];
                $item->badge(fn () => Menu::count($panel, $counter), color: 'warning');
            }
        }

        return $items;
    }
}
