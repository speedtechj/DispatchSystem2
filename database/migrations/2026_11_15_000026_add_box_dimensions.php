<?php

use App\Support\Help\Help;
use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

/** Box dimensions, the truck's cargo box, how full it can be packed, and a reserve for odd items. */
return new class extends Migration
{
    public function up(): void
    {
        Schema::table('box_sizes', function (Blueprint $t) {
            $t->unsignedSmallInteger('length_cm')->nullable();
            $t->unsignedSmallInteger('width_cm')->nullable();
            $t->unsignedSmallInteger('height_cm')->nullable();
        });
        Schema::table('trucks', function (Blueprint $t) {
            $t->unsignedSmallInteger('cargo_length_cm')->nullable();
            $t->unsignedSmallInteger('cargo_width_cm')->nullable();
            $t->unsignedSmallInteger('cargo_height_cm')->nullable();
            $t->unsignedTinyInteger('fill_pct')->nullable();     // how full it really packs (default 85)
            $t->unsignedTinyInteger('reserve_pct')->nullable();  // kept free for bikes, TVs, odd items
        });
        Help::installDefaults();
    }

    public function down(): void
    {
        Schema::table('trucks', fn (Blueprint $t) => $t->dropColumn(['cargo_length_cm', 'cargo_width_cm', 'cargo_height_cm', 'fill_pct', 'reserve_pct']));
        Schema::table('box_sizes', fn (Blueprint $t) => $t->dropColumn(['length_cm', 'width_cm', 'height_cm']));
    }
};
