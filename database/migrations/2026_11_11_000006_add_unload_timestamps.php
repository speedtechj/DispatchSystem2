<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

/**
 * When a box was scanned off its container, and when a container was marked unloaded.
 * Used by the Containers and Invoice Issue widgets. Older rows stay empty.
 */
return new class extends Migration
{
    public function up(): void
    {
        Schema::table('invoices', function (Blueprint $table) {
            $table->timestamp('verified_at')->nullable()->index();
        });

        Schema::table('containers', function (Blueprint $table) {
            $table->timestamp('unloaded_at')->nullable();
        });
    }

    public function down(): void
    {
        Schema::table('invoices', function (Blueprint $table) {
            $table->dropIndex(['verified_at']);
            $table->dropColumn('verified_at');
        });

        Schema::table('containers', function (Blueprint $table) {
            $table->dropColumn('unloaded_at');
        });
    }
};
