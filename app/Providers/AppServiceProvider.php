<?php

namespace App\Providers;

use App\Models\Consolidator;
use App\Support\Navigation\DispatchNavigationManager;
use App\Support\Photos\PhotoShrinker;
use App\Support\SchemaMemo;
use Filament\Actions\DeleteAction;
use Filament\Forms\Components\FileUpload;
use Filament\Navigation\NavigationManager;
use Filament\Notifications\Notification;
use Filament\Schemas\Components\Section;
use Filament\Support\Assets\Css;
use Filament\Support\Assets\Js;
use Filament\Support\Facades\FilamentAsset;
use Filament\Tables\Table;
use Illuminate\Console\Events\CommandFinished;
use Illuminate\Database\Eloquent\Model;
use Illuminate\Database\Events\MigrationEnded;
use Illuminate\Database\Events\MigrationsEnded;
use Illuminate\Database\Events\SchemaLoaded;
use Illuminate\Database\QueryException;
use Illuminate\Database\Schema\Builder;
use Illuminate\Support\Facades\Event;
use Illuminate\Support\Facades\Queue;
use Illuminate\Support\ServiceProvider;

class AppServiceProvider extends ServiceProvider
{
    public function register(): void
    {
        // Speed: Schema::hasTable / hasColumn answers are remembered (App\Support\SchemaMemo); forgotten when migrations run.
        $this->app->extend('db.schema', fn ($schema) => $schema instanceof Builder ? new SchemaMemo($schema) : $schema);
    }

    public function boot(): void
    {
        // Side menus: groups in the order of the work, clear names, numbers on what waits (App\Support\Navigation\Menu).
        $this->app->scoped(NavigationManager::class, fn () => new DispatchNavigationManager);

        // Forms are built with Filament schemas, which only pass the fields they render.
        Model::unguard();

        Section::configureUsing(fn (Section $section) => $section->columnSpanFull());

        // Photos are made smaller on the phone before upload (longest side 1600 px), like the
        // Scan app and the Driver app. A 3 MB phone photo becomes a few hundred KB.
        // Non-photo files are not touched; small pictures (logos) are never made bigger.
        FileUpload::configureUsing(fn (FileUpload $upload) => $upload
            ->automaticallyResizeImagesMode('contain')
            ->automaticallyResizeImagesToWidth((string) PhotoShrinker::MAX_SIDE)
            ->automaticallyResizeImagesToHeight((string) PhotoShrinker::MAX_SIDE)
            ->imageResizeUpscale(false));

        // Consistent, roomier tables in every panel.
        Table::configureUsing(fn (Table $table) => $table
            ->paginationPageOptions([10, 25, 50, 100])
            ->defaultPaginationPageOption(25)
            ->striped());

        // Deleting something that is still in use (e.g. a truck that has trips) used to end in a
        // database error page. Show a clear message instead.
        DeleteAction::configureUsing(fn (DeleteAction $action) => $action->using(
            function (Model $record, DeleteAction $action): bool {
                try {
                    return (bool) $record->delete();
                } catch (QueryException $exception) {
                    if (! in_array($exception->getCode(), ['23000', '23503'], true)) {
                        throw $exception;
                    }

                    Notification::make()
                        ->title('Cannot delete this record')
                        ->body('It is still used by other records (for example trips or invoices). Remove those first.')
                        ->danger()
                        ->persistent()
                        ->send();

                    $action->halt();

                    return false;
                }
            },
        ));

        // Queue workers live for hours; start every job with fresh lookups.
        Queue::looping(function () {
            Consolidator::flushNameCache();
            SchemaMemo::reset();
        });

        // Tables changed: forget the remembered Schema answers.
        Event::listen([MigrationsEnded::class, MigrationEnded::class, SchemaLoaded::class], fn () => SchemaMemo::flush());
        Event::listen(CommandFinished::class, function ($e) {
            if (in_array($e->command, ['optimize:clear', 'cache:clear', 'migrate', 'migrate:fresh', 'migrate:rollback', 'migrate:refresh', 'migrate:reset', 'db:wipe'], true)) {
                SchemaMemo::flush();
            }
        });

        FilamentAsset::register([
            Js::make('barcode-scanner', resource_path('js/barcode-scanner.js')),
            Js::make('driver-offline', resource_path('js/driver-offline.js')),
            // Maps & routes: the stops map (Leaflet 1.9.4 + OpenStreetMap), only on the pages that show it.
            // Kept in resources/vendor so the server does not need node_modules (composer runs
            // filament:upgrade, which publishes these files, before any npm step).
            Js::make('leaflet', resource_path('vendor/leaflet/leaflet.js'))->loadedOnRequest(),
            Css::make('leaflet', resource_path('vendor/leaflet/leaflet.css'))->loadedOnRequest(),
            Js::make('trip-map', resource_path('js/trip-map.js'))->loadedOnRequest(),
            Js::make('truck-map', resource_path('js/truck-map.js'))->loadedOnRequest(),
        ]);
    }
}
