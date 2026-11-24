<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Schema;

/**
 * Board 62: one truck to the port for all the trips of a sea shipment, and LCL with a forwarder.
 * A stop's carrier_trip_id is the trip whose truck carries its boxes: null = the shipment's main truck.
 */
return new class extends Migration
{
    public function up(): void
    {
        if (Schema::hasTable('sea_shipment_stops') && ! Schema::hasColumn('sea_shipment_stops', 'carrier_trip_id')) {
            Schema::table('sea_shipment_stops', function (Blueprint $t) {
                $t->unsignedBigInteger('carrier_trip_id')->nullable()->index();
                $t->unsignedBigInteger('own_truck_id')->nullable();      // the trip's truck before it went with the main truck
                $t->timestamp('arrived_at')->nullable();                  // RoRo: our truck arrived at this hub
                $t->decimal('trucking_cost', 12, 2)->nullable();          // a second truck: its trucking
            });
            // shipments made before: every trip kept its own truck
            DB::table('sea_shipment_stops')->update(['carrier_trip_id' => DB::raw('deliverylog_id')]);
        }
        if (Schema::hasTable('sea_shipments') && ! Schema::hasColumn('sea_shipments', 'forwarder')) {
            Schema::table('sea_shipments', function (Blueprint $t) {
                $t->string('forwarder', 80)->nullable();
                $t->string('waybill_no', 40)->nullable();
                $t->string('charge_basis', 8)->nullable();                // cbm, kg, box
                $t->decimal('charge_rate', 12, 2)->nullable();
                $t->string('hand_over_at', 160)->nullable();              // where our truck hands the boxes to the forwarder
                $t->string('pick_up_at', 160)->nullable();                // where the partner hub picks them up
            });
        }
    }

    public function down(): void
    {
        if (Schema::hasColumn('sea_shipments', 'forwarder')) {
            Schema::table('sea_shipments', fn (Blueprint $t) => $t->dropColumn(['forwarder', 'waybill_no', 'charge_basis', 'charge_rate', 'hand_over_at', 'pick_up_at']));
        }
        if (Schema::hasColumn('sea_shipment_stops', 'carrier_trip_id')) {
            Schema::table('sea_shipment_stops', fn (Blueprint $t) => $t->dropColumn(['carrier_trip_id', 'own_truck_id', 'arrived_at', 'trucking_cost']));
        }
    }
};
