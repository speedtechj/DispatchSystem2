<?php

use App\Enums\FailedDeliveryReason;
use App\Filament\Delivery\Pages\Dashboard;
use App\Filament\Pages\Redelivery;
use App\Http\Controllers\InvoiceController;
use App\Models\DeliveryAttempt;
use App\Models\DeliverySignature;
use App\Models\Deliverylog;
use App\Models\Invoice;
use App\Models\Invoiceissue;
use App\Models\Sms\SmsMessage;
use App\Models\Tripinvoice;
use App\Models\User;
use App\Services\TripAssignment;
use App\Support\Deliveries\NextTry;
use App\Support\Deliveries\SignedReceipt;
use App\Support\Sms\SmsSettings;
use Carbon\Carbon;
use Database\Seeders\DemoSeeder;
use Filament\Facades\Filament;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Illuminate\Http\Client\Request;
use Illuminate\Http\UploadedFile;
use Illuminate\Support\Facades\Http;
use Illuminate\Support\Facades\Storage;
use Livewire\Livewire;

uses(RefreshDatabase::class);

beforeEach(function () {
    $this->seed(DemoSeeder::class);
    Storage::fake('public');
    SignedReceipt::$fake = true;
    $this->driver = User::where('email', 'driver@example.com')->firstOrFail();
    $this->trip = Deliverylog::firstOrFail();
    $this->box = Tripinvoice::where('deliverylog_id', $this->trip->id)->where('is_delivered', false)->firstOrFail();
    Invoice::whereKey($this->box->invoice_id)->update(['receiver_mobile_no' => '0917 123 4567', 'receiver_name' => 'juan dela cruz']);
    $img = imagecreatetruecolor(120, 40);
    imageline($img, 5, 30, 110, 8, imagecolorallocate($img, 255, 255, 255));
    ob_start();
    imagepng($img);
    $this->sig = 'data:image/png;base64,'.base64_encode(ob_get_clean());
});

afterEach(fn () => SignedReceipt::$fake = false);

function driverPage()
{
    Filament::setCurrentPanel(Filament::getPanel('delivery'));
    test()->actingAs(test()->driver);

    return Livewire::test(Dashboard::class)->call('scan', test()->box->invoice)->call('startDeliver');
}

function photo(string $n = 'p.jpg')
{
    return UploadedFile::fake()->image($n, 800, 600);
}

it('hands over a damaged box: 2 photos, what is damaged, the receiver signs, office and receiver told', function () {
    SmsSettings::putKey('semaphore', 'sema-key');
    Http::fake(fn (Request $r) => Http::response([['message_id' => 1, 'status' => 'Pending']]));

    $page = driverPage()
        ->assertSet('signName', 'Juan Dela Cruz')->assertSee('Box condition')->assertSee('📄 Paper receipt')
        ->call('setCondition', 'damaged')->assertSet('receipt', 'phone')
        ->assertSee('Damaged: 2 photos needed')->assertSee('Damaged: the receiver signs on this phone')
        ->set('upload', photo())->call('savePhoto')
        ->assertSee('Take 2 photos');

    // one photo is not enough
    $page->call('confirmDelivered');
    expect($this->box->fresh()->is_delivered)->toBeFalse();

    $page->set('upload', photo('b.jpg'))->call('savePhoto')
        ->call('toggleDamage', 'torn')->call('toggleDamage', 'crushed')
        ->set('signName', 'Maria Dela Cruz')->set('signRel', 'Sibling')
        ->assertSee('Ask the receiver to sign')
        ->set('signature', $this->sig)
        ->assertSee('Delivered · damaged · signed · 2 photos')
        ->call('confirmDelivered')
        ->assertSee('📄 Show the receipt to the receiver');

    $box = $this->box->fresh();
    $s = DeliverySignature::firstOrFail();
    expect($box->is_delivered)->toBeTrue()
        ->and($s->why)->toBe('damaged')->and($s->recipient_name)->toBe('Maria Dela Cruz')->and($s->relationship)->toBe('Sibling')
        ->and($s->damage)->toBe(['torn', 'crushed'])->and($s->damageText())->toBe('Torn, Crushed')
        ->and(Storage::disk('public')->exists($s->signature))->toBeTrue()
        ->and($s->receipt_pdf)->toEndWith('.pdf')->and($s->receipt_jpg)->toEndWith('.jpg')
        ->and($box->delivery_picture)->toHaveCount(3)->and(collect($box->delivery_picture)->last())->toBe($s->receipt_jpg);

    $issue = Invoiceissue::findOrFail($s->invoiceissue_id);
    expect($issue->boxissue->issue_type)->toBe('Damaged on delivery')->and($issue->remarks)->toContain('Torn, Crushed')->toContain('Maria Dela Cruz');

    $sms = SmsMessage::where('kind', 'delivered_damaged')->firstOrFail();
    expect($sms->message)->toContain('Maria Dela Cruz')->toContain('torn, crushed')->toContain('/r/'.$s->token)
        ->and($s->fresh()->sms_message_id)->toBe($sms->id);
});

it('lets a receiver who cannot sign be written on the receipt', function () {
    driverPage()->call('setCondition', 'damaged')
        ->set('upload', photo())->call('savePhoto')->set('upload', photo('b.jpg'))->call('savePhoto')
        ->call('toggleDamage', 'wet')->set('cantSign', true)->call('confirmDelivered');

    expect(DeliverySignature::firstOrFail())->cant_sign->toBeTrue()->signature->toBeNull()
        ->and(SignedReceipt::html(DeliverySignature::first()))->toContain('The receiver could not sign.');
});

it('signs on the phone when there is no paper receipt, without a damage issue or text', function () {
    $page = driverPage()->set('upload', photo())->call('savePhoto')
        ->call('setReceipt', 'phone')->assertSee('Why no paper?')->assertSee('Left at the hub')
        ->set('signature', $this->sig)->assertSee('Tap why there is no paper');
    $page->call('confirmDelivered');
    expect($this->box->fresh()->is_delivered)->toBeFalse();

    $page->set('paperWhy', 'left_at_hub')->call('confirmDelivered');
    $s = DeliverySignature::firstOrFail();
    expect($this->box->fresh()->is_delivered)->toBeTrue()->and($s->why)->toBe('no_paper')->and($s->paper_reason)->toBe('left_at_hub')
        ->and($s->invoiceissue_id)->toBeNull()->and(SmsMessage::where('kind', 'delivered_damaged')->exists())->toBeFalse();
});

it('keeps the normal delivery with the paper receipt as it is', function () {
    driverPage()->set('upload', photo())->call('savePhoto')->assertSee('The receiver signs your paper receipt, like today.')
        ->assertSee('Delivered · 1 photo')->call('confirmDelivered');

    expect($this->box->fresh()->is_delivered)->toBeTrue()->and(DeliverySignature::count())->toBe(0);
});

it('fills only the blank lines of your own receipt', function () {
    $inv = Invoice::findOrFail($this->box->invoice_id);
    $plain = view('invoices.pdfinvoice', InvoiceController::receiptData($inv))->render();
    expect($plain)->not->toContain('checked')->not->toContain('data:image/png');

    driverPage()->call('setCondition', 'damaged')
        ->set('upload', photo())->call('savePhoto')->set('upload', photo('b.jpg'))->call('savePhoto')
        ->call('toggleDamage', 'torn')->set('signName', 'Maria Dela Cruz')->set('signRel', 'Sibling')->set('signature', $this->sig)
        ->call('confirmDelivered');
    $html = SignedReceipt::html(DeliverySignature::firstOrFail());

    // the same template: same text, only the blanks filled
    expect($html)->toContain('Acknowledgement Receipt')->toContain('STATUS OF THE BOX UPON DELIVERY')
        ->toContain('Maria Dela Cruz')->toContain('Sibling')->toContain('Damaged: Torn. The receiver saw the damage before signing.')
        ->toContain('data:image/png;base64,')->toContain(now()->format('M j, Y'))
        ->and(preg_match_all('/name="sixside"\s+checked/', $html))->toBe(2)
        ->and(preg_match_all('/name="good"\s+checked/', $html))->toBe(0);
});

it('opens the signed receipt from the SMS link', function () {
    driverPage()->set('upload', photo())->call('savePhoto')->call('setReceipt', 'phone')->set('paperWhy', 'no_more')
        ->set('signature', $this->sig)->call('confirmDelivered');
    $s = DeliverySignature::firstOrFail();
    auth()->logout();

    $this->get('/r/'.$s->token)->assertOk()->assertHeader('Content-Type', 'application/pdf');
    $this->get('/r/abcdefghij')->assertNotFound();
});

it('sets the next try from the reason, and the office takes over after 3 tries', function () {
    Carbon::setTestNow(Carbon::parse('2026-11-28 10:00')); // a Saturday: the next working day is Monday
    $t = app(TripAssignment::class);

    $a = $t->recordFailedAttempt($this->box, $this->driver, FailedDeliveryReason::NoOneHome, null, ['gate.jpg']);
    expect($a->next_try_on)->toStartWith('2026-11-30')->and($a->needs_office)->toBeFalse();

    $b = $t->recordFailedAttempt($this->box, $this->driver, FailedDeliveryReason::Rescheduled, 'Wednesday please', [], '2026-12-02');
    expect($b->next_try_on)->toStartWith('2026-12-02');

    $c = $t->recordFailedAttempt($this->box, $this->driver, FailedDeliveryReason::NoOneHome, null, ['gate.jpg']);
    expect($c->needs_office)->toBeTrue()->and($c->next_try_on)->toBeNull();

    expect(NextTry::plan(FailedDeliveryReason::Refused, 1)['office'])->toBeTrue()
        ->and(NextTry::plan(FailedDeliveryReason::AreaInaccessible, 1)['on']->toDateString())->toBe('2026-12-01');
    Carbon::setTestNow();
});

it('shows the next try when the driver cannot deliver, and the 2nd try after', function () {
    Filament::setCurrentPanel(Filament::getPanel('delivery'));
    $this->actingAs($this->driver);

    Livewire::test(Dashboard::class)->call('scan', $this->box->invoice)->call('startMiss')
        ->assertSee('Next try: '.NextTry::workday()->format('D M j'))
        ->set('reason', FailedDeliveryReason::Rescheduled->value)->assertSee('Which day did they ask for?')
        ->set('nextOn', NextTry::workday(null, 3)->toDateString())->assertSee('Next try: '.NextTry::workday(null, 3)->format('D M j'))
        ->set('note', 'Asked for later')
        ->call('saveMissed')
        ->call('scan', $this->box->invoice)->assertSee('2nd try')->assertSee('Last time')->assertSee('Asked for another day');

    expect(DeliveryAttempt::first()->next_try_on)->toStartWith(NextTry::workday(null, 3)->toDateString());
});

it('lists the boxes to try again for the office', function () {
    $admin = User::where('email', 'admin@example.com')->firstOrFail();
    $admin->assignRole('super_admin');
    $t = app(TripAssignment::class);
    $a = $t->recordFailedAttempt($this->box, $this->driver, FailedDeliveryReason::NoOneHome, null, ['gate.jpg']);
    $a->update(['next_try_on' => today()->toDateString()]);
    $other = Tripinvoice::where('deliverylog_id', $this->trip->id)->where('is_delivered', false)->where('id', '!=', $this->box->id)->firstOrFail();
    $b = $t->recordFailedAttempt($other, $this->driver, FailedDeliveryReason::AddressNotFound, 'No such street', ['street.jpg']);

    Filament::setCurrentPanel(Filament::getPanel('admin'));
    $this->actingAs($admin);
    $page = Livewire::test(Redelivery::class)
        ->assertSee('Due today')->assertSee('Needs office')->assertSee($this->box->invoice)->assertDontSee($other->invoice)
        ->call('setTab', 'office')->assertSee($other->invoice)->assertSee('Office decides');

    $page->call('setDay', $b->id, NextTry::workday()->toDateString());
    expect($b->fresh()->needs_office)->toBeFalse()->and($b->fresh()->next_try_on)->toStartWith(NextTry::workday()->toDateString());

    $page->call('close', $a->id);
    expect($a->fresh()->handled_at)->not->toBeNull()
        ->and(NextTry::open()->pluck('id')->all())->toBe([$b->id]);
});
