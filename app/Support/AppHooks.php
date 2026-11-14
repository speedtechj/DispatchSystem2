<?php

namespace App\Support;

use App\Models\Container;
use App\Models\DeliveryAttempt;
use App\Models\Tripinvoice;
use App\Livewire\HelpDrawer;
use App\Support\Help\Help;
use App\Support\Maps\SortQueue;
use App\Support\Sms\SmsEvents;
use Filament\Support\Facades\FilamentView;
use Filament\View\PanelsRenderHook;
use Illuminate\Support\Facades\Auth;
use Illuminate\Support\Facades\Blade;
use Illuminate\Support\Facades\Schema;
use Livewire\Livewire;

/**
 * App-wide hooks that do not belong to one panel. Registered from
 * DeliveryPanelProvider::boot() so no shared provider file needs changing.
 */
class AppHooks
{
    public static function register(): void
    {
        // Browser tab icon for all four panels (Admin → App icon & favicon).
        FilamentView::registerRenderHook(
            PanelsRenderHook::HEAD_END,
            fn (): string => view('pwa.favicon', ['url' => Pwa::faviconUrl(), 'version' => Pwa::faviconVersion()])->render(),
        );

        // Help guide: the "?" in the top bar (Admin, Warehouse, Partner hub) and the help panel it opens.
        // The Scan app and the Driver app have their own "?" in the screen header.
        Livewire::component('help-drawer', HelpDrawer::class);
        FilamentView::registerRenderHook(
            PanelsRenderHook::USER_MENU_BEFORE,
            fn (): string => in_array(Help::currentApp(), ['admin', 'warehouse', 'company'], true) && Auth::check() && Help::ready()
                ? view('filament.help.topbar-button', ['tl' => Help::lang() === 'tl'])->render() : '',
        );
        FilamentView::registerRenderHook(
            PanelsRenderHook::BODY_END,
            fn (): string => Auth::check() && Help::ready()
                ? Blade::render('@livewire(\'help-drawer\', [\'app\' => $app, \'route\' => $route], key(\'help-drawer\'))', ['app' => Help::currentApp(), 'route' => request()->route()?->getName()])
                : '',
        );

        // Remember when a container is marked unloaded (for the Containers widget).
        Container::saving(function (Container $container): void {
            if ($container->isDirty('is_unloaded') && Schema::hasColumn('containers', 'unloaded_at')) {
                $container->unloaded_at = $container->is_unloaded ? now() : null;
            }
        });

        // Maps & routes: a trip is sorted again when boxes are added to it or taken off it.
        // SMS to receivers: right after the page has answered, so nobody waits for the text.
        $sms = function (callable $job): void {
            if (app()->runningUnitTests()) {
                return; // tests call SmsEvents directly
            }
            app()->terminating(function () use ($job) {
                try {
                    if (Schema::hasTable('sms_messages')) {
                        $job();
                    }
                } catch (\Throwable $e) {
                    report($e);
                }
            });
        };
        Tripinvoice::saved(function (Tripinvoice $box) use ($sms): void {
            if ($box->is_delivered && $box->wasChanged('is_delivered')) {
                $sms(fn () => SmsEvents::delivered($box->fresh()));
            }
            if ($box->logistichub_id && $box->wasChanged('logistichub_id')) {
                $sms(fn () => SmsEvents::hubArrived($box->fresh()));
            }
        });
        DeliveryAttempt::created(fn ($a) => $sms(fn () => SmsEvents::notDelivered($a)));

        // Dashboard box counts are kept 60 seconds; forget them when boxes change.
        Tripinvoice::saved(fn () => HubBoxes::forget());
        Tripinvoice::deleted(fn () => HubBoxes::forget());
        DeliveryAttempt::created(fn () => HubBoxes::forget());

        Tripinvoice::saved(function (Tripinvoice $box): void {
            if ($box->wasRecentlyCreated || $box->wasChanged(['deliverylog_id', 'deliveryloghub_id'])) {
                SortQueue::touch($box->deliverylog_id, $box->deliveryloghub_id, $box->getOriginal('deliverylog_id'), $box->getOriginal('deliveryloghub_id'));
            }
        });
        Tripinvoice::deleted(fn (Tripinvoice $box) => SortQueue::touch($box->deliverylog_id, $box->deliveryloghub_id));
    }
}
