<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

/** Duplicate trucks: each merge (for Undo) and each "Different trucks" answer. */
return new class extends Migration
{
    public function up(): void
    {
        if (! Schema::hasTable('truck_merges')) {
            Schema::create('truck_merges', function (Blueprint $t) {
                $t->id();
                $t->string('kind', 12)->default('merge'); // merge | different
                $t->foreignId('kept_id')->index();
                $t->foreignId('dropped_id')->index();
                $t->json('moved')->nullable();    // {table: [row ids]}
                $t->json('before')->nullable();   // kept / dropped fields before the merge
                $t->foreignId('user_id')->nullable();
                $t->timestamp('undone_at')->nullable();
                $t->timestamps();
            });
        }
    }

    public function down(): void
    {
        Schema::dropIfExists('truck_merges');
    }
};
