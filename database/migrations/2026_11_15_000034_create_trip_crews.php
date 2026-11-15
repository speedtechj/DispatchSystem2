<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Schema;

/**
 * Trip steps (Planned → Loading → Ready → On the road → Back → Closed), the crew of each trip
 * (copied from the truck team, changeable for one trip), and the truck releasing itself.
 */
return new class extends Migration
{
    public function up(): void
    {
        if (! Schema::hasTable('trip_crews')) {
            Schema::create('trip_crews', function (Blueprint $t) {
                $t->id();
                $t->foreignId('deliverylog_id')->index();
                $t->foreignId('user_id')->index();
                $t->string('role')->nullable();
                $t->foreignId('replaces_user_id')->nullable();
                $t->string('reason')->nullable();
                $t->timestamps();
                $t->unique(['deliverylog_id', 'user_id']);
            });
        }
        Schema::table('deliverylogs', function (Blueprint $t) {
            if (! Schema::hasColumn('deliverylogs', 'taken_at')) {
                $t->timestamp('taken_at')->nullable();
                $t->foreignId('taken_by')->nullable();
                $t->unsignedInteger('taken_boxes')->nullable();
                $t->timestamp('back_at')->nullable();
                $t->timestamp('closed_at')->nullable();
                $t->string('release_reason')->nullable();
            }
        });

        // Trips running now keep the crew of their truck.
        $trips = DB::table('deliverylogs')->where('is_active', true)->whereNotNull('truck_id')->get(['id', 'truck_id']);
        foreach ($trips as $trip) {
            foreach (DB::table('truckcrews')->where('truck_id', $trip->truck_id)->pluck('crew')->unique() as $userId) {
                DB::table('trip_crews')->insertOrIgnore(['deliverylog_id' => $trip->id, 'user_id' => $userId, 'created_at' => now(), 'updated_at' => now()]);
            }
        }

        \App\Support\Help\Help::installDefaults();
    }

    public function down(): void
    {
        Schema::dropIfExists('trip_crews');
        Schema::table('deliverylogs', function (Blueprint $t) {
            if (Schema::hasColumn('deliverylogs', 'taken_at')) {
                $t->dropColumn(['taken_at', 'taken_by', 'taken_boxes', 'back_at', 'closed_at', 'release_reason']);
            }
        });
    }
};
