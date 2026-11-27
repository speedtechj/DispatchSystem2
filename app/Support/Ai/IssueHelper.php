<?php

namespace App\Support\Ai;

use App\Models\BoxPhoto;
use App\Models\DeliveryAttempt;
use App\Models\Invoice;
use App\Models\Invoiceissue;
use App\Support\Branding;

/** Issue helper: sums up an Invoice Issue, suggests the next step and drafts the email to the consolidator. */
class IssueHelper
{
    /** @return array{summary: string, next: string, subject: string, body: string, to: ?string, photos: list<int>} */
    public static function draft(Invoiceissue $issue, string $lang = 'en', bool $withEnglish = false): array
    {
        $invoice = $issue->invoice_id ? Invoice::with('container.consolidator')->find($issue->invoice_id) : Invoice::with('container.consolidator')->where('invoice', $issue->invoice)->first();
        $container = $invoice?->container;
        $consolidator = $container?->consolidator;
        $photos = $invoice ? BoxPhoto::where('invoice_id', $invoice->id)->orderBy('taken_at')->get() : collect();
        $attempts = $invoice ? DeliveryAttempt::where('invoice_id', $invoice->id)->get() : collect();
        $company = Branding::companyName();

        $facts = [
            'issue_type' => $issue->boxissue?->issue_type,
            'remarks' => $issue->remarks,
            'opened' => $issue->created_at?->format('M j, Y'),
            'box' => $issue->invoice,
            'container' => $container?->container_no,
            'consolidator' => $consolidator?->company_name,
            'receiver' => $invoice?->receiver_name,
            'receiver_place' => $invoice ? trim($invoice->receiver_barangay.', '.$invoice->receiver_city, ', ') : null,
            'sender' => $invoice?->sender_name,
            'delivered' => (bool) $invoice?->is_delivered,
            'photos' => $photos->map(fn ($p) => ($p->condition ?: 'good').' at '.($p->step).' on '.$p->taken_at?->format('M j'))->all(),
            'failed_attempts' => $attempts->map(fn ($a) => $a->reason?->getLabel().($a->note ? ': '.$a->note : ''))->all(),
        ];

        $out = Ai::json('issues',
            "You help the claims staff of {$company}, a cargo company delivering balikbayan boxes in the Philippines for consolidators abroad. "
            .'From the facts, return {"summary": one or two plain sentences, "next": the practical next step in one sentence, '
            .'"subject": a short email subject, "body": a polite, short email to the consolidator (greeting, what happened with box number and container, '
            .'what we did, what we need from them, thanks, sign as '.$company.')}. Mention attached photos only if there are photos. Only use the facts given. '
            .'"summary" and "next" stay in English; the subject and the email: '.EmailLanguages::instruction($lang, $withEnglish),
            json_encode($facts, JSON_UNESCAPED_UNICODE), 'smart', $withEnglish ? 1400 : 900);

        return [
            'summary' => (string) ($out['summary'] ?? ''),
            'next' => (string) ($out['next'] ?? ''),
            'subject' => (string) ($out['subject'] ?? "Box {$issue->invoice}"),
            'body' => (string) ($out['body'] ?? ''),
            'to' => $consolidator?->email,
            'photos' => $photos->pluck('id')->all(),
            'consolidator_id' => $consolidator?->id,
        ];
    }
}
