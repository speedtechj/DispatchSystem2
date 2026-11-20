<?php

use App\Filament\Resources\Deliverylogs\Pages\ListDeliverylogs;
use App\Models\Deliverylog;
use App\Models\User;
use App\Support\SchemaMemo;
use Database\Seeders\DemoSeeder;
use Filament\Facades\Filament;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Schema;
use Livewire\Livewire;

uses(RefreshDatabase::class);

it('remembers Schema answers and forgets them when a table changes', function () {
    expect(Schema::getFacadeRoot())->toBeInstanceOf(SchemaMemo::class);
    expect(Schema::hasTable('speed_probe'))->toBeFalse();

    Schema::hasTable('users');
    Schema::hasColumn('users', 'email');
    DB::flushQueryLog();
    DB::enableQueryLog();
    Schema::hasTable('speed_probe');
    Schema::hasTable('users');
    Schema::hasColumn('users', 'email');
    expect(DB::getQueryLog())->toBeEmpty(); // asked before: no query

    Schema::create('speed_probe', fn (Blueprint $t) => $t->id());
    expect(Schema::hasTable('speed_probe'))->toBeTrue()
        ->and(Schema::hasColumn('speed_probe', 'id'))->toBeTrue();
    Schema::table('speed_probe', fn (Blueprint $t) => $t->string('note')->nullable());
    expect(Schema::hasColumn('speed_probe', 'note'))->toBeTrue();
    Schema::drop('speed_probe');
    expect(Schema::hasTable('speed_probe'))->toBeFalse();
});

it('loads the Delivery trips list with the same number of queries for 5 or 30 trips', function () {
    $this->seed(DemoSeeder::class);
    $admin = User::where('email', 'admin@example.com')->firstOrFail();
    $this->actingAs($admin);
    Filament::setCurrentPanel(Filament::getPanel('admin'));
    $base = Deliverylog::where('logistichub_id', $admin->logistichub_id)->firstOrFail();

    $count = function () {
        DB::flushQueryLog();
        DB::enableQueryLog();
        Livewire::test(ListDeliverylogs::class)->html();

        return count(DB::getQueryLog());
    };
    $few = $count();
    foreach (range(1, 25) as $n) {
        $t = $base->replicate();
        $t->trip_number = null;
        $t->save();
    }
    $many = $count();

    expect($many - $few)->toBeLessThan(10); // before: about 13 more queries for every trip
});
