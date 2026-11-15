<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

/** Partner hub by truck (Luzon): the hub scans the boxes in when the truck arrives (Scan app · Receive truck). */
return new class extends Migration
{
    public function up(): void
    {
        if (! Schema::hasTable('truck_receipts')) {
            Schema::create('truck_receipts', function (Blueprint $t) {
                $t->id();
                $t->foreignId('deliverylog_id');
                $t->foreignId('logistichub_id');
                $t->timestamp('finished_at')->nullable();
                $t->foreignId('finished_by')->nullable();
                $t->unsignedInteger('missing')->default(0);
                $t->timestamps();
                $t->unique(['deliverylog_id', 'logistichub_id']);
            });
        }
        if (! Schema::hasTable('truck_receipt_scans')) {
            Schema::create('truck_receipt_scans', function (Blueprint $t) {
                $t->id();
                $t->foreignId('deliverylog_id');
                $t->foreignId('logistichub_id');
                $t->foreignId('invoice_id');
                $t->foreignId('user_id')->nullable();
                $t->timestamp('created_at')->nullable();
                $t->unique(['deliverylog_id', 'invoice_id']);
            });
        }

        // New help guides (Receive truck, and Find your way in the side menu).
        \App\Support\Help\Help::installDefaults();
    }

    public function down(): void
    {
        Schema::dropIfExists('truck_receipt_scans');
        Schema::dropIfExists('truck_receipts');
    }
};
