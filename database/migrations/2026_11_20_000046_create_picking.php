<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

/** Picking (board 49): pickers per trip, what was picked and by whom, and a live log. */
return new class extends Migration
{
    public function up(): void
    {
        if (! Schema::hasTable('trip_pickers')) {
            Schema::create('trip_pickers', function (Blueprint $t) {
                $t->id();
                $t->foreignId('deliverylog_id')->index();
                $t->foreignId('user_id')->index();
                $t->string('how', 12)->default('office'); // office · suggested · took
                $t->foreignId('by_user_id')->nullable();
                $t->timestamps();
                $t->unique(['deliverylog_id', 'user_id']);
            });
        }
        if (! Schema::hasTable('pick_logs')) {
            Schema::create('pick_logs', function (Blueprint $t) {
                $t->id();
                $t->foreignId('deliverylog_id')->index();
                $t->foreignId('user_id')->nullable();
                $t->string('invoice', 40)->nullable();
                $t->string('what', 20); // picked · undone · not_found · wrong · took · assigned
                $t->string('note', 255)->nullable();
                $t->timestamp('created_at')->nullable();
            });
        }
        Schema::table('tripinvoices', function (Blueprint $t) {
            foreach (['picked_at' => 'timestamp', 'missing_at' => 'timestamp'] as $c => $type) {
                if (! Schema::hasColumn('tripinvoices', $c)) {
                    $t->timestamp($c)->nullable();
                }
            }
            foreach (['picked_by', 'missing_by'] as $c) {
                if (! Schema::hasColumn('tripinvoices', $c)) {
                    $t->foreignId($c)->nullable();
                }
            }
        });
    }

    public function down(): void
    {
        Schema::dropIfExists('trip_pickers');
        Schema::dropIfExists('pick_logs');
        Schema::table('tripinvoices', function (Blueprint $t) {
            foreach (['picked_at', 'missing_at', 'picked_by', 'missing_by'] as $c) {
                if (Schema::hasColumn('tripinvoices', $c)) {
                    $t->dropColumn($c);
                }
            }
        });
    }
};
