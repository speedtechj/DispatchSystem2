<?php

namespace App\Support\Ai;

use App\Models\DeliverySignature;
use App\Models\Invoice;
use App\Support\Branding;
use Illuminate\Support\Collection;
use Illuminate\Support\Facades\Schema;

/**
 * Part 45 (board 73): the AI helper of Box issues, for the Box Photos email: writes the email to the consolidator
 * from the facts of the boxes in the photos, in the language picked. Only the facts given, never made up.
 */
class BoxEmailWriter
{
    /**
     * @param  Collection  $items  photo items from BoxAlbum (invoice, label, condition, at, who, note, kind)
     * @return array{subject: string, body: string}
     */
    public static function draft(Collection $items, string $lang = 'en', bool $withEnglish = false): array
    {
        $company = Branding::companyName();
        $boxes = Invoice::with('container.consolidator', 'consolidator')->whereIn('invoice', $items->pluck('invoice')->filter()->unique())->get();
        $facts = $boxes->take(10)->map(function (Invoice $b) use ($items) {
            $mine = $items->where('invoice', $b->invoice);
            $sig = Schema::hasTable('delivery_signatures')
                ? DeliverySignature::where('invoice_id', $b->id)->latest('id')->first() : null;

            return [
                'box' => $b->invoice,
                'container' => $b->container?->container_no,
                'consolidator' => ($b->consolidator ?? $b->container?->consolidator)?->company_name,
                'receiver' => $b->receiver_name,
                'receiver_place' => trim($b->receiver_barangay.', '.$b->receiver_city, ', '),
                'delivered' => (bool) $b->is_delivered,
                'signed_on_delivery' => $sig ? array_filter([
                    'by' => $sig->recipient_name, 'relationship' => $sig->relationship,
                    'damaged' => $sig->isDamaged() ? $sig->damageText() : null,
                    'why_signed_on_phone' => $sig->isDamaged() ? 'box handed over damaged' : 'no paper receipt',
                    'signed_at' => $sig->signed_at?->format('M j, Y g:i A'),
                ]) : null,
                'photos_attached' => $mine->map(fn ($i) => trim($i['label'].($i['condition'] && $i['condition'] !== 'good' ? ' ('.$i['condition'].')' : '').' on '.$i['at']?->format('M j').($i['note'] ? ' · note: '.$i['note'] : '')))->values()->all(),
            ];
        })->values()->all();

        $out = Ai::json('issues',
            "You help the office staff of {$company}, a cargo company delivering balikbayan boxes in the Philippines for consolidators abroad. "
            .'From the facts, write a short, polite email to the consolidator that goes with the attached photos: greeting, which box(es) and container, '
            .'what the photos show (delivered, damaged, not delivered, at the warehouse), what we did, anything we need from them, thanks, sign as '.$company.'. '
            .EmailLanguages::instruction($lang, $withEnglish).' Only use the facts given. '
            .'Return {"subject": a short subject in the same language, "body": the email}.',
            json_encode(['boxes' => $facts, 'photo_count' => $items->count()], JSON_UNESCAPED_UNICODE), 'smart', $withEnglish ? 1400 : 900);

        return [
            'subject' => mb_substr((string) ($out['subject'] ?? ''), 0, 200),
            'body' => (string) ($out['body'] ?? ''),
        ];
    }
}
