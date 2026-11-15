<?php

use App\Support\Help\Help;
use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

/** Return shipments: boxes a partner hub sends back to the warehouse, scanned in when they arrive. */
return new class extends Migration
{
    public function up(): void
    {
        Schema::create('return_shipments', function (Blueprint $t) {
            $t->id();
            $t->string('code', 20)->unique();
            $t->foreignId('logistichub_id')->index();   // the partner hub sending it
            $t->foreignId('warehouse_id')->nullable();
            $t->string('mode', 12)->default('container');
            $t->string('status', 12)->default('preparing'); // preparing, sent, received
            $t->json('status_log')->nullable();
            $t->string('van_no', 20)->nullable();
            $t->string('seal_no', 30)->nullable();
            $t->string('vessel', 80)->nullable();
            $t->string('bl_no', 40)->nullable();
            $t->date('eta')->nullable();
            $t->decimal('cost', 12, 2)->nullable();
            $t->string('note', 300)->nullable();
            $t->foreignId('created_by')->nullable();
            $t->timestamps();
        });
        Schema::table('wrong_hub_boxes', function (Blueprint $t) {
            $t->foreignId('return_shipment_id')->nullable()->index();
            $t->foreignId('received_by')->nullable();
            $t->timestamp('received_at')->nullable();
        });
        Help::installDefaults();
    }

    public function down(): void
    {
        Schema::table('wrong_hub_boxes', fn (Blueprint $t) => $t->dropColumn(['return_shipment_id', 'received_by', 'received_at']));
        Schema::dropIfExists('return_shipments');
    }
};
