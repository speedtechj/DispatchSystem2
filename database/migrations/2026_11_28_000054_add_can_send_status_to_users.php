<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

/** Part 47b: Settings → Users → "Send status manually" (admins always may, drivers never). */
return new class extends Migration
{
    public function up(): void
    {
        if (! Schema::hasColumn('users', 'can_send_status')) {
            Schema::table('users', fn (Blueprint $t) => $t->boolean('can_send_status')->default(false));
        }
    }

    public function down(): void
    {
        if (Schema::hasColumn('users', 'can_send_status')) {
            Schema::table('users', fn (Blueprint $t) => $t->dropColumn('can_send_status'));
        }
    }
};
