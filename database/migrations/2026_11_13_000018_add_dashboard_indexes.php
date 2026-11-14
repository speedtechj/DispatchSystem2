<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

/** Faster dashboard: indexes for the box counts (added only when missing). */
return new class extends Migration
{
    protected array $indexes = [
        'tripinvoices' => [['is_delivered', 'updated_at'], ['logistichub_id'], ['is_delivered', 'deliverylog_id']],
        'invoices' => [['is_verified', 'is_assigned']],
        'truck_positions' => [['deliverylog_id', 'recorded_at']],
    ];

    public function up(): void
    {
        foreach ($this->indexes as $table => $list) {
            if (! Schema::hasTable($table)) {
                continue;
            }
            $have = collect(Schema::getIndexes($table))->pluck('columns')->all();
            foreach ($list as $cols) {
                if (! collect($cols)->every(fn ($c) => Schema::hasColumn($table, $c))) {
                    continue;
                }
                if (collect($have)->contains(fn ($c) => array_slice($c, 0, count($cols)) === $cols)) {
                    continue;
                }
                Schema::table($table, fn (Blueprint $t) => $t->index($cols, 'ds_'.$table.'_'.implode('_', $cols).'_idx'));
            }
        }
    }

    public function down(): void
    {
        foreach ($this->indexes as $table => $list) {
            foreach ($list as $cols) {
                $name = 'ds_'.$table.'_'.implode('_', $cols).'_idx';
                if (Schema::hasTable($table) && collect(Schema::getIndexes($table))->contains('name', $name)) {
                    Schema::table($table, fn (Blueprint $t) => $t->dropIndex($name));
                }
            }
        }
    }
};
