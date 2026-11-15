<?php

use App\Support\Help\Help;
use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

/** Counting a warehouse section (and moving boxes into it) with the Scan app. */
return new class extends Migration
{
    public function up(): void
    {
        Schema::create('wh_counts', function (Blueprint $t) {
            $t->id();
            $t->foreignId('wh_section_id')->index();
            $t->foreignId('user_id')->nullable();
            $t->unsignedInteger('expected')->nullable();
            $t->unsignedInteger('found')->nullable();
            $t->unsignedInteger('missing')->nullable();
            $t->unsignedInteger('moved_in')->nullable();
            $t->timestamp('finished_at')->nullable();
            $t->timestamps();
        });
        Schema::create('wh_count_scans', function (Blueprint $t) {
            $t->id();
            $t->foreignId('wh_count_id');
            $t->foreignId('invoice_id');
            $t->foreignId('user_id')->nullable();
            $t->foreignId('moved_from')->nullable(); // section it was in before
            $t->timestamp('created_at')->nullable();
            $t->unique(['wh_count_id', 'invoice_id']);
        });
        Help::installDefaults();
    }

    public function down(): void
    {
        Schema::dropIfExists('wh_count_scans');
        Schema::dropIfExists('wh_counts');
    }
};
