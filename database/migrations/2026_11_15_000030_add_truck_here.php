<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

/** Transfer trip: "The truck is here now" — boxes for its warehouse go straight onto it while containers are unloaded. */
return new class extends Migration
{
    public function up(): void
    {
        Schema::table('whdeliverylogs', function (Blueprint $t) {
            if (! Schema::hasColumn('whdeliverylogs', 'truck_here')) {
                $t->boolean('truck_here')->default(false);
                $t->timestamp('truck_here_at')->nullable();
                $t->unsignedBigInteger('truck_here_by')->nullable();
            }
        });

        // The help guide still says to tap "A truck is waiting" in the Scan app: use the new steps (only if not edited).
        if (Schema::hasTable('help_guides')) {
            $guide = \App\Models\Help\HelpGuide::where('slug', 'warehouse-sections')->first();
            $new = collect(\App\Support\Help\DefaultGuides::all())->firstWhere('slug', 'warehouse-sections');
            if ($guide && $new && str_contains(json_encode($guide->steps), 'Tap \\"A truck is waiting\\"')) {
                $guide->forceFill(['steps' => $new['steps']])->save();
                \App\Support\Help\Help::forget();
            }
        }
    }

    public function down(): void
    {
        Schema::table('whdeliverylogs', function (Blueprint $t) {
            if (Schema::hasColumn('whdeliverylogs', 'truck_here')) {
                $t->dropColumn(['truck_here', 'truck_here_at', 'truck_here_by']);
            }
        });
    }
};
