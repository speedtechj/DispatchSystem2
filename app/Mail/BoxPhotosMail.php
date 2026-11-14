<?php

namespace App\Mail;

use Illuminate\Bus\Queueable;
use Illuminate\Mail\Attachment;
use Illuminate\Mail\Mailable;
use Illuminate\Mail\Mailables\Content;
use Illuminate\Mail\Mailables\Envelope;
use Illuminate\Queue\SerializesModels;
use Illuminate\Support\Collection;

class BoxPhotosMail extends Mailable
{
    use Queueable, SerializesModels;

    /** @param Collection<int, array> $photos items from BoxAlbum (name, disk, path, invoice, label, condition, ref, at) */
    public function __construct(public string $subjectLine, public ?string $body, public Collection $photos, public ?string $senderName = null) {}

    public function envelope(): Envelope
    {
        return new Envelope(subject: $this->subjectLine);
    }

    public function content(): Content
    {
        return new Content(view: 'mail.box-photos');
    }

    public function attachments(): array
    {
        return $this->photos->map(fn (array $p) => Attachment::fromStorageDisk($p['disk'], $p['path'])->as($p['name']))->all();
    }
}
