<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class extends Migration
{
    public function up(): void
    {
        Schema::table('brand_assets', function (Blueprint $table) {
            $table->string('scan_icon')->nullable()->after('app_icon');
            $table->string('driver_label', 30)->nullable()->after('scan_icon');
            $table->string('scan_label', 30)->nullable()->after('driver_label');
        });
    }

    public function down(): void
    {
        Schema::table('brand_assets', function (Blueprint $table) {
            $table->dropColumn(['scan_icon', 'driver_label', 'scan_label']);
        });
    }
};
