<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

/** Board 64: forwarders (with branches) and ports, kept in Settings and picked on a sea shipment. */
return new class extends Migration
{
    public function up(): void
    {
        if (! Schema::hasTable('forwarders')) {
            Schema::create('forwarders', function (Blueprint $t) {
                $t->id();
                $t->string('name', 80);
                $t->string('charge_basis', 8)->nullable();   // cbm, kg, box
                $t->decimal('charge_rate', 12, 2)->nullable();
                $t->boolean('is_active')->default(true);
                $t->foreignId('user_id')->nullable();
                $t->timestamps();
            });
        }
        if (! Schema::hasTable('forwarder_branches')) {
            Schema::create('forwarder_branches', function (Blueprint $t) {
                $t->id();
                $t->foreignId('forwarder_id')->index();
                $t->string('name', 80);                       // "Cebu · Pier 3"
                $t->string('address', 200)->nullable();
                $t->string('hours', 60)->nullable();
                $t->string('phone', 40)->nullable();
                $t->decimal('lat', 10, 7)->nullable();
                $t->decimal('lng', 10, 7)->nullable();
                $t->timestamps();
            });
        }
        if (! Schema::hasTable('ports')) {
            Schema::create('ports', function (Blueprint $t) {
                $t->id();
                $t->string('name', 80);
                $t->string('kind', 12)->default('both');      // container, roro, both
                $t->string('address', 200)->nullable();
                $t->decimal('lat', 10, 7)->nullable();
                $t->decimal('lng', 10, 7)->nullable();
                $t->boolean('is_active')->default(true);
                $t->timestamps();
            });
        }
        if (Schema::hasTable('sea_shipments') && ! Schema::hasColumn('sea_shipments', 'forwarder_id')) {
            Schema::table('sea_shipments', function (Blueprint $t) {
                $t->foreignId('forwarder_id')->nullable();
                $t->foreignId('hand_over_branch_id')->nullable();
                $t->foreignId('pick_up_branch_id')->nullable();
            });
        }
    }

    public function down(): void
    {
        if (Schema::hasColumn('sea_shipments', 'forwarder_id')) {
            Schema::table('sea_shipments', fn (Blueprint $t) => $t->dropColumn(['forwarder_id', 'hand_over_branch_id', 'pick_up_branch_id']));
        }
        Schema::dropIfExists('ports');
        Schema::dropIfExists('forwarder_branches');
        Schema::dropIfExists('forwarders');
    }
};
