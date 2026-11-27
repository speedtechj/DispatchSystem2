<?php

namespace App\Support\Deliveries;

use App\Jobs\MakeSignedReceipt;
use App\Models\Boxissue;
use App\Models\DeliverySignature;
use App\Models\Invoice;
use App\Models\Invoiceissue;
use App\Models\Tripinvoice;
use App\Models\User;
use App\Support\Photos\Storage\PhotoFolders;
use DomainException;
use Illuminate\Support\Facades\Storage;
use Illuminate\Support\Str;

/**
 * Part 44 (boards 69, 70, 70b): a delivery signed on the driver's phone.
 * Damaged: the receiver signs that they saw the damage, a damage issue is made for the office,
 * and the receiver gets an SMS with the receipt link. No paper receipt: the receiver signs on the phone.
 */
class DeliveryProof
{
    /**
     * @param  array{why: string, paper_reason?: ?string, recipient_name: string, relationship?: ?string, damage?: array, damage_note?: ?string,
     *               cant_sign?: bool, signature?: ?string, lat?: ?float, lng?: ?float}  $d
     */
    public static function record(Tripinvoice $box, User $driver, array $d): DeliverySignature
    {
        $why = $d['why'] === 'damaged' ? 'damaged' : 'no_paper';
        $name = trim(Str::squish((string) ($d['recipient_name'] ?? '')));
        if ($name === '') {
            throw new DomainException('Type the name of the person who received the box.');
        }
        $damage = array_values(array_intersect(array_keys(DeliverySignature::DAMAGE), (array) ($d['damage'] ?? [])));
        if ($why === 'damaged' && $damage === [] && blank($d['damage_note'] ?? null)) {
            throw new DomainException('Tap what is damaged.');
        }
        $cant = (bool) ($d['cant_sign'] ?? false);
        $png = static::png($d['signature'] ?? null);
        if (! $png && ! $cant) {
            throw new DomainException('Ask the receiver to sign.');
        }

        $token = static::token();
        $dir = PhotoFolders::dir('delivery', $box->invoice);
        $path = null;
        if ($png) {
            $path = $dir.'/signature-'.$token.'.png';
            Storage::disk('public')->put($path, $png);
        }

        return DeliverySignature::create([
            'tripinvoice_id' => $box->id,
            'invoice_id' => $box->invoice_id,
            'user_id' => $driver->id,
            'why' => $why,
            'paper_reason' => $why === 'no_paper' && isset(DeliverySignature::PAPER[$d['paper_reason'] ?? '']) ? $d['paper_reason'] : null,
            'recipient_name' => Str::limit($name, 117, ''),
            'relationship' => in_array($d['relationship'] ?? null, DeliverySignature::RELATIONSHIP, true) ? $d['relationship'] : null,
            'damage' => $why === 'damaged' ? $damage : null,
            'damage_note' => $why === 'damaged' && filled($d['damage_note'] ?? null) ? Str::limit(trim($d['damage_note']), 290, '') : null,
            'cant_sign' => $cant && ! $png,
            'signature' => $path,
            'token' => $token,
            'lat' => is_numeric($d['lat'] ?? null) ? $d['lat'] : null,
            'lng' => is_numeric($d['lng'] ?? null) ? $d['lng'] : null,
            'signed_at' => now(),
        ]);
    }

    /** After the box is marked delivered: the damage issue, then the receipt (and the SMS) in the background. */
    public static function after(DeliverySignature $s): void
    {
        if ($s->isDamaged() && ! $s->invoiceissue_id) {
            $box = $s->tripinvoice;
            $type = Boxissue::firstOrCreate(['issue_type' => 'Damaged on delivery']);
            $issue = Invoiceissue::create([
                'invoice' => $box?->invoice, 'invoice_id' => $s->invoice_id, 'container_id' => Invoice::whereKey($s->invoice_id)->value('container_id'),
                'boxissue_id' => $type->id, 'user_id' => $s->user_id,
                'remarks' => 'Delivered damaged: '.$s->damageText().'. Received by '.$s->recipient_name.($s->relationship ? ' ('.strtolower($s->relationship).')' : '').', who saw the damage and signed.',
                'attachment_pic' => array_values((array) ($box?->delivery_picture ?? [])),
            ]);
            $s->update(['invoiceissue_id' => $issue->id]);
        }
        MakeSignedReceipt::dispatch($s->id)->afterCommit();
    }

    /** The PNG from the signature pad ("data:image/png;base64,…"), at most 300 KB. */
    public static function png(?string $dataUrl): ?string
    {
        if (! $dataUrl || ! preg_match('~^data:image/png;base64,([A-Za-z0-9+/=\s]+)$~', $dataUrl, $m)) {
            return null;
        }
        $bin = base64_decode($m[1], true);

        return $bin !== false && strlen($bin) > 60 && strlen($bin) <= 300 * 1024 && str_starts_with($bin, "\x89PNG") ? $bin : null;
    }

    protected static function token(): string
    {
        do {
            $t = Str::lower(Str::random(10));
        } while (DeliverySignature::where('token', $t)->exists());

        return $t;
    }
}
