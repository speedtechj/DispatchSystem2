<?php

namespace App\Filament\Auth;

use Filament\Auth\Pages\Login;
use Illuminate\Contracts\Support\Htmlable;

/**
 * Filament's own sign-in (validation, rate limiting, remember me) inside a
 * full-screen design. Each panel has its own subclass and Blade view.
 */
abstract class BrandedLogin extends Login
{
    protected static string $layout = 'filament.auth.layout';

    /** Shown in the browser tab and on the page, e.g. "Warehouse". */
    abstract public function panelLabel(): string;

    public function getTitle(): string|Htmlable
    {
        return 'Sign in · '.$this->panelLabel();
    }

    public function getHeading(): string|Htmlable|null
    {
        return 'Sign in';
    }

    public function getSubheading(): string|Htmlable|null
    {
        return null;
    }
}
