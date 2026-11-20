<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

/** How a trip was made: ai (Plan trips with an AI request), plan (Plan trips), changed (plan changed before Create), manual (by hand). */
return new class extends Migration
{
    public function up(): void
    {
        if (! Schema::hasColumn('deliverylogs', 'made_by')) {
            Schema::table('deliverylogs', function (Blueprint $t) {
                $t->string('made_by', 12)->nullable()->index();
                $t->string('made_note', 300)->nullable();
            });
        }
    }

    public function down(): void
    {
        if (Schema::hasColumn('deliverylogs', 'made_by')) {
            Schema::table('deliverylogs', fn (Blueprint $t) => $t->dropColumn(['made_by', 'made_note']));
        }
    }
};
