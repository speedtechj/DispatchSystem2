<?php

namespace App\Mail;

use Illuminate\Bus\Queueable;
use Illuminate\Mail\Mailable;
use Illuminate\Mail\Mailables\Content;
use Illuminate\Mail\Mailables\Envelope;

class AgingSummaryMail extends Mailable
{
    use Queueable;

    public function __construct(public array $sum, public array $advice, public string $url, public ?string $name = null) {}

    public function envelope(): Envelope
    {
        return new Envelope(subject: 'Morning summary · '.now()->format('D M j').' · '.$this->sum['late'].' late '.str('box')->plural($this->sum['late']));
    }

    public function content(): Content
    {
        return new Content(view: 'mail.aging-summary');
    }
}
