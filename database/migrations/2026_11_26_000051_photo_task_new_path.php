<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

/** Part 41: old photos put in the new folders while they are copied or moved. */
return new class extends Migration
{
    public function up(): void
    {
        if (Schema::hasTable('photo_task_items') && ! Schema::hasColumn('photo_task_items', 'new_path')) {
            Schema::table('photo_task_items', function (Blueprint $t) {
                $t->string('new_path', 500)->nullable();   // the path in the new folders (null: keeps its path)
                $t->string('tbl', 64)->nullable();         // the column whose path is changed after the copy
                $t->string('col', 64)->nullable();
            });
        }
    }

    public function down(): void
    {
        if (Schema::hasColumn('photo_task_items', 'new_path')) {
            Schema::table('photo_task_items', fn (Blueprint $t) => $t->dropColumn(['new_path', 'tbl', 'col']));
        }
    }
};
