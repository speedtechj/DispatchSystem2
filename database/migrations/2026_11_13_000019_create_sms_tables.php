<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

/** SMS to receivers, and the AI notes on truck alerts and the end-of-day truck summary. */
return new class extends Migration
{
    public function up(): void
    {
        if (! Schema::hasTable('sms_messages')) {
            Schema::create('sms_messages', function (Blueprint $table) {
                $table->id();
                /** out_for_delivery, driver_next, delivered, not_delivered, hub_arrived, test */
                $table->string('kind', 24)->index();
                $table->foreignId('deliverylog_id')->nullable()->index();
                $table->string('receiver_key', 40)->nullable();
                $table->string('name')->nullable();
                $table->string('number', 20)->nullable()->index();
                $table->string('raw_number', 60)->nullable();
                $table->string('lang', 3)->default('en');
                $table->text('message');
                $table->unsignedTinyInteger('parts')->default(1);
                /** sent, failed, bad_number, opted_out, over_limit, no_key */
                $table->string('status', 16)->index();
                $table->string('provider', 16)->nullable();
                $table->string('provider_id', 80)->nullable();
                $table->string('error', 500)->nullable();
                $table->json('invoice_ids')->nullable();
                $table->foreignId('user_id')->nullable();
                $table->timestamp('sent_at')->nullable();
                $table->timestamps();
                $table->index(['kind', 'deliverylog_id', 'receiver_key']);
                $table->index('created_at');
            });
        }
        if (! Schema::hasTable('sms_optouts')) {
            Schema::create('sms_optouts', function (Blueprint $table) {
                $table->id();
                $table->string('number', 20)->unique();
                $table->string('why', 60)->nullable();
                $table->timestamps();
            });
        }
        if (Schema::hasTable('truck_alerts') && ! Schema::hasColumn('truck_alerts', 'ai_note')) {
            Schema::table('truck_alerts', function (Blueprint $table) {
                $table->text('ai_note')->nullable();
                $table->string('ai_level', 8)->nullable();
                $table->json('ai_actions')->nullable();
            });
        }
        if (! Schema::hasTable('truck_day_summaries')) {
            Schema::create('truck_day_summaries', function (Blueprint $table) {
                $table->id();
                $table->date('day');
                $table->unsignedBigInteger('hub_id')->default(0); // 0 = every hub
                $table->json('data');
                $table->timestamps();
                $table->unique(['day', 'hub_id']);
            });
        }
    }

    public function down(): void
    {
        Schema::dropIfExists('truck_day_summaries');
        Schema::dropIfExists('sms_optouts');
        Schema::dropIfExists('sms_messages');
        if (Schema::hasColumn('truck_alerts', 'ai_note')) {
            Schema::table('truck_alerts', fn (Blueprint $t) => $t->dropColumn(['ai_note', 'ai_level', 'ai_actions']));
        }
    }
};
