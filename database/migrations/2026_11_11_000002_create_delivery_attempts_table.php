<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

/**
 * One row each time a driver could not deliver a box, with the reason, a note
 * and proof photos. Kept as history, so repeated attempts are visible.
 */
return new class extends Migration
{
    public function up(): void
    {
        Schema::create('delivery_attempts', function (Blueprint $table) {
            $table->id();
            $table->foreignId('tripinvoice_id')->constrained()->cascadeOnDelete();
            $table->foreignId('invoice_id')->constrained();
            $table->foreignId('deliverylog_id')->nullable()->constrained();
            $table->foreignId('user_id')->constrained();
            $table->string('reason', 40);
            $table->text('note')->nullable();
            $table->json('photos')->nullable();
            $table->timestamps();

            $table->index(['invoice_id', 'created_at']);
        });
    }

    public function down(): void
    {
        Schema::dropIfExists('delivery_attempts');
    }
};
