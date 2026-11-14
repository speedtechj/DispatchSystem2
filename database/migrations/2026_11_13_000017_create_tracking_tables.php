<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

/** Truck tracking: where each truck was (during trips only), alerts, and the driver's yes to sharing location. */
return new class extends Migration
{
    public function up(): void
    {
        if (! Schema::hasTable('truck_positions')) {
            Schema::create('truck_positions', function (Blueprint $table) {
                $table->id();
                $table->foreignId('truck_id');
                $table->foreignId('deliverylog_id')->nullable()->index();
                $table->foreignId('user_id')->nullable();
                $table->decimal('lat', 10, 7);
                $table->decimal('lng', 10, 7);
                $table->decimal('speed', 6, 1)->nullable();   // km/h
                $table->unsignedSmallInteger('heading')->nullable();
                $table->unsignedSmallInteger('accuracy')->nullable(); // metres
                $table->string('source', 12)->default('app');
                $table->timestamp('recorded_at');
                $table->index(['truck_id', 'recorded_at']);
            });
        }

        if (! Schema::hasTable('truck_alerts')) {
            Schema::create('truck_alerts', function (Blueprint $table) {
                $table->id();
                $table->foreignId('truck_id')->index();
                $table->foreignId('deliverylog_id')->nullable()->index();
                /** stopped, no_signal, off_route, back_with_boxes */
                $table->string('kind', 20);
                $table->string('title');
                $table->string('text', 500)->nullable();
                $table->decimal('lat', 10, 7)->nullable();
                $table->decimal('lng', 10, 7)->nullable();
                $table->timestamp('started_at');
                $table->timestamp('ended_at')->nullable();
                $table->foreignId('checked_by')->nullable();
                $table->timestamp('checked_at')->nullable();
                $table->string('note', 500)->nullable();
                $table->timestamps();
            });
        }

        if (! Schema::hasColumn('users', 'tracking_consent_at')) {
            Schema::table('users', function (Blueprint $table) {
                $table->timestamp('tracking_consent_at')->nullable();
            });
        }
    }

    public function down(): void
    {
        Schema::dropIfExists('truck_alerts');
        Schema::dropIfExists('truck_positions');
        if (Schema::hasColumn('users', 'tracking_consent_at')) {
            Schema::table('users', fn (Blueprint $table) => $table->dropColumn('tracking_consent_at'));
        }
    }
};
