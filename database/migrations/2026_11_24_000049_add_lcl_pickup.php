<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

/** Board 63: the partner hub counts the LCL boxes at the forwarder and keeps a photo of the release. */
return new class extends Migration
{
    public function up(): void
    {
        if (Schema::hasTable('sea_shipments') && ! Schema::hasColumn('sea_shipments', 'pickup_count')) {
            Schema::table('sea_shipments', function (Blueprint $t) {
                $t->unsignedInteger('pickup_count')->nullable();
                $t->string('pickup_photo')->nullable();
                $t->foreignId('pickup_by')->nullable();
                $t->timestamp('pickup_at')->nullable();
            });
        }
    }

    public function down(): void
    {
        if (Schema::hasColumn('sea_shipments', 'pickup_count')) {
            Schema::table('sea_shipments', fn (Blueprint $t) => $t->dropColumn(['pickup_count', 'pickup_photo', 'pickup_by', 'pickup_at']));
        }
    }
};
