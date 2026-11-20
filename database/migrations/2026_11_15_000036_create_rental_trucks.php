<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

/**
 * Rental trucks: who owns a truck (own or rental), the rental company and how it charges
 * (per trip, per day, per km), the days a rental is booked, and the rental part of each trip.
 */
return new class extends Migration
{
    public function up(): void
    {
        if (! Schema::hasTable('rental_companies')) {
            Schema::create('rental_companies', function (Blueprint $t) {
                $t->id();
                $t->string('name');
                $t->string('contact_name')->nullable();
                $t->string('phone')->nullable();
                $t->text('notes')->nullable();
                $t->foreignId('logistichub_id')->nullable()->index();
                $t->timestamps();
            });
        }
        Schema::table('trucks', function (Blueprint $t) {
            if (! Schema::hasColumn('trucks', 'ownership')) {
                $t->string('ownership', 10)->default('own');
                $t->foreignId('rental_company_id')->nullable()->index();
                $t->decimal('rate_trip', 10, 2)->nullable();
                $t->decimal('rate_day', 10, 2)->nullable();
                $t->decimal('rate_km', 10, 2)->nullable();
                $t->string('rental_driver')->nullable();
                $t->string('make_model')->nullable();
            }
        });
        if (! Schema::hasTable('truck_bookings')) {
            Schema::create('truck_bookings', function (Blueprint $t) {
                $t->id();
                $t->foreignId('truck_id')->index();
                $t->date('day');
                $t->foreignId('user_id')->nullable();
                $t->timestamps();
                $t->unique(['truck_id', 'day']);
            });
        }
        Schema::table('deliverylogs', function (Blueprint $t) {
            if (! Schema::hasColumn('deliverylogs', 'rental_cost')) {
                $t->string('rental_driver')->nullable();
                $t->decimal('rental_cost', 10, 2)->nullable();
                $t->string('rental_rate', 10)->nullable();
                $t->unsignedInteger('rental_km')->nullable();
            }
        });
        \App\Support\Help\Help::installDefaults();
    }

    public function down(): void
    {
        Schema::table('deliverylogs', function (Blueprint $t) {
            if (Schema::hasColumn('deliverylogs', 'rental_cost')) {
                $t->dropColumn(['rental_driver', 'rental_cost', 'rental_rate', 'rental_km']);
            }
        });
        Schema::dropIfExists('truck_bookings');
        Schema::table('trucks', function (Blueprint $t) {
            if (Schema::hasColumn('trucks', 'ownership')) {
                $t->dropColumn(['ownership', 'rental_company_id', 'rate_trip', 'rate_day', 'rate_km', 'rental_driver', 'make_model']);
            }
        });
        Schema::dropIfExists('rental_companies');
    }
};
