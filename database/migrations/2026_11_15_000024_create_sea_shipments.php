<?php

use App\Support\Help\Help;
use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

/**
 * Sea shipments to partner hubs (Visayas, Mindanao): built on a normal trip to the port,
 * with the van, seal, ship, port check and receiving at the partner hub. Plus the
 * Wrong hub & returns list.
 */
return new class extends Migration
{
    public function up(): void
    {
        Schema::create('sea_shipments', function (Blueprint $t) {
            $t->id();
            $t->string('code', 20)->unique();
            $t->foreignId('deliverylog_id')->unique();   // the trip to the port (a normal trip to the hub)
            $t->foreignId('logistichub_id')->index();     // the partner hub it goes to
            $t->string('mode', 12)->default('container'); // container, roro
            $t->string('status', 12)->default('preparing');
            $t->json('status_log')->nullable();
            $t->string('van_no', 20)->nullable();
            $t->string('van_size', 10)->nullable();
            $t->string('seal_no', 30)->nullable();
            $t->string('seal_photo')->nullable();
            $t->string('shipping_line', 80)->nullable();
            $t->string('vessel', 80)->nullable();
            $t->string('voyage', 30)->nullable();
            $t->string('bl_no', 40)->nullable();
            $t->string('port_from', 80)->nullable();
            $t->string('port_to', 80)->nullable();
            $t->date('etd')->nullable();
            $t->date('eta')->nullable();
            $t->string('port_check', 8)->default('count'); // full, count, off
            $t->unsignedInteger('port_count')->nullable();
            $t->string('port_receipt')->nullable();
            $t->string('port_reason', 200)->nullable();
            $t->foreignId('port_by')->nullable();
            $t->timestamp('port_at')->nullable();
            $t->decimal('cost_freight', 12, 2)->nullable();
            $t->decimal('cost_trucking', 12, 2)->nullable();
            $t->decimal('cost_port', 12, 2)->nullable();
            $t->decimal('cost_other', 12, 2)->nullable();
            $t->string('note', 500)->nullable();
            $t->foreignId('created_by')->nullable();
            $t->timestamps();
        });

        Schema::create('sea_shipment_scans', function (Blueprint $t) {
            $t->id();
            $t->foreignId('sea_shipment_id');
            $t->foreignId('invoice_id');
            $t->string('step', 10); // port, received
            $t->foreignId('user_id')->nullable();
            $t->timestamp('created_at')->nullable();
            $t->unique(['sea_shipment_id', 'invoice_id', 'step']);
        });

        Schema::create('wrong_hub_boxes', function (Blueprint $t) {
            $t->id();
            $t->foreignId('invoice_id')->index();
            $t->foreignId('tripinvoice_id')->nullable();
            $t->foreignId('logistichub_id')->index();   // where the box is now
            $t->foreignId('correct_hub_id')->nullable(); // where it should go
            $t->foreignId('sea_shipment_id')->nullable();
            $t->string('reason', 20);                    // wrong_hub, refused, moved, wrong_address, other
            $t->string('status', 12)->default('waiting');// waiting, sent_hub, back, done
            $t->string('note', 300)->nullable();
            $t->foreignId('created_by')->nullable();
            $t->foreignId('done_by')->nullable();
            $t->timestamp('done_at')->nullable();
            $t->timestamps();
        });

        Help::installDefaults();
    }

    public function down(): void
    {
        Schema::dropIfExists('wrong_hub_boxes');
        Schema::dropIfExists('sea_shipment_scans');
        Schema::dropIfExists('sea_shipments');
    }
};
