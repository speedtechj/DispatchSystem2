<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

/**
 * Part 44: a box handed over damaged, or with no paper receipt, is signed on the driver's phone.
 * The signed receipt is the same receipt you print (only its blank lines filled in).
 * Can't deliver: the next try is set by the reason; after 3 tries the office decides.
 */
return new class extends Migration
{
    public function up(): void
    {
        if (! Schema::hasTable('delivery_signatures')) {
            Schema::create('delivery_signatures', function (Blueprint $t) {
                $t->id();
                $t->unsignedBigInteger('tripinvoice_id')->index();
                $t->unsignedBigInteger('invoice_id')->nullable()->index();
                $t->unsignedBigInteger('user_id')->nullable();        // the driver
                $t->string('why', 20);                               // damaged | no_paper
                $t->string('paper_reason', 40)->nullable();          // wet_torn | left_at_hub | no_more
                $t->string('recipient_name', 120);
                $t->string('relationship', 40)->nullable();
                $t->json('damage')->nullable();                      // ['torn', 'crushed', …]
                $t->string('damage_note', 300)->nullable();
                $t->boolean('cant_sign')->default(false);
                $t->string('signature', 500)->nullable();            // PNG on the public disk
                $t->string('receipt_pdf', 500)->nullable();
                $t->string('receipt_jpg', 500)->nullable();          // also in the delivery photos
                $t->string('token', 16)->unique();                   // /r/{token}: the link in the SMS
                $t->decimal('lat', 10, 7)->nullable();
                $t->decimal('lng', 10, 7)->nullable();
                $t->unsignedBigInteger('invoiceissue_id')->nullable();
                $t->unsignedBigInteger('sms_message_id')->nullable();
                $t->timestamp('signed_at')->nullable();
                $t->timestamps();
            });
        }
        if (Schema::hasTable('delivery_attempts') && ! Schema::hasColumn('delivery_attempts', 'next_try_on')) {
            Schema::table('delivery_attempts', function (Blueprint $t) {
                $t->date('next_try_on')->nullable();                 // when to try again (null: the office decides)
                $t->boolean('needs_office')->default(false);
                $t->timestamp('handled_at')->nullable();             // the office set a new date or closed it
                $t->unsignedBigInteger('handled_by')->nullable();
            });
        }
    }

    public function down(): void
    {
        Schema::dropIfExists('delivery_signatures');
        if (Schema::hasColumn('delivery_attempts', 'next_try_on')) {
            Schema::table('delivery_attempts', fn (Blueprint $t) => $t->dropColumn(['next_try_on', 'needs_office', 'handled_at', 'handled_by']));
        }
    }
};
