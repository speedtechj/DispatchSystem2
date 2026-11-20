<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

/** Speed: indexes the Delivery trips page and its cards use. Safe to run again: skips what exists. */
return new class extends Migration
{
    /** table => [index name => columns] */
    protected array $indexes = [
        'delivery_attempts' => ['delivery_attempts_trip_created_idx' => ['deliverylog_id', 'created_at']],
        'delivery_reversals' => ['delivery_reversals_trip_created_idx' => ['deliverylog_id', 'created_at']],
        'truckcrews' => ['truckcrews_truck_idx' => ['truck_id']],
    ];

    public function up(): void
    {
        foreach ($this->indexes as $table => $list) {
            if (! Schema::hasTable($table)) {
                continue;
            }
            foreach ($list as $name => $cols) {
                if (! Schema::hasColumns($table, $cols) || Schema::hasIndex($table, $name) || Schema::hasIndex($table, $cols)) {
                    continue;
                }
                Schema::table($table, fn (Blueprint $t) => $t->index($cols, $name));
            }
        }
    }

    public function down(): void
    {
        foreach ($this->indexes as $table => $list) {
            foreach ($list as $name => $cols) {
                if (Schema::hasTable($table) && Schema::hasIndex($table, $name)) {
                    Schema::table($table, fn (Blueprint $t) => $t->dropIndex($name));
                }
            }
        }
    }
};
