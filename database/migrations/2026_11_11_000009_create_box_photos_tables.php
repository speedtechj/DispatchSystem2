<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class extends Migration
{
    public function up(): void
    {
        Schema::create('box_photos', function (Blueprint $table) {
            $table->id();
            $table->unsignedBigInteger('invoice_id')->nullable()->index();
            $table->string('invoice', 64)->nullable()->index(); // invoice number, for search
            $table->string('step', 20)->index();                // unload, load, hub_load, wh_load, wh_unload, return
            $table->string('condition', 10)->nullable()->index(); // good, damaged, wet, open
            $table->string('note')->nullable();
            $table->boolean('is_batch')->default(false);
            $table->string('path');
            $table->unsignedInteger('size')->default(0);
            $table->unsignedBigInteger('container_id')->nullable()->index();
            $table->unsignedBigInteger('deliverylog_id')->nullable()->index();
            $table->unsignedBigInteger('whdeliverylog_id')->nullable()->index();
            $table->unsignedBigInteger('warehouse_id')->nullable();
            $table->unsignedBigInteger('logistichub_id')->nullable()->index();
            $table->unsignedBigInteger('user_id')->nullable();
            $table->timestamp('taken_at')->index();
            $table->timestamps();
        });

        Schema::create('box_photo_emails', function (Blueprint $table) {
            $table->id();
            $table->unsignedBigInteger('user_id')->nullable();
            $table->unsignedBigInteger('consolidator_id')->nullable();
            $table->json('recipients');
            $table->string('subject');
            $table->text('message')->nullable();
            $table->json('photo_ids');
            $table->string('status', 10)->default('sent'); // sent, failed
            $table->text('error')->nullable();
            $table->timestamps();
        });

        Schema::create('photo_settings', function (Blueprint $table) {
            $table->id();
            $table->json('places')->nullable();
            $table->unsignedSmallInteger('batch_every')->default(0);
            $table->unsignedSmallInteger('keep_months')->default(6);
            $table->timestamps();
        });
    }

    public function down(): void
    {
        Schema::dropIfExists('photo_settings');
        Schema::dropIfExists('box_photo_emails');
        Schema::dropIfExists('box_photos');
    }
};
