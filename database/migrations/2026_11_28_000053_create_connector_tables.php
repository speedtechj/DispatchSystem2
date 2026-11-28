<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

/**
 * Part 47: Dispatch System sends box statuses to each consolidator's connector.
 *
 *  connector_links     one per consolidator: address, push or pull, the pairing (token and secret encrypted)
 *  connector_mappings  our event (code or code@place) → their status id, per consolidator
 *  connector_events    the Outbox: every status we send, with its hold, tries and the connector's answer
 */
return new class extends Migration
{
    public function up(): void
    {
        if (! Schema::hasTable('connector_links')) {
            Schema::create('connector_links', function (Blueprint $t) {
                $t->id();
                $t->foreignId('consolidator_id')->unique();
                $t->string('url', 250)->nullable();              // push: the connector's HTTPS address
                $t->string('mode', 8)->default('push');           // push | pull
                $t->text('token')->nullable();                    // encrypted
                $t->text('secret')->nullable();                   // encrypted
                $t->string('key_id', 64)->nullable()->index();    // pull: the connector signs with this key id
                $t->string('state', 12)->default('setup');        // setup | online | offline | paused | off
                $t->string('connector_name', 150)->nullable();
                $t->string('version', 20)->nullable();
                $t->string('location_code', 20)->nullable();      // what the connector says it is
                $t->json('health')->nullable();                   // last /health answer
                $t->json('statuses')->nullable();                 // their status list (branch PH, active)
                $t->timestamp('statuses_at')->nullable();
                $t->timestamp('last_seen_at')->nullable();
                $t->timestamp('last_results_at')->nullable();     // /results?since=
                $t->string('last_error', 300)->nullable();
                $t->unsignedSmallInteger('fails')->default(0);     // failed tries in a row
                $t->timestamp('paused_at')->nullable();
                $t->timestamp('next_try_at')->nullable();
                $t->timestamp('mailed_at')->nullable();
                $t->timestamp('paired_at')->nullable();
                $t->foreignId('paired_by')->nullable();
                $t->unsignedBigInteger('pull_cursor')->default(0);
                $t->timestamps();
            });
        }

        if (! Schema::hasTable('connector_mappings')) {
            Schema::create('connector_mappings', function (Blueprint $t) {
                $t->id();
                $t->foreignId('connector_link_id');
                $t->string('key', 140);                          // ds.transfer@tarlac
                $t->unsignedBigInteger('trackstatus_id')->nullable();
                $t->string('status_name', 191)->nullable();
                $t->boolean('skip')->default(false);              // Don't send this one
                $t->timestamps();
                $t->unique(['connector_link_id', 'key']);
            });
        }

        if (! Schema::hasTable('connector_events')) {
            Schema::create('connector_events', function (Blueprint $t) {
                $t->id();
                $t->string('uid', 40)->unique();                  // the event id the connector sees
                $t->foreignId('connector_link_id');
                $t->foreignId('invoice_id')->nullable()->index();
                $t->string('invoice', 40);
                $t->string('code', 80);
                $t->string('place', 60)->nullable();
                $t->string('label', 150)->nullable();
                $t->json('payload');                              // the event as it is sent
                $t->string('state', 16)->default('hold')->index();
                // hold | trip (waits for the trip to leave) | ready | sent | saved | skipped | refused
                // | needs_mapping | not_found | failed | busy | retry | cancelled
                $t->unsignedTinyInteger('priority')->default(5);  // 1 = first (delivered, undo)
                $t->timestamp('send_after')->nullable();
                $t->unsignedSmallInteger('tries')->default(0);
                $t->timestamp('next_try_at')->nullable();
                $t->timestamp('sent_at')->nullable();
                $t->unsignedInteger('took_ms')->nullable();
                $t->string('message', 250)->nullable();
                $t->unsignedBigInteger('trackstatus_id')->nullable();
                $t->unsignedBigInteger('row_id')->nullable();
                $t->string('source', 40)->nullable()->index();    // tripinvoice:12, invoice:5, manual, backfill
                $t->string('corrects', 40)->nullable()->index();  // uid of the event this one undoes
                $t->string('undone_by', 40)->nullable();
                $t->foreignId('user_id')->nullable();             // who did it in Dispatch System
                $t->boolean('manual')->default(false);
                $t->timestamp('happened_at');
                $t->timestamps();
                $t->index(['connector_link_id', 'state', 'priority', 'id']);
                $t->index(['connector_link_id', 'created_at']);
            });
        }
    }

    public function down(): void
    {
        Schema::dropIfExists('connector_events');
        Schema::dropIfExists('connector_mappings');
        Schema::dropIfExists('connector_links');
    }
};
