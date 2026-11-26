<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

/** Part 40: photos on Cloudflare R2 / Amazon S3 (Settings → Photo storage). */
return new class extends Migration
{
    public function up(): void
    {
        if (! Schema::hasTable('storage_buckets')) {
            Schema::create('storage_buckets', function (Blueprint $t) {
                $t->id();
                $t->string('slot', 8)->unique();            // tmp, real
                $t->string('provider', 8)->default('r2');   // r2, s3, other
                $t->string('account_id', 64)->nullable();
                $t->string('endpoint', 255)->nullable();
                $t->string('region', 40)->nullable();
                $t->string('bucket', 80)->nullable();
                $t->string('access_key', 128)->nullable();
                $t->text('secret')->nullable();             // encrypted
                $t->boolean('test_ok')->default(false);
                $t->string('test_message', 255)->nullable();
                $t->timestamp('tested_at')->nullable();
                $t->boolean('is_off')->default(false);
                $t->timestamps();
            });
        }

        // Where each photo is, when it is not on this server. No row = on the server, like before.
        if (! Schema::hasTable('photo_files')) {
            Schema::create('photo_files', function (Blueprint $t) {
                $t->id();
                $t->string('disk', 8);                      // public, box, old
                $t->string('path', 500);
                $t->string('place', 8);                     // server, tmp, real
                $t->unsignedInteger('size')->nullable();
                $t->string('note', 160)->nullable();        // fallback: why it stayed on the server
                $t->timestamps();
                $t->unique(['disk', 'path']);
                $t->index(['place', 'created_at']);
            });
        }

        if (! Schema::hasTable('photo_tasks')) {
            Schema::create('photo_tasks', function (Blueprint $t) {
                $t->id();
                $t->string('kind', 12);                     // move, switch, copy_old
                $t->string('from_place', 8)->nullable();
                $t->string('to_place', 8)->nullable();
                $t->string('status', 10)->default('ready'); // ready, running, paused, checking, done, failed
                $t->json('options')->nullable();
                $t->unsignedInteger('total')->default(0);
                $t->unsignedInteger('done')->default(0);
                $t->unsignedInteger('skipped')->default(0);
                $t->unsignedInteger('failed')->default(0);
                $t->unsignedBigInteger('bytes_before')->default(0);
                $t->unsignedBigInteger('bytes_after')->default(0);
                $t->string('last_error', 255)->nullable();
                $t->foreignId('user_id')->nullable();
                $t->timestamp('started_at')->nullable();
                $t->timestamp('finished_at')->nullable();
                $t->timestamp('checked_at')->nullable();
                $t->timestamps();
            });
        }

        if (! Schema::hasTable('photo_task_items')) {
            Schema::create('photo_task_items', function (Blueprint $t) {
                $t->id();
                $t->foreignId('photo_task_id');
                $t->string('disk', 8)->default('public');
                $t->string('path', 500);                    // the path in the database = the key in the bucket
                $t->string('source', 600)->nullable();      // full path of the file on this server
                $t->string('other', 600)->nullable();       // the second file when both sites have one
                $t->string('found', 8)->nullable();         // wmsv2, wms, both, missing
                $t->string('ref', 120)->nullable();         // table.column #id
                $t->string('status', 8)->default('pending'); // pending, done, skipped, failed, missing
                $t->unsignedInteger('size_before')->nullable();
                $t->unsignedInteger('size_after')->nullable();
                $t->unsignedInteger('src_time')->nullable();
                $t->boolean('tried')->default(false);
                $t->boolean('checked')->default(false);
                $t->string('note', 160)->nullable();
                $t->timestamps();
                $t->index(['photo_task_id', 'status']);
            });
        }
    }

    public function down(): void
    {
        Schema::dropIfExists('photo_task_items');
        Schema::dropIfExists('photo_tasks');
        Schema::dropIfExists('photo_files');
        Schema::dropIfExists('storage_buckets');
    }
};
