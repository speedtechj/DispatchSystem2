<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

/** Where the phone was when the driver handed the boxes over at the port. */
return new class extends Migration
{
    public function up(): void
    {
        Schema::table('sea_shipments', function (Blueprint $t) {
            $t->decimal('port_lat', 10, 7)->nullable();
            $t->decimal('port_lng', 10, 7)->nullable();
        });
    }

    public function down(): void
    {
        Schema::table('sea_shipments', fn (Blueprint $t) => $t->dropColumn(['port_lat', 'port_lng']));
    }
};
