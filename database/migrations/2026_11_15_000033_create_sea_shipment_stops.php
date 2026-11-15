<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Schema;

/**
 * One container, more partner hubs: a sea shipment has a stop for each trip (each hub).
 * The first hub receives its boxes and passes the container on to the next.
 */
return new class extends Migration
{
    public function up(): void
    {
        if (! Schema::hasTable('sea_shipment_stops')) {
            Schema::create('sea_shipment_stops', function (Blueprint $t) {
                $t->id();
                $t->foreignId('sea_shipment_id')->index();
                $t->foreignId('deliverylog_id')->unique();
                $t->foreignId('logistichub_id')->index();
                $t->unsignedTinyInteger('stop')->default(1);
                $t->timestamp('received_at')->nullable();
                $t->foreignId('received_by')->nullable();
                $t->unsignedInteger('missing')->default(0);
                $t->timestamps();
            });
        }
        // Every shipment so far has one stop: its own trip.
        if (Schema::hasTable('sea_shipments')) {
            foreach (DB::table('sea_shipments')->whereNotIn('id', DB::table('sea_shipment_stops')->select('sea_shipment_id'))->get() as $s) {
                $log = collect(json_decode((string) $s->status_log, true) ?: [])->where('status', 'received')->last();
                DB::table('sea_shipment_stops')->insert(['sea_shipment_id' => $s->id, 'deliverylog_id' => $s->deliverylog_id, 'logistichub_id' => $s->logistichub_id, 'stop' => 1,
                    'received_at' => $s->status === 'received' ? ($log['at'] ?? $s->updated_at) : null, 'received_by' => $s->status === 'received' ? ($log['by'] ?? null) : null,
                    'missing' => 0, 'created_at' => now(), 'updated_at' => now()]);
            }
        }
    }

    public function down(): void
    {
        Schema::dropIfExists('sea_shipment_stops');
    }
};
