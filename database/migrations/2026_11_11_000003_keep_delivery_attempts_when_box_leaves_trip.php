<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

/**
 * When an undelivered box is returned (taken off its trip), keep the driver's
 * reasons and photos: the attempt just loses its link to the old trip row.
 */
return new class extends Migration
{
    public function up(): void
    {
        Schema::table('delivery_attempts', function (Blueprint $table) {
            $table->dropForeign(['tripinvoice_id']);
        });

        Schema::table('delivery_attempts', function (Blueprint $table) {
            $table->unsignedBigInteger('tripinvoice_id')->nullable()->change();
            $table->foreign('tripinvoice_id')->references('id')->on('tripinvoices')->nullOnDelete();
        });
    }

    public function down(): void
    {
        Schema::table('delivery_attempts', function (Blueprint $table) {
            $table->dropForeign(['tripinvoice_id']);
            $table->foreign('tripinvoice_id')->references('id')->on('tripinvoices')->cascadeOnDelete();
        });
    }
};
