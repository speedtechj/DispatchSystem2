<?php

namespace App\Providers\Filament\Concerns;

use Filament\Http\Middleware\Authenticate;
use Filament\Http\Middleware\AuthenticateSession;
use Filament\Http\Middleware\DisableBladeIconComponents;
use Filament\Http\Middleware\DispatchServingFilamentEvent;
use Filament\Panel;
use Filament\Support\Colors\Color;
use Filament\Support\Enums\Width;
use Filament\View\PanelsRenderHook;
use Illuminate\Cookie\Middleware\AddQueuedCookiesToResponse;
use Illuminate\Cookie\Middleware\EncryptCookies;
use Illuminate\Foundation\Http\Middleware\PreventRequestForgery;
use Illuminate\Routing\Middleware\SubstituteBindings;
use Illuminate\Session\Middleware\StartSession;
use Illuminate\Support\Facades\Blade;
use Illuminate\View\Middleware\ShareErrorsFromSession;

/**
 * Look and behaviour shared by all four panels (Admin, Company, Warehouse,
 * Delivery), so they feel like one product and are configured in one place.
 */
trait ConfiguresDispatchPanel
{
    /**
     * @param  class-string|null  $login  the panel's branded sign-in page
     */
    protected function dispatchPanel(Panel $panel, string $area, ?string $login = null): Panel
    {
        return $panel
            ->login($login)
            ->spa()
            ->brandName("Dispatch · {$area}")
            ->brandLogo(fn () => view('filament.brand.logo', ['area' => $area]))
            ->brandLogoHeight('2.25rem')
            ->favicon(asset('favicon.svg'))
            ->viteTheme('resources/css/filament/admin/theme.css')
            ->font('Archivo', provider: \Filament\FontProviders\LocalFontProvider::class)
            ->defaultAvatarProvider(\App\Support\LocalAvatarProvider::class)
            ->colors([
                'primary' => Color::hex('#f6be00'),
                'gray' => Color::Slate,
                'info' => Color::hex('#2f6f9f'),
                'success' => Color::hex('#17895e'),
                'warning' => Color::hex('#e08a00'),
                'danger' => Color::hex('#cf3b3b'),
            ])
            ->maxContentWidth(Width::Full)
            ->sidebarCollapsibleOnDesktop()
            ->sidebarWidth('16.5rem')
            ->globalSearch(false)
            ->databaseNotifications()
            ->unsavedChangesAlerts()
            ->renderHook(
                PanelsRenderHook::SIDEBAR_FOOTER,
                fn (): string => Blade::render('<div class="ds-sidebar-footer">{{ $area }} · signed in as {{ auth()->user()?->first_name }}</div>', ['area' => $area]),
            )
            ->middleware([
                EncryptCookies::class,
                AddQueuedCookiesToResponse::class,
                StartSession::class,
                AuthenticateSession::class,
                ShareErrorsFromSession::class,
                PreventRequestForgery::class,
                SubstituteBindings::class,
                DisableBladeIconComponents::class,
                DispatchServingFilamentEvent::class,
            ])
            ->authMiddleware([
                Authenticate::class,
            ]);
    }
}
