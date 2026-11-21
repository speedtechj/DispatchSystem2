<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

/** Sections by city (optional), and spots inside a section (C1, C2…), optional (boards 50 and 50b). */
return new class extends Migration
{
    public function up(): void
    {
        if (Schema::hasTable('wh_sections')) {
            Schema::table('wh_sections', function (Blueprint $t) {
                if (! Schema::hasColumn('wh_sections', 'cities')) {
                    $t->json('cities')->nullable()->after('provinces'); // ["San Jose · Nueva Ecija", …]
                }
                if (! Schema::hasColumn('wh_sections', 'use_spots')) {
                    $t->boolean('use_spots')->default(false)->after('cities');
                }
            });
        }
        if (! Schema::hasTable('wh_spots')) {
            Schema::create('wh_spots', function (Blueprint $t) {
                $t->id();
                $t->foreignId('wh_section_id')->index();
                $t->string('code', 12);
                $t->unsignedSmallInteger('sort')->default(0);
                $t->timestamps();
            });
        }
        if (Schema::hasTable('invoices') && ! Schema::hasColumn('invoices', 'wh_spot_id')) {
            Schema::table('invoices', fn (Blueprint $t) => $t->foreignId('wh_spot_id')->nullable()->index()->after('wh_section_id'));
        }
    }

    public function down(): void
    {
        if (Schema::hasColumn('invoices', 'wh_spot_id')) {
            Schema::table('invoices', fn (Blueprint $t) => $t->dropColumn('wh_spot_id'));
        }
        Schema::dropIfExists('wh_spots');
        if (Schema::hasTable('wh_sections')) {
            Schema::table('wh_sections', function (Blueprint $t) {
                foreach (['cities', 'use_spots'] as $c) {
                    if (Schema::hasColumn('wh_sections', $c)) {
                        $t->dropColumn($c);
                    }
                }
            });
        }
    }
};
