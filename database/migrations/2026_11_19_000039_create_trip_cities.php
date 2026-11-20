<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

/** Trips by city: a planned trip keeps its cities; boxes join when they are scanned onto the truck. */
return new class extends Migration
{
    public function up(): void
    {
        if (! Schema::hasTable('trip_cities')) {
            Schema::create('trip_cities', function (Blueprint $t) {
                $t->id();
                $t->foreignId('deliverylog_id')->index();
                $t->string('province', 120)->nullable();
                $t->string('city', 120);
                $t->string('city_key', 80)->index();
                $t->unsignedInteger('planned_boxes')->default(0);
                $t->timestamps();
            });
        }
        Schema::table('deliverylogs', function (Blueprint $t) {
            if (! Schema::hasColumn('deliverylogs', 'plan_why')) {
                $t->string('plan_why', 300)->nullable();
            }
            if (! Schema::hasColumn('deliverylogs', 'plan_space')) {
                $t->unsignedInteger('plan_space')->nullable();
            }
        });
    }

    public function down(): void
    {
        Schema::dropIfExists('trip_cities');
        Schema::table('deliverylogs', function (Blueprint $t) {
            foreach (['plan_why', 'plan_space'] as $c) {
                if (Schema::hasColumn('deliverylogs', $c)) {
                    $t->dropColumn($c);
                }
            }
        });
    }
};
