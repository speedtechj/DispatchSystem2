<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

/**
 * Missing barangay: the system fills it in (same receiver, map, driver GPS, AI).
 * The manifest address is never changed; the filled barangay is kept here.
 */
return new class extends Migration
{
    public function up(): void
    {
        if (! Schema::hasTable('barangay_fills')) {
            Schema::create('barangay_fills', function (Blueprint $t) {
                $t->id();
                $t->foreignId('invoice_id')->unique();
                $t->foreignId('container_id')->nullable()->index();
                $t->string('barangay', 120)->nullable();
                $t->string('source', 10)->nullable();       // same, map, driver, ai, office
                $t->unsignedTinyInteger('confidence')->default(0);
                $t->string('clue', 300)->nullable();
                $t->json('clues')->nullable();              // words in the address the AI used
                $t->json('candidates')->nullable();         // [{name, pct, why}]
                $t->string('status', 10)->default('pending')->index(); // pending, used, check, checked, none
                $t->foreignId('checked_by')->nullable();
                $t->timestamp('checked_at')->nullable();
                $t->unsignedTinyInteger('tries')->default(0);
                $t->timestamps();
            });
        }
        if (! Schema::hasTable('receiver_places')) {
            Schema::create('receiver_places', function (Blueprint $t) {
                $t->id();
                $t->string('key', 64)->unique();            // p + phone, or n + name/street
                $t->string('city_key', 80)->index();
                $t->string('barangay', 120)->nullable();
                $t->string('source', 10)->nullable();
                $t->decimal('lat', 10, 7)->nullable();
                $t->decimal('lng', 10, 7)->nullable();
                $t->timestamp('confirmed_at')->nullable();
                $t->timestamps();
            });
        }
        if (Schema::hasTable('geo_places') && ! Schema::hasColumn('geo_places', 'barangay')) {
            Schema::table('geo_places', fn (Blueprint $t) => $t->string('barangay', 120)->nullable());
        }
        if (Schema::hasTable('trip_stops') && ! Schema::hasColumn('trip_stops', 'barangay_note')) {
            Schema::table('trip_stops', fn (Blueprint $t) => $t->string('barangay_note', 40)->nullable());
        }
    }

    public function down(): void
    {
        Schema::dropIfExists('barangay_fills');
        Schema::dropIfExists('receiver_places');
        if (Schema::hasColumn('geo_places', 'barangay')) {
            Schema::table('geo_places', fn (Blueprint $t) => $t->dropColumn('barangay'));
        }
        if (Schema::hasColumn('trip_stops', 'barangay_note')) {
            Schema::table('trip_stops', fn (Blueprint $t) => $t->dropColumn('barangay_note'));
        }
    }
};
