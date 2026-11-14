<?php

use App\Support\Help\Help;
use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

/** Help guide: step-by-step guides in English and Tagalog, for every panel and phone app. */
return new class extends Migration
{
    public function up(): void
    {
        if (! Schema::hasTable('help_guides')) {
            Schema::create('help_guides', function (Blueprint $table) {
                $table->id();
                $table->string('slug', 80)->unique();
                /** admin, warehouse, company, scan, driver */
                $table->json('apps');
                $table->string('topic', 24)->index();
                $table->string('icon', 16)->nullable();
                $table->string('title_en');
                $table->string('title_tl')->nullable();
                $table->text('summary_en')->nullable();
                $table->text('summary_tl')->nullable();
                $table->text('when_en')->nullable();
                $table->text('when_tl')->nullable();
                /** [{title_en, title_tl, text_en, text_tl, image}] */
                $table->json('steps')->nullable();
                $table->text('result_en')->nullable();
                $table->text('result_tl')->nullable();
                /** [{q_en, q_tl, a_en, a_tl}] */
                $table->json('problems')->nullable();
                /** route names without the panel part, where the "?" opens this guide */
                $table->json('pages')->nullable();
                /** app => route name for "Do it now" */
                $table->json('links')->nullable();
                $table->json('related')->nullable();
                $table->unsignedInteger('helpful_yes')->default(0);
                $table->unsignedInteger('helpful_no')->default(0);
                $table->unsignedInteger('views')->default(0);
                $table->integer('sort')->default(100);
                $table->boolean('is_published')->default(true);
                $table->foreignId('updated_by')->nullable();
                $table->timestamps();
            });
        }

        Help::installDefaults();
    }

    public function down(): void
    {
        Schema::dropIfExists('help_guides');
    }
};
