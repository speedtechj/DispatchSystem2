<?php

use App\Support\Boxes\BoxSets;
use App\Support\Help\Help;
use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Schema;

/**
 * Warehouse sections (each one for a destination, chosen by the receiver's province),
 * box sets (all boxes of one customer), who scanned each box, and the truck waiting
 * at a container unload (boxes go straight from the container onto the truck).
 */
return new class extends Migration
{
    public function up(): void
    {
        Schema::create('wh_sections', function (Blueprint $t) {
            $t->id();
            $t->foreignId('warehouse_id')->nullable()->index();
            $t->string('code', 8);
            $t->string('name', 80);
            $t->string('color', 7)->default('#1d6fb8');
            $t->string('kind', 12)->default('area'); // area, returns, check
            $t->foreignId('logistichub_id')->nullable();   // boxes for this partner hub
            $t->foreignId('to_warehouse_id')->nullable();  // boxes for this other warehouse (e.g. Tarlac)
            $t->json('provinces')->nullable();
            $t->unsignedSmallInteger('sort')->default(0);
            $t->boolean('is_active')->default(true);
            $t->timestamps();
        });

        Schema::table('invoices', function (Blueprint $t) {
            $t->foreignId('wh_section_id')->nullable()->index();
            $t->timestamp('sectioned_at')->nullable();
            $t->foreignId('verified_by')->nullable();
            $t->string('set_key', 40)->nullable()->index();
        });
        Schema::table('tripinvoices', function (Blueprint $t) {
            $t->foreignId('loaded_by')->nullable();
            $t->timestamp('loaded_at')->nullable();
        });
        Schema::table('whtripinvoices', function (Blueprint $t) {
            $t->foreignId('loaded_by')->nullable();
            $t->timestamp('loaded_at')->nullable();
        });

        Schema::create('wh_crossdocks', function (Blueprint $t) {
            $t->id();
            $t->foreignId('container_id')->index();
            $t->foreignId('whdeliverylog_id');
            $t->foreignId('started_by')->nullable();
            $t->boolean('paused')->default(false);
            $t->timestamp('ended_at')->nullable();
            $t->timestamps();
        });

        Schema::create('set_splits', function (Blueprint $t) {
            $t->id();
            $t->foreignId('invoice_id')->index();
            $t->string('set_key', 40)->nullable();
            $t->foreignId('deliverylog_id')->nullable();
            $t->string('reason', 40);
            $t->foreignId('user_id')->nullable();
            $t->timestamps();
        });

        // sets for the boxes already in the system
        DB::table('invoices')->select('id', 'receiver_name', 'receiver_mobile_no', 'receiver_city')->orderBy('id')
            ->chunkById(500, function ($rows) {
                foreach ($rows as $r) {
                    DB::table('invoices')->where('id', $r->id)->update(['set_key' => BoxSets::keyFor($r->receiver_name, $r->receiver_mobile_no, $r->receiver_city)]);
                }
            });

        Help::installDefaults();
    }

    public function down(): void
    {
        Schema::dropIfExists('set_splits');
        Schema::dropIfExists('wh_crossdocks');
        Schema::table('whtripinvoices', fn (Blueprint $t) => $t->dropColumn(['loaded_by', 'loaded_at']));
        Schema::table('tripinvoices', fn (Blueprint $t) => $t->dropColumn(['loaded_by', 'loaded_at']));
        Schema::table('invoices', function (Blueprint $t) {
            $t->dropIndex(['wh_section_id']);
            $t->dropIndex(['set_key']);
            $t->dropColumn(['wh_section_id', 'sectioned_at', 'verified_by', 'set_key']);
        });
        Schema::dropIfExists('wh_sections');
    }
};
