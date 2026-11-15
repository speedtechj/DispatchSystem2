<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

/**
 * Next trip waiting: a trip planned for a truck that is still out waits for that trip to close.
 * ready_at: when the trip was locked (for "Trip ready but nobody took it").
 */
return new class extends Migration
{
    public function up(): void
    {
        Schema::table('deliverylogs', function (Blueprint $t) {
            if (! Schema::hasColumn('deliverylogs', 'waits_for')) {
                $t->foreignId('waits_for')->nullable()->index();
                $t->timestamp('ready_at')->nullable();
            }
        });
        \App\Support\Help\Help::installDefaults();
    }

    public function down(): void
    {
        Schema::table('deliverylogs', function (Blueprint $t) {
            if (Schema::hasColumn('deliverylogs', 'waits_for')) {
                $t->dropColumn(['waits_for', 'ready_at']);
            }
        });
    }
};
