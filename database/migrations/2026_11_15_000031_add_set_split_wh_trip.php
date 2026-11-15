<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

/** Why a customer's box stays behind when a transfer truck (warehouse to warehouse) leaves. */
return new class extends Migration
{
    public function up(): void
    {
        if (Schema::hasTable('set_splits') && ! Schema::hasColumn('set_splits', 'whdeliverylog_id')) {
            Schema::table('set_splits', fn (Blueprint $t) => $t->foreignId('whdeliverylog_id')->nullable()->index());
        }
    }

    public function down(): void
    {
        if (Schema::hasColumn('set_splits', 'whdeliverylog_id')) {
            Schema::table('set_splits', fn (Blueprint $t) => $t->dropColumn('whdeliverylog_id'));
        }
    }
};
