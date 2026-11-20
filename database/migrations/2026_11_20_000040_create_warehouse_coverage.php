<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

/** Two or more warehouses: which warehouse delivers each province (and town exceptions). */
return new class extends Migration
{
    public function up(): void
    {
        if (! Schema::hasTable('warehouse_coverages')) {
            Schema::create('warehouse_coverages', function (Blueprint $t) {
                $t->id();
                $t->foreignId('warehouse_id')->index();
                $t->string('province', 120);
                $t->string('province_key', 120)->index();
                $t->string('city', 120)->nullable();
                $t->string('city_key', 80)->nullable();
                $t->foreignId('user_id')->nullable();
                $t->timestamps();
            });
        }
        if (! Schema::hasTable('coverage_requests')) {
            Schema::create('coverage_requests', function (Blueprint $t) {
                $t->id();
                $t->foreignId('warehouse_id');          // asks for the province
                $t->foreignId('from_warehouse_id');     // has it now
                $t->string('province', 120);
                $t->string('province_key', 120);
                $t->string('status', 10)->default('pending');
                $t->foreignId('user_id')->nullable();
                $t->foreignId('decided_by')->nullable();
                $t->timestamp('decided_at')->nullable();
                $t->timestamps();
            });
        }
        if (! Schema::hasTable('coverage_log')) {
            Schema::create('coverage_log', function (Blueprint $t) {
                $t->id();
                $t->foreignId('warehouse_id')->nullable();
                $t->string('text', 200);
                $t->foreignId('user_id')->nullable();
                $t->timestamps();
            });
        }
        if (! Schema::hasColumn('warehouses', 'is_default')) {
            Schema::table('warehouses', fn (Blueprint $t) => $t->boolean('is_default')->default(false));
        }
    }

    public function down(): void
    {
        Schema::dropIfExists('warehouse_coverages');
        Schema::dropIfExists('coverage_requests');
        Schema::dropIfExists('coverage_log');
        if (Schema::hasColumn('warehouses', 'is_default')) {
            Schema::table('warehouses', fn (Blueprint $t) => $t->dropColumn('is_default'));
        }
    }
};
