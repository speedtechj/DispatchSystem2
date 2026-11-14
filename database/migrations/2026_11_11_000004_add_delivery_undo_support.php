<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

/**
 * Who delivered a box and exactly when (needed for the 30-minute undo window),
 * and a history of deliveries that were undone, with who, when, why and the photos.
 */
return new class extends Migration
{
    public function up(): void
    {
        Schema::table('tripinvoices', function (Blueprint $table) {
            $table->timestamp('delivered_at')->nullable();
            $table->foreignId('delivered_by')->nullable()->constrained('users')->nullOnDelete();
        });

        Schema::create('delivery_reversals', function (Blueprint $table) {
            $table->id();
            $table->foreignId('tripinvoice_id')->nullable()->constrained()->nullOnDelete();
            $table->foreignId('invoice_id')->constrained();
            $table->foreignId('deliverylog_id')->nullable()->constrained();
            $table->foreignId('user_id')->constrained();             // who undid it
            $table->foreignId('delivered_by')->nullable()->constrained('users')->nullOnDelete();
            $table->timestamp('delivered_at')->nullable();           // the delivery that was undone
            $table->string('reason', 40);
            $table->text('note')->nullable();
            $table->json('photos')->nullable();                      // the delivery photos, kept
            $table->boolean('by_office')->default(false);
            $table->timestamps();

            $table->index(['invoice_id', 'created_at']);
        });
    }

    public function down(): void
    {
        Schema::dropIfExists('delivery_reversals');

        Schema::table('tripinvoices', function (Blueprint $table) {
            $table->dropConstrainedForeignId('delivered_by');
            $table->dropColumn('delivered_at');
        });
    }
};
