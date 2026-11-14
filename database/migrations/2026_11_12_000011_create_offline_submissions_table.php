<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

/** Deliveries and not-delivered boxes saved on a driver's phone without signal, sent later. */
return new class extends Migration
{
    public function up(): void
    {
        Schema::create('offline_submissions', function (Blueprint $table) {
            $table->id();
            $table->uuid('uuid')->unique();             // made on the phone; sending twice does nothing
            $table->unsignedBigInteger('user_id')->index();
            $table->unsignedBigInteger('tripinvoice_id')->nullable()->index();
            $table->string('type', 12);                 // deliver, miss
            $table->string('status', 12);               // saved, conflict
            $table->string('message')->nullable();
            $table->timestamp('happened_at')->nullable(); // time on the phone
            $table->json('payload')->nullable();
            $table->timestamps();
        });
    }

    public function down(): void
    {
        Schema::dropIfExists('offline_submissions');
    }
};
