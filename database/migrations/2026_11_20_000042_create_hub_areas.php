<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

/**
 * Hub areas: which partner hub delivers each place (province, city or barangay), one owner per place.
 * Also: where a hub is, its phone, hub requests for a place, the change log,
 * "deliver direct instead" on a trip city, and "no SMS" for one trip.
 */
return new class extends Migration
{
    public function up(): void
    {
        Schema::table('logistichubs', function (Blueprint $t) {
            if (! Schema::hasColumn('logistichubs', 'province')) {
                $t->string('province', 120)->nullable();
                $t->string('city', 120)->nullable();
                $t->string('barangay', 120)->nullable();
                $t->string('phone', 40)->nullable();
            }
        });
        if (! Schema::hasTable('hub_areas')) {
            Schema::create('hub_areas', function (Blueprint $t) {
                $t->id();
                $t->foreignId('logistichub_id')->index();
                $t->string('province', 120);
                $t->string('city', 120)->nullable();
                $t->string('barangay', 120)->nullable();
                $t->string('p_key', 120);
                $t->string('c_key', 120)->default('');
                $t->string('b_key', 120)->default('');
                $t->timestamps();
                $t->unique(['p_key', 'c_key', 'b_key']);
            });
        }
        if (! Schema::hasTable('hub_area_requests')) {
            Schema::create('hub_area_requests', function (Blueprint $t) {
                $t->id();
                $t->foreignId('logistichub_id')->index();
                $t->string('province', 120);
                $t->string('city', 120)->nullable();
                $t->string('barangay', 120)->nullable();
                $t->string('reason', 300)->nullable();
                $t->foreignId('now_hub_id')->nullable();
                $t->foreignId('user_id')->nullable();
                $t->string('status', 12)->default('pending')->index();
                $t->foreignId('decided_by')->nullable();
                $t->timestamp('decided_at')->nullable();
                $t->timestamps();
            });
        }
        if (! Schema::hasTable('hub_area_log')) {
            Schema::create('hub_area_log', function (Blueprint $t) {
                $t->id();
                $t->foreignId('logistichub_id')->nullable()->index();
                $t->string('text', 300);
                $t->foreignId('user_id')->nullable();
                $t->timestamps();
            });
        }
        if (Schema::hasTable('trip_cities') && ! Schema::hasColumn('trip_cities', 'hub_id')) {
            Schema::table('trip_cities', fn (Blueprint $t) => $t->foreignId('hub_id')->nullable()->index());
        }
        if (! Schema::hasColumn('deliverylogs', 'no_sms')) {
            Schema::table('deliverylogs', fn (Blueprint $t) => $t->boolean('no_sms')->default(false));
        }
    }

    public function down(): void
    {
        Schema::dropIfExists('hub_area_log');
        Schema::dropIfExists('hub_area_requests');
        Schema::dropIfExists('hub_areas');
        if (Schema::hasColumn('logistichubs', 'province')) {
            Schema::table('logistichubs', fn (Blueprint $t) => $t->dropColumn(['province', 'city', 'barangay', 'phone']));
        }
        if (Schema::hasColumn('trip_cities', 'hub_id')) {
            Schema::table('trip_cities', fn (Blueprint $t) => $t->dropColumn('hub_id'));
        }
        if (Schema::hasColumn('deliverylogs', 'no_sms')) {
            Schema::table('deliverylogs', fn (Blueprint $t) => $t->dropColumn('no_sms'));
        }
    }
};
