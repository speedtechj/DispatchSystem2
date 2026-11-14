<?php

namespace App\Filament\Shared;

use App\Mail\BoxPhotosMail;
use App\Models\BoxPhoto;
use App\Models\BoxPhotoEmail;
use App\Models\Consolidator;
use App\Models\Invoice;
use App\Support\Photos\BoxAlbum;
use BackedEnum;
use Filament\Actions\Action;
use Filament\Forms\Components\TagsInput;
use Filament\Forms\Components\Textarea;
use Filament\Forms\Components\TextInput;
use Filament\Notifications\Notification;
use Filament\Pages\Page;
use Filament\Support\Icons\Heroicon;
use Illuminate\Support\Collection;
use Illuminate\Support\Facades\Auth;
use Illuminate\Support\Facades\Mail;
use Illuminate\Support\Facades\Storage;
use Livewire\Attributes\Url;
use Symfony\Component\HttpFoundation\Response;
use Throwable;
use ZipArchive;

/**
 * Every photo of a box, from container to doorstep: scan photos plus the driver's
 * delivered and not-delivered photos. Nothing is shown until you search.
 */
abstract class BoxPhotosPage extends Page
{
    protected string $view = 'filament.shared.box-photos';

    protected static string|BackedEnum|null $navigationIcon = Heroicon::OutlinedPhoto;

    protected static ?string $navigationLabel = 'Box Photos';

    protected static ?string $title = 'Box Photos';

    protected static ?string $slug = 'box-photos';

    /** Biggest email we try to send (attachments). */
    public const MAX_EMAIL_BYTES = 20 * 1024 * 1024;

    public const PLACES = [
        'unload' => 'Unload', 'wh_load' => 'WH transfer load', 'wh_unload' => 'WH transfer unload',
        'load' => 'Load', 'hub_load' => 'Hub load', 'return' => 'Return',
        'not_delivered' => 'Not delivered', 'delivered' => 'Delivered',
    ];

    #[Url]
    public string $q = '';

    #[Url]
    public string $place = '';

    #[Url]
    public string $cond = '';

    /** @var list<string> keys like p:12, d:5:0, a:3:1 */
    public array $selected = [];

    public function getHeading(): string
    {
        return '';
    }

    protected function album(): BoxAlbum
    {
        return new BoxAlbum(Auth::user());
    }

    public function updatedQ(): void
    {
        $q = trim($this->q);
        if (mb_strlen($q) >= 3) {
            $recent = collect(session('box-photos.recent', []))->reject(fn ($r) => $r === $q)->prepend($q)->take(5)->values()->all();
            session(['box-photos.recent' => $recent]);
        }
    }

    public function searchFor(string $q): void
    {
        $this->q = $q;
        $this->updatedQ();
    }

    public function clearSearch(): void
    {
        $this->reset('q', 'place', 'cond', 'selected');
    }

    public function clearSelection(): void
    {
        $this->selected = [];
    }

    protected function selectedItems(): Collection
    {
        return $this->selected === [] ? collect() : $this->album()->resolve($this->selected);
    }

    /** One photo downloads as is; several come as one ZIP file. */
    public function downloadSelected(): ?Response
    {
        $items = $this->selectedItems();
        if ($items->isEmpty()) {
            Notification::make()->title('Select photos first')->warning()->send();

            return null;
        }
        if ($items->count() === 1) {
            return Storage::disk($items[0]['disk'])->download($items[0]['path'], $items[0]['name']);
        }

        $tmp = tempnam(sys_get_temp_dir(), 'photos');
        $zip = new ZipArchive;
        $zip->open($tmp, ZipArchive::OVERWRITE);
        foreach ($items as $i) {
            $zip->addFile(Storage::disk($i['disk'])->path($i['path']), $i['name']);
        }
        $zip->close();

        $name = 'box-photos-'.($this->q !== '' ? str($this->q)->slug().'-' : '').now()->format('Ymd-His').'.zip';

        return response()->download($tmp, $name, ['Content-Type' => 'application/zip'])->deleteFileAfterSend();
    }

    /** Consolidator of the photos' boxes: from the box, else from its container. */
    protected function consolidatorFor(Collection $items): ?Consolidator
    {
        $boxes = Invoice::with('consolidator', 'container.consolidator')->whereIn('invoice', $items->pluck('invoice')->filter()->unique())->get();

        return $boxes->map(fn (Invoice $b) => $b->consolidator ?? $b->container?->consolidator)->filter()->first();
    }

    public function emailAction(): Action
    {
        return Action::make('email')
            ->label('Email to consolidator')
            ->icon(Heroicon::OutlinedEnvelope)
            ->modalHeading('Email photos to consolidator')
            ->modalSubmitActionLabel('Send email')
            ->modalWidth('xl')
            ->fillForm(function () {
                $items = $this->selectedItems();
                $con = $this->consolidatorFor($items);
                $boxes = $items->pluck('invoice')->filter()->unique();
                $bad = $items->whereIn('condition', ['damaged', 'wet', 'open'])->pluck('invoice')->unique()->filter();

                return [
                    'to' => array_values(array_filter([$con?->email])),
                    'subject' => 'Photos · '.$boxes->take(3)->join(', ').($boxes->count() > 3 ? ' +'.($boxes->count() - 3) : '').' · '.$items->count().' '.str('photo')->plural($items->count()),
                    'message' => "Hello,\n\nAttached are the photos of ".($boxes->count() === 1 ? 'box '.$boxes->first() : $boxes->count().' boxes')
                        .'. Each file name starts with the invoice number.'
                        .($bad->isNotEmpty() ? "\nPlease check: ".$bad->join(', ').'.' : '')."\n\nThank you.",
                ];
            })
            ->schema([
                TagsInput::make('to')->label('To')->placeholder('Add an email and press Enter')
                    ->helperText("Filled from the consolidator's email. You can add more.")
                    ->nestedRecursiveRules(['email'])->required(),
                TextInput::make('subject')->required()->maxLength(200),
                Textarea::make('message')->rows(6),
            ])
            ->action(function (array $data): void {
                $items = $this->selectedItems();
                if ($items->isEmpty()) {
                    Notification::make()->title('Select photos first')->warning()->send();

                    return;
                }
                $bytes = $items->sum('size');
                if ($bytes > self::MAX_EMAIL_BYTES) {
                    Notification::make()->title('Too many photos for one email')
                        ->body('About '.round($bytes / 1048576, 1).' MB selected. Keep it under 20 MB, or send in two emails.')->danger()->send();

                    return;
                }

                $log = BoxPhotoEmail::create([
                    'user_id' => Auth::id(),
                    'consolidator_id' => $this->consolidatorFor($items)?->id,
                    'recipients' => array_values($data['to']),
                    'subject' => $data['subject'],
                    'message' => $data['message'] ?? null,
                    'photo_ids' => $items->pluck('key')->all(),
                ]);

                try {
                    Mail::to($data['to'])->send(new BoxPhotosMail($data['subject'], $data['message'] ?? null, $items, Auth::user()?->full_name));
                } catch (Throwable $e) {
                    report($e);
                    $log->update(['status' => 'failed', 'error' => mb_substr($e->getMessage(), 0, 1000)]);
                    Notification::make()->title('The email was not sent')->body('Check the MAIL_ settings in .env. '.mb_substr($e->getMessage(), 0, 160))->danger()->persistent()->send();

                    return;
                }

                $this->selected = [];
                Notification::make()->title('Email sent to '.implode(', ', $data['to']))->body($items->count().' photos attached.')->success()->send();
            });
    }

    public function deleteAction(): Action
    {
        return Action::make('delete')
            ->label('Delete photo')
            ->color('danger')
            ->link()
            ->visible(fn () => (bool) Auth::user()?->hasRole('super_admin'))
            ->requiresConfirmation()
            ->modalHeading('Delete this photo?')
            ->modalDescription('The photo file is removed for good. Delivery photos from the driver are not deleted here.')
            ->action(function (array $arguments): void {
                $key = (string) ($arguments['key'] ?? '');
                if (str_starts_with($key, 'p:')) {
                    BoxPhoto::visibleTo(Auth::user())->find((int) substr($key, 2))?->delete();
                }
                $this->selected = array_values(array_diff($this->selected, [$key]));
                Notification::make()->title('Photo deleted')->send();
            });
    }

    protected function stats(): array
    {
        $week = BoxPhoto::visibleTo(Auth::user())->where('taken_at', '>=', now()->startOfWeek());

        return [
            'week' => (clone $week)->count(),
            'damaged' => (clone $week)->where('condition', 'damaged')->distinct()->count('invoice_id'),
            'wet' => (clone $week)->where('condition', 'wet')->distinct()->count('invoice_id'),
        ];
    }

    protected function getViewData(): array
    {
        $boxes = collect();
        if (trim($this->q) !== '') {
            $album = $this->album();
            $boxes = $album->boxes($album->find($this->q))
                ->filter(fn ($b) => $b['items']->contains(fn ($i) => ($this->place === '' || $i['step'] === $this->place)
                    && ($this->cond === '' || $i['condition'] === $this->cond)))
                ->values();
        }

        $items = $boxes->flatMap(fn ($b) => $b['items']->values());

        return [
            'boxes' => $boxes,
            'photoCount' => $items->count(),
            'viewer' => $items->mapWithKeys(fn ($i) => [$i['key'] => [
                'src' => $i['url'], 'dl' => $i['download'], 'name' => $i['name'], 'invoice' => $i['invoice'],
                'title' => $i['kind'] === 'delivered' ? 'Proof of delivery · '.$i['n'].' of '.$i['of']
                    : ($i['kind'] === 'not_delivered' ? 'Not delivered · '.$i['n'].' of '.$i['of'] : $i['label'].' · '.$i['invoice']),
                'ref' => $i['ref'], 'who' => $i['who'], 'when' => $i['at']?->format('d M Y · g:i A'),
                'cond' => $i['condition'], 'condLabel' => BoxPhoto::CONDITIONS[$i['condition']] ?? null,
                'note' => $i['note'], 'size' => $i['size'], 'scan' => $i['kind'] === 'scan',
                'stamp' => collect([$i['invoice'], $i['label'], $i['condition'] ? strtoupper($i['condition']) : null, $i['at']?->format('d M H:i'), $i['who']])->filter()->join(' | '),
            ]])->all(),
            'places' => self::PLACES,
            'conditions' => BoxPhoto::CONDITIONS,
            'stats' => $this->stats(),
            'recent' => session('box-photos.recent', []),
            'emails' => BoxPhotoEmail::with('user:id,first_name,last_name')->when(! Auth::user()?->hasRole('super_admin'), fn ($q) => $q->where('user_id', Auth::id()))
                ->latest()->limit(5)->get(),
        ];
    }
}
