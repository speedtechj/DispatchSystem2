<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

/** AI helpers: one settings row (API key, models, spending limit, features), usage log, photo checks, alerts, customer chats. */
return new class extends Migration
{
    public function up(): void
    {
        Schema::create('ai_settings', function (Blueprint $table) {
            $table->id();
            $table->text('api_key')->nullable(); // stored encrypted
            $table->string('model_fast')->default('claude-haiku-5-5');
            $table->string('model_smart')->default('claude-sonnet-5-5');
            $table->decimal('monthly_limit', 8, 2)->default(20);
            $table->json('features')->nullable();
            $table->timestamps();
        });

        Schema::create('ai_usage', function (Blueprint $table) {
            $table->id();
            $table->string('feature', 40)->index();
            $table->string('model', 80);
            $table->unsignedInteger('input_tokens')->default(0);
            $table->unsignedInteger('output_tokens')->default(0);
            $table->decimal('cost', 10, 5)->default(0);
            $table->boolean('ok')->default(true);
            $table->string('error')->nullable();
            $table->foreignId('user_id')->nullable();
            $table->timestamp('created_at')->nullable()->index();
        });

        Schema::create('ai_photo_checks', function (Blueprint $table) {
            $table->id();
            $table->string('source', 20); // scan, delivery
            $table->foreignId('box_photo_id')->nullable()->unique();
            $table->foreignId('tripinvoice_id')->nullable()->index();
            $table->string('path');
            $table->string('step', 30)->nullable();
            $table->string('invoice')->nullable()->index();
            $table->foreignId('invoice_id')->nullable()->index();
            $table->string('worker_said', 30)->nullable();
            $table->string('verdict', 20)->nullable(); // ok, damaged, wet, open, blurry, no_box, unclear
            $table->unsignedTinyInteger('confidence')->default(0);
            $table->string('note')->nullable();
            $table->boolean('flagged')->default(false)->index();
            $table->string('decision', 20)->nullable(); // damaged, fine
            $table->foreignId('decided_by')->nullable();
            $table->timestamp('decided_at')->nullable();
            $table->foreignId('invoiceissue_id')->nullable();
            $table->foreignId('warehouse_id')->nullable();
            $table->foreignId('logistichub_id')->nullable()->index();
            $table->timestamp('checked_at')->nullable();
            $table->timestamps();
            $table->unique(['tripinvoice_id', 'path']);
        });

        Schema::create('ai_alerts', function (Blueprint $table) {
            $table->id();
            $table->string('key')->unique(); // one alert per problem
            $table->string('kind', 30)->index();
            $table->string('severity', 10)->default('mid'); // high, mid, low
            $table->string('title');
            $table->text('body');
            $table->string('link')->nullable();
            $table->foreignId('warehouse_id')->nullable();
            $table->foreignId('logistichub_id')->nullable()->index();
            $table->string('status', 12)->default('open')->index(); // open, checked, ignored
            $table->foreignId('handled_by')->nullable();
            $table->timestamp('handled_at')->nullable();
            $table->timestamps();
        });

        Schema::create('ai_chats', function (Blueprint $table) {
            $table->id();
            $table->string('token', 64)->unique();
            $table->foreignId('invoice_id')->index();
            $table->string('invoice');
            $table->json('messages')->nullable();
            $table->boolean('needs_staff')->default(false);
            $table->string('ip', 64)->nullable();
            $table->timestamps();
        });

        Schema::create('ai_risk_marks', function (Blueprint $table) {
            $table->id();
            $table->foreignId('tripinvoice_id')->unique();
            $table->string('status', 20); // texted, removed, ok
            $table->text('message')->nullable();
            $table->foreignId('user_id')->nullable();
            $table->timestamps();
        });
    }

    public function down(): void
    {
        foreach (['ai_risk_marks', 'ai_chats', 'ai_alerts', 'ai_photo_checks', 'ai_usage', 'ai_settings'] as $t) {
            Schema::dropIfExists($t);
        }
    }
};
