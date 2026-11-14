<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

/** Box aging: warning and late limits per stage (and region), and who is told. */
return new class extends Migration
{
    public function up(): void
    {
        Schema::create('ai_aging_limits', function (Blueprint $table) {
            $table->id();
            $table->string('stage', 20);
            $table->string('region', 20)->default('all');
            $table->unsignedSmallInteger('warn_days');
            $table->unsignedSmallInteger('late_days');
            $table->string('reason')->nullable();
            $table->timestamps();
            $table->unique(['stage', 'region']);
        });

        Schema::table('ai_settings', function (Blueprint $table) {
            $table->json('aging')->nullable()->after('features'); // email per group, summary hour, last summary date
        });
    }

    public function down(): void
    {
        Schema::dropIfExists('ai_aging_limits');
        Schema::table('ai_settings', fn (Blueprint $table) => $table->dropColumn('aging'));
    }
};
