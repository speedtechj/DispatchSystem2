<?php

namespace App\Console\Commands;

use App\Models\User;
use Illuminate\Console\Command;
use Illuminate\Contracts\Http\Kernel;
use Illuminate\Http\Request;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Route;
use Throwable;

/** Opens every page of a panel as a user and lists the slowest ones, so you can see what to fix. */
class SpeedCheck extends Command
{
    protected $signature = 'speed:check {email : the user to open the pages as} {--panel=admin : admin, warehouse, company or delivery} {--top=15}';

    protected $description = 'Time every page of a panel and show the slowest';

    public function handle(Kernel $kernel): int
    {
        $user = User::where('email', $this->argument('email'))->first();
        if (! $user) {
            $this->error('No user with that email.');

            return self::FAILURE;
        }
        $panel = $this->option('panel');
        $routes = collect(Route::getRoutes()->getRoutes())->filter(fn ($r) => str_starts_with((string) $r->getName(), "filament.{$panel}.")
            && in_array('GET', $r->methods(), true) && ! str_contains($r->uri(), '{')
            && ! str_contains((string) $r->getName(), '.auth.'));

        $count = 0;
        DB::listen(function () use (&$count) {
            $count++;
        });

        $rows = [];
        $this->output->progressStart($routes->count());
        foreach ($routes as $route) {
            $count = 0;
            auth()->login($user);
            $request = Request::create('/'.ltrim($route->uri(), '/'), 'GET');
            $request->setLaravelSession(app('session')->driver());
            $start = microtime(true);
            try {
                $status = $kernel->handle($request)->getStatusCode();
            } catch (Throwable $e) {
                $status = 'error';
            }
            $rows[] = ['/'.ltrim($route->uri(), '/'), (int) round((microtime(true) - $start) * 1000), $count, $status, round(memory_get_peak_usage(true) / 1048576)];
            $this->output->progressAdvance();
        }
        $this->output->progressFinish();

        usort($rows, fn ($a, $b) => $b[1] <=> $a[1]);
        $this->table(['Page', 'Time (ms)', 'Queries', 'Status', 'Peak MB'], array_slice($rows, 0, (int) $this->option('top')));
        $this->line('Send this table if a page is still slow.');

        return self::SUCCESS;
    }
}
