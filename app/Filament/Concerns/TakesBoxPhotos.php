<?php

namespace App\Filament\Concerns;

use App\Models\BoxPhoto;
use App\Models\Invoice;
use App\Models\PhotoSetting;
use App\Support\Photos\BoxPhotos;
use Filament\Notifications\Notification;
use Illuminate\Support\Collection;
use Illuminate\Support\Facades\Auth;
use Livewire\Features\SupportFileUploads\TemporaryUploadedFile;

/**
 * Optional photos on a scan station. After a box is scanned the crew can mark how it looks
 * and add any number of photos; scanning never waits for a photo.
 * Pages say which step they are (photoStep) and what the photo belongs to (photoContext).
 */
trait TakesBoxPhotos
{
    /** @var TemporaryUploadedFile|null */
    public $boxPhoto = null;

    public ?string $photoCondition = null;

    public string $photoNote = '';

    /** Boxes scanned since the last batch photo. */
    public int $sinceBatch = 0;

    /** unload, load, hub_load, wh_load, wh_unload, return — or null for no photos. */
    public function photoStep(): ?string
    {
        return null;
    }

    /** container / trip / warehouse / hub the photo belongs to. */
    public function photoContext(): array
    {
        return [];
    }

    /**
     * Containers or trips to pick from in the Scan app: list of [id, name, sub].
     *
     * @return Collection<int, array{id: int, name: string, sub: ?string}>
     */
    public function appChoices(): Collection
    {
        return collect();
    }

    public function photosEnabled(): bool
    {
        $step = $this->photoStep();

        return $step !== null && PhotoSetting::current()->allows($step);
    }

    /** The box the next photo is for: the last box scanned successfully. */
    protected function photoInvoice(): ?Invoice
    {
        return $this->lastStatus === 'success' && $this->lastInvoiceId ? Invoice::find($this->lastInvoiceId) : null;
    }

    public function canPhotoBox(): bool
    {
        return $this->photosEnabled() && $this->photoInvoice() !== null;
    }

    public function batchDue(): bool
    {
        $every = PhotoSetting::current()->batch_every;

        return $this->photosEnabled() && $every > 0 && $this->sinceBatch >= $every;
    }

    public function setPhotoCondition(?string $condition): void
    {
        $this->photoCondition = array_key_exists((string) $condition, BoxPhoto::CONDITIONS) ? $condition : null;
    }

    /** Called by the browser after the (already shrunk) photo is uploaded. */
    public function saveBoxPhoto(bool $batch = false): void
    {
        if (! $this->photosEnabled()) {
            return;
        }

        $this->validate(['boxPhoto' => 'required|image|max:12288'], ['boxPhoto.image' => 'That file is not a photo.']);

        $invoice = $batch ? null : $this->photoInvoice();
        if (! $batch && ! $invoice) {
            $this->reset('boxPhoto');
            Notification::make()->title('Scan the box first, then add its photo.')->warning()->send();

            return;
        }

        BoxPhotos::store($this->boxPhoto, $this->photoStep(), $invoice, $this->photoContext(), Auth::user(),
            $batch ? null : $this->photoCondition, $batch ? null : $this->photoNote);

        $this->reset('boxPhoto');
        if ($batch) {
            $this->sinceBatch = 0;
        }

        Notification::make()->title($batch ? 'Batch photo saved' : 'Photo saved for '.$invoice->invoice)->success()->duration(2000)->send();
    }

    public function skipBatch(): void
    {
        $this->sinceBatch = 0;
    }

    /** Photos taken of the last box at this step (newest last). */
    public function lastBoxPhotos(): Collection
    {
        $invoice = $this->photoInvoice();

        return $invoice
            ? BoxPhoto::where('invoice_id', $invoice->id)->where('step', $this->photoStep())->orderBy('id')->get()
            : collect();
    }

    /** Called from scanResult(): a new box starts with no condition. */
    protected function photoAfterScan(string $status): void
    {
        $this->photoCondition = null;
        $this->photoNote = '';
        $this->reset('boxPhoto');
        if ($status === 'success') {
            $this->sinceBatch++;
        }
    }
}
