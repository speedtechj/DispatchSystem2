<?php

use App\Support\Help\Help;
use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

/** Fuel: fills from the Driver app, fuel cash per trip, fuel card statements. */
return new class extends Migration
{
    public function up(): void
    {
        Schema::table('trucks', function (Blueprint $table) {
            if (! Schema::hasColumn('trucks', 'fuel_type')) {
                $table->string('fuel_type', 10)->nullable();          // diesel / gasoline
            }
            if (! Schema::hasColumn('trucks', 'tank_liters')) {
                $table->unsignedSmallInteger('tank_liters')->nullable();
            }
            if (! Schema::hasColumn('trucks', 'fuel_card_last4')) {
                $table->string('fuel_card_last4', 8)->nullable();
            }
        });

        if (! Schema::hasTable('fuel_fills')) {
            Schema::create('fuel_fills', function (Blueprint $table) {
                $table->id();
                $table->foreignId('truck_id')->index();
                $table->foreignId('deliverylog_id')->nullable()->index();
                $table->foreignId('driver_id')->nullable();
                $table->foreignId('logistichub_id')->nullable()->index();
                $table->timestamp('filled_at')->index();
                $table->string('station', 120)->nullable();
                $table->string('product', 80)->nullable();
                $table->string('fuel_type', 10)->nullable();
                $table->decimal('liters', 8, 2);
                $table->decimal('price_per_liter', 8, 2)->nullable();
                $table->decimal('total', 10, 2);
                $table->decimal('vatable', 10, 2)->nullable();
                $table->decimal('vat', 10, 2)->nullable();
                $table->string('station_tin', 30)->nullable();
                $table->string('invoice_no', 40)->nullable();
                $table->boolean('buyer_tin_ok')->nullable();
                $table->string('paid_with', 8)->default('card');      // card / cash
                $table->string('card_last4', 8)->nullable();
                $table->unsignedInteger('odometer')->nullable();
                $table->unsignedInteger('km_since')->nullable();
                $table->decimal('km_per_liter', 6, 2)->nullable();
                $table->string('receipt_path')->nullable();
                $table->string('odometer_path')->nullable();
                $table->decimal('lat', 10, 7)->nullable();
                $table->decimal('lng', 10, 7)->nullable();
                $table->boolean('gps_ok')->nullable();
                $table->unsignedInteger('gps_distance_m')->nullable();
                $table->boolean('ai_read')->default(false);
                $table->json('ai_data')->nullable();
                $table->timestamps();
            });
        }

        if (! Schema::hasTable('fuel_cash')) {
            Schema::create('fuel_cash', function (Blueprint $table) {
                $table->id();
                $table->foreignId('deliverylog_id')->unique();
                $table->foreignId('truck_id')->nullable();
                $table->foreignId('driver_id')->nullable();
                $table->decimal('km', 8, 1)->nullable();
                $table->decimal('km_per_liter', 6, 2)->nullable();
                $table->decimal('price', 8, 2)->nullable();
                $table->unsignedTinyInteger('buffer_pct')->default(10);
                $table->decimal('estimate', 10, 2)->nullable();
                $table->decimal('given', 10, 2);
                $table->timestamp('given_at');
                $table->foreignId('given_by')->nullable();
                $table->decimal('returned', 10, 2)->nullable();
                $table->timestamp('settled_at')->nullable();
                $table->foreignId('settled_by')->nullable();
                $table->string('note')->nullable();
                $table->timestamps();
            });
        }

        if (! Schema::hasTable('fuel_statements')) {
            Schema::create('fuel_statements', function (Blueprint $table) {
                $table->id();
                $table->string('provider', 20);
                $table->string('filename');
                $table->foreignId('logistichub_id')->nullable();
                $table->date('from')->nullable();
                $table->date('to')->nullable();
                $table->unsignedInteger('lines')->default(0);
                $table->foreignId('uploaded_by')->nullable();
                $table->timestamps();
            });
        }

        if (! Schema::hasTable('fuel_statement_lines')) {
            Schema::create('fuel_statement_lines', function (Blueprint $table) {
                $table->id();
                $table->foreignId('fuel_statement_id')->index();
                $table->foreignId('truck_id')->nullable()->index();
                $table->foreignId('fuel_fill_id')->nullable()->index();
                $table->timestamp('charged_at')->nullable();
                $table->string('card', 30)->nullable();
                $table->string('plate', 20)->nullable();
                $table->string('station', 120)->nullable();
                $table->string('product', 80)->nullable();
                $table->string('fuel_type', 10)->nullable();
                $table->decimal('liters', 8, 2)->nullable();
                $table->decimal('amount', 10, 2)->nullable();
                $table->unsignedInteger('odometer')->nullable();
                $table->string('status', 16)->index();                // matched / liters_differ / no_fill / no_truck
                $table->timestamps();
            });
        }

        Help::installDefaults();
    }

    public function down(): void
    {
        Schema::dropIfExists('fuel_statement_lines');
        Schema::dropIfExists('fuel_statements');
        Schema::dropIfExists('fuel_cash');
        Schema::dropIfExists('fuel_fills');
        Schema::table('trucks', function (Blueprint $table) {
            foreach (['fuel_type', 'tank_liters', 'fuel_card_last4'] as $c) {
                if (Schema::hasColumn('trucks', $c)) {
                    $table->dropColumn($c);
                }
            }
        });
    }
};
