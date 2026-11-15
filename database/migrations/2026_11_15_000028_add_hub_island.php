<?php

use App\Support\Help\Help;
use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

/** Where each hub is (Luzon, Visayas, Mindanao), whether boxes go there by sea, and its usual port. */
return new class extends Migration
{
    public function up(): void
    {
        Schema::table('logistichubs', function (Blueprint $t) {
            $t->string('island', 10)->nullable();
            $t->boolean('by_sea')->nullable();
            $t->string('port', 80)->nullable();
        });
        Help::installDefaults();
    }

    public function down(): void
    {
        Schema::table('logistichubs', fn (Blueprint $t) => $t->dropColumn(['island', 'by_sea', 'port']));
    }
};
