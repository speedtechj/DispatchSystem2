<?php

use App\Models\Deliverylog;
use App\Models\Invoice;
use App\Models\User;
use App\Models\Whdeliverylog;
use Database\Seeders\DemoSeeder;
use Filament\Facades\Filament;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Illuminate\Support\Facades\Route;

uses(RefreshDatabase::class);

beforeEach(function () {
    $this->seed(DemoSeeder::class);
    // switch every AI helper on, so their pages are visited too (no calls are made to the AI by opening them)
    \App\Models\Ai\AiSetting::create(['api_key' => 'sk-ant-test', 'features' => array_keys(\App\Support\Ai\AiFeatures::ALL)]);
    \Illuminate\Support\Facades\Cache::forget('ai.settings');
    \Illuminate\Support\Facades\Http::preventStrayRequests();
});

/**
 * Every GET page of a panel, with {record}-style parameters filled using the
 * first row of the resource's model.
 */
function panelUrls(string $panelId): array
{
    $panel = Filament::getPanel($panelId);
    $urls = [];

    foreach (Route::getRoutes() as $route) {
        $name = $route->getName() ?? '';

        if (! str_starts_with($name, "filament.{$panelId}.") || ! in_array('GET', $route->methods())) {
            continue;
        }

        if (preg_match('/\.auth\.|\.tenant|email-verification|password-reset|\.logout|\.login/', $name)) {
            continue;
        }

        $parameters = [];

        foreach ($route->parameterNames() as $parameter) {
            $resource = collect($panel->getResources())
                ->first(fn (string $resource) => str_contains($name, '.resources.'.$resource::getSlug().'.'));

            $model = $resource ? $resource::getModel() : null;
            $key = $model ? $model::query()->value('id') : null;

            if ($key === null) {
                continue 2;
            }

            $parameters[$parameter] = $key;
        }

        $urls[$name] = route($name, $parameters);
    }

    return $urls;
}

dataset('panels', [
    'admin' => ['admin', 'admin@example.com'],
    'company' => ['company', 'company@example.com'],
    'warehouse' => ['warehouse', 'warehouse@example.com'],
    'delivery' => ['delivery', 'driver@example.com'],
]);

it('renders every page of the panel without errors', function (string $panelId, string $email) {
    $user = User::where('email', $email)->firstOrFail();
    Filament::setCurrentPanel(Filament::getPanel($panelId));

    $failures = [];

    foreach (panelUrls($panelId) as $name => $url) {
        $response = $this->actingAs($user)->get($url);

        if ($response->getStatusCode() >= 500) {
            $message = $response->exception?->getMessage() ?? 'HTTP '.$response->getStatusCode();

            // Filament 5's HTML sanitizer needs PHP 8.4's Dom\HTMLDocument; skip when testing on older PHP.
            if (PHP_VERSION_ID < 80400 && str_contains($message, 'Dom\HTMLDocument')) {
                continue;
            }

            $failures[] = "{$name}: ".str($message)->limit(300);
        } elseif ($response->getStatusCode() === 403) {
            // Demo users hold every permission, so nothing in their own panel may be forbidden.
            $failures[] = "{$name}: 403 Forbidden";
        }
    }

    expect($failures)->toBe([]);
})->with('panels');

it('opens the invoice-assignment screens for a trip of the user\'s own hub', function () {
    $admin = User::where('email', 'admin@example.com')->firstOrFail();
    $trip = Deliverylog::firstOrFail();

    $this->actingAs($admin)->get('/routeinvoice?ownerRecord='.$trip->id)->assertSuccessful()->assertSee('Assign invoices');
    $this->actingAs($admin)->get('/routeinvoice')->assertNotFound();
    $this->actingAs($admin)->get('/routeinvoice?ownerRecord=999999')->assertNotFound();
});

it('opens the warehouse assignment screens', function () {
    $warehouse = User::where('email', 'warehouse@example.com')->firstOrFail();
    $whTrip = Whdeliverylog::firstOrFail();
    $trip = Deliverylog::firstOrFail();

    $this->actingAs($warehouse)->get('/warehouse/routeinvoice?ownerRecord='.$whTrip->id)->assertSuccessful();
    $this->actingAs($warehouse)->get('/warehouse/hubroute?ownerRecord='.$trip->id)->assertSuccessful();
});

it('requires sign-in to print a receipt', function () {
    $invoice = Invoice::firstOrFail();

    $this->get(route('invoicepdf', $invoice->id))->assertRedirect();
});

it('keeps users out of panels they do not belong to', function () {
    $driver = User::where('email', 'driver@example.com')->firstOrFail();

    $this->actingAs($driver)->get('/')->assertForbidden();
    $this->actingAs($driver)->get('/warehouse')->assertForbidden();
    $this->actingAs($driver)->get('/delivery')->assertSuccessful();
});

it('explains a missing PDF program instead of crashing', function () {
    config(['snappy.pdf.binary' => '/nowhere/wkhtmltopdf']);
    $admin = User::where('email', 'admin@example.com')->firstOrFail();
    $invoice = \App\Models\Invoice::firstOrFail();

    $this->actingAs($admin)
        ->get(route('invoicepdf', $invoice->id))
        ->assertStatus(503)
        ->assertSee('wkhtmltopdf');
});
