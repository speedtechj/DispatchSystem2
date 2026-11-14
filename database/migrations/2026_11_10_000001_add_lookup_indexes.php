<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

/**
 * Indexes for the columns every scan and assignment screen filters on.
 * Without them each barcode scan was a full scan of the invoices table.
 */
return new class extends Migration
{
    public function up(): void
    {
        Schema::table('invoices', function (Blueprint $table) {
            $table->index('invoice', 'idx_invoices_invoice');
            $table->index(['container_id', 'invoice'], 'idx_invoices_container_invoice');
            $table->index('location_code', 'idx_invoices_location_code');
            $table->index(['is_assigned', 'is_verified'], 'idx_invoices_assigned_verified');
            $table->index(['warehouse_id', 'wh_is_assigned'], 'idx_invoices_warehouse_assigned');
        });

        Schema::table('tripinvoices', function (Blueprint $table) {
            $table->index('invoice', 'idx_tripinvoices_invoice');
        });

        Schema::table('consolidators', function (Blueprint $table) {
            $table->index('code', 'idx_consolidators_code');
        });
    }

    public function down(): void
    {
        Schema::table('invoices', function (Blueprint $table) {
            $table->dropIndex('idx_invoices_invoice');
            $table->dropIndex('idx_invoices_container_invoice');
            $table->dropIndex('idx_invoices_location_code');
            $table->dropIndex('idx_invoices_assigned_verified');
            $table->dropIndex('idx_invoices_warehouse_assigned');
        });

        Schema::table('tripinvoices', function (Blueprint $table) {
            $table->dropIndex('idx_tripinvoices_invoice');
        });

        Schema::table('consolidators', function (Blueprint $table) {
            $table->dropIndex('idx_consolidators_code');
        });
    }
};
