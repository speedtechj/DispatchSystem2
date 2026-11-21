<?php

use App\Filament\Pages\AiSettings;
use App\Filament\Pages\PlanTrips;
use App\Models\Ai\AiSetting;
use App\Models\User;
use App\Support\Ai\Ai;
use App\Support\Ai\AiAccess;
use Database\Seeders\DemoSeeder;
use Filament\Facades\Filament;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Illuminate\Support\Facades\Auth;
use Illuminate\Support\Facades\Cache;
use Livewire\Livewire;

uses(RefreshDatabase::class);

beforeEach(function () {
    $this->seed(DemoSeeder::class);
    AiSetting::query()->delete();
    AiSetting::create(['api_key' => 'sk-ant-test-1234', 'model_fast' => 'claude-haiku-5-5', 'model_smart' => 'claude-sonnet-5-5', 'monthly_limit' => 20,
        'features' => ['trips', 'ask', 'voice', 'photo_check', 'issues']]);
    Cache::forget('ai.settings');
    $this->admin = User::where('email', 'admin@example.com')->firstOrFail();
    $this->other = User::where('email', 'warehouse@example.com')->firstOrFail();
});

it('lets everyone use the AI until people are picked', function () {
    $this->actingAs($this->other);
    expect(Ai::switchedOn('trips'))->toBeTrue()->and(Ai::enabled('ask'))->toBeTrue();
});

it('limits each AI helper to the picked people; jobs and helpers that run by themselves are not limited', function () {
    AiAccess::put(['mode' => 'picked', 'users' => [$this->admin->id], 'over' => ['voice' => 'all', 'issues' => [$this->other->id]]]);

    $this->actingAs($this->other);
    expect(Ai::switchedOn('trips'))->toBeFalse()
        ->and(Ai::enabled('ask'))->toBeFalse()
        ->and(Ai::switchedOn('voice'))->toBeTrue()        // everyone
        ->and(Ai::switchedOn('issues'))->toBeTrue()       // own list
        ->and(Ai::switchedOn('photo_check'))->toBeTrue(); // runs by itself

    $this->actingAs($this->admin);
    expect(Ai::switchedOn('trips'))->toBeTrue()->and(Ai::switchedOn('issues'))->toBeFalse();

    Auth::logout(); // a job or a command: nobody signed in
    expect(Ai::switchedOn('trips'))->toBeTrue();
});

it('hides the AI box in Plan trips for people not picked', function () {
    AiAccess::put(['mode' => 'picked', 'users' => [$this->admin->id], 'over' => []]);
    Filament::setCurrentPanel(Filament::getPanel('admin'));

    $this->actingAs($this->admin);
    Livewire::test(PlanTrips::class)->assertSee('What matters today?');

    $this->other->forceFill(['logistichub_id' => $this->admin->logistichub_id])->save();
    $this->actingAs($this->other);
    Livewire::test(PlanTrips::class)->assertDontSee('What matters today?')->assertSee('planned with the system rules');
});

it('saves who can use AI from Settings → AI', function () {
    $this->actingAs($this->admin);
    Filament::setCurrentPanel(Filament::getPanel('admin'));
    Livewire::test(AiSettings::class)->call('setTab', 'access')->assertSee('Who can use AI · for all helpers')
        ->call('setMode', 'picked')->call('addUser', $this->admin->id)->assertSee('Picked people only')
        ->call('setWho', 'voice', 'all')->call('setWho', 'issues', 'own')->call('addUser', $this->other->id, 'issues')
        ->set('previewUser', $this->other->id)->assertSee('No AI in Plan trips')
        ->call('saveAccess');

    $a = AiAccess::get();
    expect($a['mode'])->toBe('picked')->and($a['users'])->toBe([$this->admin->id])
        ->and($a['over']['voice'])->toBe('all')
        ->and($a['over']['issues'])->toBe([$this->admin->id, $this->other->id]);
});
