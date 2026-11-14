<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

/**
 * Maps & routes: every address found once and saved (geo_places), and for each
 * trip the order of stops and where each receiver's boxes go in the truck.
 */
return new class extends Migration
{
    public function up(): void
    {
        if (! Schema::hasTable('geo_places')) {
            Schema::create('geo_places', function (Blueprint $table) {
                $table->id();
                $table->string('key', 40)->unique();
                $table->string('raw', 600);
                $table->string('clean', 600)->nullable();
                $table->decimal('lat', 10, 7)->nullable();
                $table->decimal('lng', 10, 7)->nullable();
                /** pending, found, not_found, manual */
                $table->string('status', 16)->default('pending')->index();
                $table->boolean('exact')->default(false);
                $table->string('source', 20)->nullable();
                $table->decimal('suggested_lat', 10, 7)->nullable();
                $table->decimal('suggested_lng', 10, 7)->nullable();
                $table->foreignId('suggested_by')->nullable();
                $table->timestamp('suggested_at')->nullable()->index();
                $table->unsignedTinyInteger('tries')->default(0);
                $table->timestamps();
            });
        }

        if (! Schema::hasTable('trip_routes')) {
            Schema::create('trip_routes', function (Blueprint $table) {
                $table->id();
                $table->foreignId('deliverylog_id')->unique();
                $table->boolean('locked')->default(false);
                $table->string('source', 40)->nullable();
                $table->decimal('km', 8, 1)->nullable();
                $table->unsignedInteger('minutes')->nullable();
                $table->string('boxes_hash', 40)->nullable();
                $table->unsignedSmallInteger('waiting')->default(0);
                $table->unsignedSmallInteger('ai_fixed')->default(0);
                $table->timestamp('sorted_at')->nullable();
                $table->timestamps();
            });
        }

        if (! Schema::hasTable('trip_stops')) {
            Schema::create('trip_stops', function (Blueprint $table) {
                $table->id();
                $table->foreignId('deliverylog_id')->index();
                $table->unsignedSmallInteger('stop_no');
                $table->string('receiver_key', 40);
                $table->string('name')->nullable();
                $table->string('address', 600)->nullable();
                $table->string('barangay')->nullable();
                $table->string('city')->nullable();
                $table->string('phone', 40)->nullable();
                $table->decimal('lat', 10, 7)->nullable();
                $table->decimal('lng', 10, 7)->nullable();
                $table->boolean('exact')->default(false);
                $table->foreignId('geo_place_id')->nullable();
                /** front, middle, back */
                $table->string('zone', 8)->default('middle');
                $table->unsignedSmallInteger('boxes')->default(0);
                $table->boolean('priority')->default(false);
                $table->json('box_ids')->nullable();
                $table->timestamps();
                $table->unique(['deliverylog_id', 'receiver_key']);
            });
        }
    }

    public function down(): void
    {
        Schema::dropIfExists('trip_stops');
        Schema::dropIfExists('trip_routes');
        Schema::dropIfExists('geo_places');
    }
};
