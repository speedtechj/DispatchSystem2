<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

/**
 * Speed: indexes for the columns the lists, Box aging and the AI helpers search on most.
 * Only added where they are missing (MySQL already has some from the foreign keys).
 */
return new class extends Migration
{
    protected array $indexes = [
        'invoices' => [['is_delivered'], ['is_verified', 'is_delivered'], ['receiver_province']],
        'tripinvoices' => [['invoice_id'], ['deliverylog_id'], ['deliveryloghub_id'], ['is_delivered', 'delivered_at'], ['delivered_by']],
        'whtripinvoices' => [['invoice_id'], ['whdeliverylog_id'], ['is_unloaded']],
        'containers' => [['unloaded_at'], ['created_at'], ['is_unloaded']],
        'deliverylogs' => [['is_active'], ['logistichub_id'], ['assigned_to'], ['truck_id']],
        'delivery_attempts' => [['tripinvoice_id'], ['created_at']],
        'invoiceissues' => [['invoice_id']],
    ];

    public function up(): void
    {
        foreach ($this->indexes as $table => $list) {
            if (! Schema::hasTable($table)) {
                continue;
            }
            foreach ($list as $columns) {
                if (array_diff($columns, Schema::getColumnListing($table)) || $this->has($table, $columns)) {
                    continue;
                }
                Schema::table($table, fn (Blueprint $t) => $t->index($columns, $this->name($table, $columns)));
            }
        }
    }

    public function down(): void
    {
        foreach ($this->indexes as $table => $list) {
            foreach ($list as $columns) {
                if (Schema::hasTable($table) && in_array($this->name($table, $columns), array_column(Schema::getIndexes($table), 'name'), true)) {
                    Schema::table($table, fn (Blueprint $t) => $t->dropIndex($this->name($table, $columns)));
                }
            }
        }
    }

    /** Any index (or foreign key index) that starts with these columns already helps. */
    protected function has(string $table, array $columns): bool
    {
        foreach (Schema::getIndexes($table) as $index) {
            if (array_slice($index['columns'], 0, count($columns)) === $columns) {
                return true;
            }
        }

        return false;
    }

    protected function name(string $table, array $columns): string
    {
        return 'ds_'.$table.'_'.implode('_', $columns).'_idx';
    }
};
