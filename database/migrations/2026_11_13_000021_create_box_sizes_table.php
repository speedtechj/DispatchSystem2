<?php

use App\Support\Help\Help;
use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

/** Box sizes: how much truck space each box type from the manifests takes (your normal box = 1). */
return new class extends Migration
{
    public function up(): void
    {
        if (! Schema::hasTable('box_sizes')) {
            Schema::create('box_sizes', function (Blueprint $table) {
                $table->id();
                /** The name shown, as most often written on the manifests. */
                $table->string('name', 80);
                /** Every way it is written, cleaned ("LARGE", "Large box", "large" → "large"). */
                $table->json('spellings');
                /** Truck space it takes, in normal boxes. */
                $table->decimal('space', 4, 1)->default(1);
                $table->boolean('is_base')->default(false);
                /** False until an admin has looked at it (shown as New · not set). */
                $table->boolean('is_set')->default(false);
                /** Box types the admin said are not the same as this one. */
                $table->json('kept_apart')->nullable();
                $table->timestamps();
            });
        }

        Help::installDefaults();
    }

    public function down(): void
    {
        Schema::dropIfExists('box_sizes');
    }
};
