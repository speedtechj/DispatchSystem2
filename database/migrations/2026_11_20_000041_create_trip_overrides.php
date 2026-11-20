<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

/** Trip rules: every time a rule was bypassed (who, why), and requests waiting for the office. */
return new class extends Migration
{
    public function up(): void
    {
        if (! Schema::hasTable('trip_overrides')) {
            Schema::create('trip_overrides', function (Blueprint $t) {
                $t->id();
                $t->string('rule', 20)->index();
                $t->string('trip_kind', 10)->default('delivery'); // delivery | transfer
                $t->unsignedBigInteger('trip_id')->nullable()->index();
                $t->string('trip_number', 40)->nullable();
                $t->foreignId('invoice_id')->nullable()->index();
                $t->string('box', 60)->nullable();
                $t->foreignId('user_id')->nullable();
                $t->string('reason', 120)->nullable();
                $t->string('note', 200)->nullable();
                $t->json('data')->nullable();
                $t->string('status', 10)->default('allowed')->index(); // allowed, pending, approved, refused
                $t->foreignId('decided_by')->nullable();
                $t->timestamp('decided_at')->nullable();
                $t->timestamps();
            });
        }
    }

    public function down(): void
    {
        Schema::dropIfExists('trip_overrides');
    }
};
