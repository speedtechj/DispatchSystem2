#!/usr/bin/env bash
#
# Dispatch System — Part 46 · Box Photos fast with R2
# Only the files changed in this step; the rest of your project is left as it is.
#
#   cd ~/Desktop/Project/DispatchSystem
#   bash ~/Desktop/Project/part46-photos-fast.sh

set -euo pipefail
[ -f artisan ] || { echo "Run this from inside your DispatchSystem project folder (the one with 'artisan')."; exit 1; }

STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="../DispatchSystem-backup-$STAMP.tar.gz"
echo "▶ Backing up the project to $BACKUP"
tar -czf "$BACKUP" --exclude=vendor --exclude=node_modules --exclude=storage/logs .

echo "▶ Writing 8 files"

# ---------------------------------------------------------------- app/Filament/Shared/BoxPhotosPage.php
mkdir -p 'app/Filament/Shared'
cat > 'app/Filament/Shared/BoxPhotosPage.php' <<'DISPATCH_FILE_END_0'
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
use App\Support\Ai\Ai;
use App\Support\Ai\AiUnavailable;
use App\Support\Ai\BoxEmailWriter;
use App\Support\Ai\EmailLanguages;
use Filament\Forms\Components\CheckboxList;
use Filament\Forms\Components\TagsInput;
use Filament\Forms\Components\Toggle;
use Filament\Forms\Components\ToggleButtons;
use Filament\Schemas\Components\Utilities\Get;
use Filament\Schemas\Components\Utilities\Set;
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

    /** Board 71: 'box' = a card for each box, 'all' = one gallery of all photos by day. */
    #[Url]
    public string $arrange = 'box';

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

    /** Part 45: the search runs on Enter, the 🔍 button, a scan or a Recent chip, never on every key. */
    public function searchFor(string $q): void
    {
        $this->q = mb_substr(trim($q), 0, 60);
        $this->selected = [];
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
    public function downloadSelected(array $keys = []): ?Response
    {
        $items = $keys ? $this->album()->resolve(array_map('strval', $keys)) : $this->selectedItems();
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
            // Part 46: read through the disk, so photos in the bucket (R2) are in the ZIP too
            $bytes = rescue(fn () => Storage::disk($i['disk'])->get($i['path']), null, false);
            if ($bytes !== null) {
                $zip->addFromString($i['name'], $bytes);
            }
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

    /** Part 45 (board 73): photos of one box (✉ on the box or in the viewer), else the selected ones. */
    protected function emailItems(array $arguments = []): Collection
    {
        $keys = array_values(array_filter(array_map('strval', (array) ($arguments['keys'] ?? []))));

        return $keys ? $this->album()->resolve($keys) : $this->selectedItems();
    }

    protected function plainMessage(Collection $items): string
    {
        $boxes = $items->pluck('invoice')->filter()->unique();
        $bad = $items->whereIn('condition', ['damaged', 'wet', 'open'])->pluck('invoice')->unique()->filter();

        return "Hello,\n\nAttached are the photos of ".($boxes->count() === 1 ? 'box '.$boxes->first() : $boxes->count().' boxes')
            .'. Each file name starts with the invoice number.'
            .($bad->isNotEmpty() ? "\nPlease check: ".$bad->join(', ').'.' : '')."\n\nThank you.";
    }

    public function emailAction(): Action
    {
        return Action::make('email')
            ->label('Email to consolidator')
            ->icon(Heroicon::OutlinedEnvelope)
            ->modalHeading(function (array $arguments) {
                $boxes = $this->emailItems($arguments)->pluck('invoice')->filter()->unique();

                return 'Email photos'.($boxes->count() === 1 ? ' · '.$boxes->first() : ' · '.$boxes->count().' boxes');
            })
            ->modalSubmitActionLabel('Send email')
            ->modalWidth('3xl')
            ->fillForm(function (array $arguments) {
                $items = $this->emailItems($arguments);
                $con = $this->consolidatorFor($items);
                $boxes = $items->pluck('invoice')->filter()->unique();

                return [
                    'to' => array_values(array_filter([$con?->email])),
                    'lang' => EmailLanguages::for($con?->id),
                    'english' => false,
                    'subject' => 'Photos · '.$boxes->take(3)->join(', ').($boxes->count() > 3 ? ' +'.($boxes->count() - 3) : '').' · '.$items->count().' '.str('photo')->plural($items->count()),
                    'message' => $this->plainMessage($items),
                    'keys' => $items->pluck('key')->all(),
                ];
            })
            ->schema(fn (array $arguments) => [
                TagsInput::make('to')->label('To')->placeholder('Add an email and press Enter')
                    ->helperText("Filled from the consolidator's email. You can add more.")
                    ->nestedRecursiveRules(['email'])->required(),
                ToggleButtons::make('lang')->label('Language of the email')->options(EmailLanguages::options())->inline()->live()
                    ->helperText(fn (Get $get) => in_array($get('lang'), EmailLanguages::CHECK, true)
                        ? 'The AI writes this language less surely: read it before sending, or tick Add English below.'
                        : 'Remembered for this consolidator.'),
                Toggle::make('english')->label('Add English below')->inline(),
                TextInput::make('subject')->required()->maxLength(200),
                Textarea::make('message')->rows(10)
                    ->hintAction(Action::make('aiWrite')->label('✨ Write with AI')->color('info')
                        ->visible(fn () => Ai::switchedOn('issues'))
                        ->action(function (Get $get, Set $set) use ($arguments) {
                            $items = $this->emailItems($arguments)->whereIn('key', (array) $get('keys'))->values();
                            if ($items->isEmpty()) {
                                $items = $this->emailItems($arguments);
                            }
                            try {
                                $d = BoxEmailWriter::draft($items, (string) $get('lang'), (bool) $get('english'));
                            } catch (AiUnavailable $e) {
                                Notification::make()->title('The AI helper is not available')->body($e->getMessage())->warning()->send();

                                return;
                            }
                            if ($d['body'] !== '') {
                                $set('message', $d['body']);
                            }
                            if ($d['subject'] !== '') {
                                $set('subject', $d['subject']);
                            }
                        })),
                CheckboxList::make('keys')->label('Photos to attach')->allowHtml()->columns(4)->bulkToggleable()
                    ->options(fn () => $this->emailItems($arguments)->mapWithKeys(fn ($i) => [$i['key'] => '<span style="display:flex;gap:.5rem;align-items:center">'
                        .'<img src="'.e($i['url']).'" alt="" style="width:3.4rem;height:2.6rem;object-fit:cover;border-radius:.4rem">'
                        .'<span style="font-size:.75rem;line-height:1.2"><b>'.e($i['invoice']).'</b><br>'.e($i['label']).' · '.max(1, (int) round($i['size'] / 1024)).' KB</span></span>'])->all())
                    ->required(),
            ])
            ->action(function (array $data, array $arguments): void {
                $items = $this->emailItems($arguments)->whereIn('key', (array) ($data['keys'] ?? []))->values();
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
                $con = $this->consolidatorFor($items);
                EmailLanguages::remember($con?->id, (string) ($data['lang'] ?? 'en'));

                $log = BoxPhotoEmail::create([
                    'user_id' => Auth::id(),
                    'consolidator_id' => $con?->id,
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
        $match = null;
        if (trim($this->q) !== '') {
            $album = $this->album();
            $match = $album->match($this->q);
            $boxes = $album->boxes($match['ids'])
                ->filter(fn ($b) => $b['items']->contains(fn ($i) => ($this->place === '' || $i['step'] === $this->place)
                    && ($this->cond === '' || $i['condition'] === $this->cond)))
                ->values();
        }

        $items = $boxes->flatMap(fn ($b) => $b['items']->values());

        return [
            'boxes' => $boxes,
            'match' => $match['kind'] ?? null,
            'arrange' => $this->arrange === 'all' ? 'all' : 'box',
            'days' => $boxes->flatMap(fn ($b) => $b['items'])->sortByDesc(fn ($i) => $i['at']?->timestamp ?? 0)
                ->groupBy(fn ($i) => $i['at'] ? ($i['at']->isToday() ? 'Today · '.$i['at']->format('D d M Y') : $i['at']->format('D d M Y')) : 'No date', true),
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
DISPATCH_FILE_END_0

# ---------------------------------------------------------------- app/Http/Controllers/BoxPhotoController.php
mkdir -p 'app/Http/Controllers'
cat > 'app/Http/Controllers/BoxPhotoController.php' <<'DISPATCH_FILE_END_1'
<?php

namespace App\Http\Controllers;

use App\Models\BoxPhoto;
use App\Support\Photos\Storage\PhotoStore;
use Illuminate\Support\Facades\Auth;
use Illuminate\Support\Facades\Storage;
use Symfony\Component\HttpFoundation\Response;

/** Photos are private files: only signed-in users who may see the box get them. */
class BoxPhotoController extends Controller
{
    /**
     * Part 46: a photo in the bucket (R2) is not copied through this server any more (that was slow):
     * the browser is sent to a short-lived private link and loads it straight from the bucket.
     * A photo still on this server is sent as a file.
     */
    public function show(int $photo): Response
    {
        $p = $this->find($photo, check: false);
        $place = PhotoStore::placeOf('box', $p->path);
        if ($place !== 'server') {
            return redirect()->away(PhotoStore::link($place, PhotoStore::key('box', $p->path)))
                ->header('Cache-Control', 'private, max-age=3000');
        }
        abort_unless(Storage::disk('box')->exists($p->path), 404);

        return response(Storage::disk('box')->get($p->path), 200, [
            'Content-Type' => 'image/jpeg',
            'Cache-Control' => 'private, max-age=86400',
        ]);
    }

    public function download(int $photo): Response
    {
        $p = $this->find($photo);

        return Storage::disk('box')->download($p->path, $p->fileName());
    }

    protected function find(int $id, bool $check = true): BoxPhoto
    {
        abort_unless(Auth::check(), 403);
        $p = BoxPhoto::visibleTo(Auth::user())->find($id);
        abort_unless($p && (! $check || $p->exists()), 404);

        return $p;
    }
}
DISPATCH_FILE_END_1

# ---------------------------------------------------------------- app/Models/BoxPhoto.php
mkdir -p 'app/Models'
cat > 'app/Models/BoxPhoto.php' <<'DISPATCH_FILE_END_2'
<?php

namespace App\Models;

use Illuminate\Database\Eloquent\Builder;
use Illuminate\Database\Eloquent\Model;
use Illuminate\Database\Eloquent\Relations\BelongsTo;
use Illuminate\Support\Facades\Storage;

/** One photo taken while scanning. Every capture is its own row and file; nothing is replaced. */
class BoxPhoto extends Model
{
    public const STEPS = [
        'unload' => 'Unloading a container',
        'load' => 'Loading a delivery truck',
        'hub_load' => 'Loading at a partner hub',
        'wh_load' => 'Warehouse to warehouse: loading',
        'wh_unload' => 'Warehouse to warehouse: unloading',
        'return' => 'Returning boxes',
        'hub_receive' => 'Receiving at a partner hub',
    ];

    public const SHORT = [
        'unload' => 'Unload', 'load' => 'Load', 'hub_load' => 'Hub load',
        'wh_load' => 'WH transfer load', 'wh_unload' => 'WH transfer unload', 'return' => 'Return', 'hub_receive' => 'Hub receive',
    ];

    public const CONDITIONS = ['good' => 'Good', 'damaged' => 'Damaged', 'wet' => 'Wet', 'open' => 'Open'];

    protected $guarded = [];

    protected function casts(): array
    {
        return ['taken_at' => 'datetime', 'is_batch' => 'boolean'];
    }

    public function box(): BelongsTo
    {
        return $this->belongsTo(Invoice::class, 'invoice_id');
    }

    public function container(): BelongsTo
    {
        return $this->belongsTo(Container::class);
    }

    public function deliverylog(): BelongsTo
    {
        return $this->belongsTo(Deliverylog::class);
    }

    public function whdeliverylog(): BelongsTo
    {
        return $this->belongsTo(Whdeliverylog::class);
    }

    public function user(): BelongsTo
    {
        return $this->belongsTo(User::class);
    }

    public function warehouse(): BelongsTo
    {
        return $this->belongsTo(Warehouse::class);
    }

    public function logistichub(): BelongsTo
    {
        return $this->belongsTo(Logistichub::class);
    }

    /**
     * Who may see which photos: admin and warehouse staff see all;
     * partner hub staff see photos of boxes sent to their hub or taken by them.
     */
    public function scopeVisibleTo(Builder $query, ?User $user): Builder
    {
        if (! $user) {
            return $query->whereRaw('1 = 0');
        }
        if ($user->hasRole('super_admin')) {
            return $query;
        }
        $hub = $user->logistichub_id ? Logistichub::find($user->logistichub_id) : null;
        if (! $hub || ! $hub->is_company) {
            // admin and warehouse staff
            return ($hub || $user->warehouse_id) ? $query : $query->whereRaw('1 = 0');
        }

        return $query->where(fn (Builder $q) => $q->where('logistichub_id', $hub->id)
            ->orWhereIn('invoice_id', Tripinvoice::where('logistichub_id', $hub->id)->select('invoice_id')));
    }

    public function scopeSearch(Builder $query, string $term): Builder
    {
        $term = trim($term);
        if ($term === '') {
            return $query;
        }

        return $query->where(fn (Builder $q) => $q->where('invoice', 'like', "%{$term}%")
            ->orWhereHas('container', fn (Builder $c) => $c->where('container_no', 'like', "%{$term}%"))
            ->orWhereHas('deliverylog', fn (Builder $d) => $d->where('trip_number', 'like', "%{$term}%"))
            ->orWhereHas('whdeliverylog', fn (Builder $d) => $d->where('trip_number', 'like', "%{$term}%")));
    }

    public function url(): string
    {
        return route('box-photos.show', $this);
    }

    public function downloadUrl(): string
    {
        return route('box-photos.download', $this);
    }

    /** Where it was taken: container or trip. */
    public function reference(): string
    {
        return match (true) {
            (bool) $this->deliverylog_id => 'Trip '.($this->deliverylog?->trip_number ?? '#'.$this->deliverylog_id),
            (bool) $this->whdeliverylog_id => 'WH trip '.($this->whdeliverylog?->trip_number ?? '#'.$this->whdeliverylog_id),
            (bool) $this->container_id => 'Container '.($this->container?->container_no ?? '#'.$this->container_id),
            default => '—',
        };
    }

    public function place(): string
    {
        return $this->warehouse?->name ?? $this->logistichub?->hub_name ?? '';
    }

    /** INV004521_unload_2.jpg — position among the photos of this box at this step. */
    public function fileName(?int $n = null): string
    {
        $n ??= static::where('invoice_id', $this->invoice_id)->where('step', $this->step)->where('is_batch', $this->is_batch)
            ->where('id', '<=', $this->id)->count();
        $base = $this->is_batch ? 'batch_'.str($this->reference())->slug('_') : ($this->invoice ?: 'box');

        return $base.'_'.$this->step.'_'.max(1, $n).'.jpg';
    }

    public function exists(): bool
    {
        return Storage::disk('box')->exists($this->path);
    }

    protected static function booted(): void
    {
        static::deleting(fn (BoxPhoto $p) => Storage::disk('box')->delete($p->path));
    }
}
DISPATCH_FILE_END_2

# ---------------------------------------------------------------- app/Support/Photos/BoxAlbum.php
mkdir -p 'app/Support/Photos'
cat > 'app/Support/Photos/BoxAlbum.php' <<'DISPATCH_FILE_END_3'
<?php

namespace App\Support\Photos;

use App\Models\BoxPhoto;
use App\Models\DeliveryAttempt;
use App\Models\Deliverylog;
use App\Models\Invoice;
use App\Models\Logistichub;
use App\Models\Tripinvoice;
use App\Models\User;
use App\Models\Whdeliverylog;
use App\Models\Whtripinvoice;
use Illuminate\Support\Carbon;
use Illuminate\Support\Collection;
use Illuminate\Support\Facades\Storage;

/**
 * Every photo of a box in one list: scan photos (box_photos) plus the driver's
 * delivery photos (tripinvoices.delivery_picture) and not-delivered photos (delivery_attempts.photos).
 *
 * Each photo is an array with a key used for selecting it:
 *   p:{box_photo id}   d:{tripinvoice id}:{n}   a:{delivery attempt id}:{n}
 */
class BoxAlbum
{
    public const MAX_BOXES = 30;

    public function __construct(public readonly ?User $user) {}

    /** Partner hub users only see their own boxes. Null = sees everything. */
    protected function hubLimit(): ?int
    {
        if (! $this->user || $this->user->hasRole('super_admin')) {
            return $this->user ? null : -1;
        }
        $hub = $this->user->logistichub_id ? Logistichub::find($this->user->logistichub_id) : null;
        if ($hub?->is_company) {
            return $hub->id;
        }

        return ($hub || $this->user->warehouse_id) ? null : -1;
    }

    /** Invoice ids for a search by invoice, container or trip number. */
    public function find(string $q): Collection
    {
        $q = trim($q);
        if ($q === '') {
            return collect();
        }

        $ids = Invoice::query()->where('invoice', 'like', "%{$q}%")->limit(200)->pluck('id')
            ->merge(BoxPhoto::search($q)->whereNotNull('invoice_id')->limit(500)->pluck('invoice_id'))
            ->merge(Invoice::query()->whereHas('container', fn ($c) => $c->where('container_no', 'like', "%{$q}%"))->limit(500)->pluck('id'))
            ->merge(Tripinvoice::query()->where(fn ($t) => $t
                ->whereIn('deliverylog_id', Deliverylog::where('trip_number', 'like', "%{$q}%")->select('id'))
                ->orWhereIn('deliveryloghub_id', Deliverylog::where('trip_number', 'like', "%{$q}%")->select('id')))->limit(500)->pluck('invoice_id'))
            ->merge(Whtripinvoice::query()->whereIn('whdeliverylog_id', Whdeliverylog::where('trip_number', 'like', "%{$q}%")->select('id'))->limit(500)->pluck('invoice_id'))
            ->filter()->unique()->values();

        return $this->allowed($ids);
    }

    /**
     * Part 45 (board 72): an exact box, trip or container number first; similar numbers only when nothing is exact.
     *
     * @return array{kind: string, ids: Collection}  kind: short | exact | trip | container | like
     */
    public function match(string $q): array
    {
        $q = trim($q);
        if (mb_strlen($q) < 3) {
            return ['kind' => 'short', 'ids' => collect()];
        }
        $exact = Invoice::query()->where('invoice', $q)->limit(20)->pluck('id');
        if ($exact->isNotEmpty()) {
            return ['kind' => 'exact', 'ids' => $this->allowed($exact)];
        }
        $trips = Deliverylog::where('trip_number', $q)->pluck('id');
        $whTrips = Whdeliverylog::where('trip_number', $q)->pluck('id');
        if ($trips->isNotEmpty() || $whTrips->isNotEmpty()) {
            $ids = Tripinvoice::query()->where(fn ($t) => $t->whereIn('deliverylog_id', $trips)->orWhereIn('deliveryloghub_id', $trips))->limit(1000)->pluck('invoice_id')
                ->merge(Whtripinvoice::query()->whereIn('whdeliverylog_id', $whTrips)->limit(1000)->pluck('invoice_id'))->filter()->unique()->values();

            return ['kind' => 'trip', 'ids' => $this->allowed($ids)];
        }
        $cont = Invoice::query()->whereHas('container', fn ($c) => $c->where('container_no', $q))->limit(1000)->pluck('id');
        if ($cont->isNotEmpty()) {
            return ['kind' => 'container', 'ids' => $this->allowed($cont)];
        }

        return ['kind' => 'like', 'ids' => $this->find($q)];
    }

    /** The boxes of these that this user may see. */
    public function allowed(Collection $ids): Collection
    {
        $hub = $this->hubLimit();
        if ($hub === -1) {
            return collect();
        }
        if ($hub === null) {
            return $ids->values();
        }

        return $ids->intersect(
            Tripinvoice::where('logistichub_id', $hub)->whereIn('invoice_id', $ids)->pluck('invoice_id')
                ->merge(BoxPhoto::where('logistichub_id', $hub)->whereIn('invoice_id', $ids)->pluck('invoice_id'))
        )->values();
    }

    /**
     * Boxes with their photos, newest box first. Boxes without any photo are left out.
     *
     * @return Collection<int, array{invoice: Invoice, items: Collection, journey: array, worst: ?string, delivered: ?array, attempts: Collection}>
     */
    public function boxes(Collection $invoiceIds): Collection
    {
        if ($invoiceIds->isEmpty()) {
            return collect();
        }

        $invoices = Invoice::whereKey($invoiceIds->take(500))->get()->keyBy('id');
        $scan = BoxPhoto::visibleTo($this->user)
            ->with('container:id,container_no', 'deliverylog:id,trip_number', 'whdeliverylog:id,trip_number', 'user:id,first_name,last_name', 'warehouse:id,name', 'logistichub:id,hub_name')
            ->whereIn('invoice_id', $invoices->keys())->orderBy('taken_at')->orderBy('id')->get()->groupBy('invoice_id');
        $trips = Tripinvoice::with('deliverer:id,first_name,last_name', 'deliverylog:id,trip_number', 'hubTrip:id,trip_number')
            ->whereIn('invoice_id', $invoices->keys())->where('is_delivered', true)->get()->groupBy('invoice_id');
        $attempts = DeliveryAttempt::with('user:id,first_name,last_name', 'deliverylog:id,trip_number')
            ->whereIn('invoice_id', $invoices->keys())->orderBy('created_at')->get()->groupBy('invoice_id');

        // Part 46: where every photo is (server or bucket), in two queries instead of one per photo
        \App\Support\Photos\Storage\PhotoStore::preload('box', $scan->flatten()->pluck('path')->all());
        \App\Support\Photos\Storage\PhotoStore::preload('public', $trips->flatten()->flatMap(fn ($t) => (array) $t->delivery_picture)
            ->merge($attempts->flatten()->flatMap(fn ($a) => (array) $a->photos))->filter()->values()->all());

        return $invoices->map(function (Invoice $box) use ($scan, $trips, $attempts) {
            $items = collect();
            // file names (INV_unload_2.jpg) numbered here, not with one query per photo
            $seq = [];
            $nums = [];
            foreach ($scan->get($box->id, collect())->sortBy('id') as $p) {
                $k = $p->step.'|'.(int) $p->is_batch;
                $nums[$p->id] = $seq[$k] = ($seq[$k] ?? 0) + 1;
            }
            foreach ($scan->get($box->id, collect()) as $p) {
                $items->push($this->scanItem($p, $nums[$p->id] ?? null));
            }

            $missCards = collect();
            foreach ($attempts->get($box->id, collect()) as $a) {
                $photos = collect($a->photos)->filter()->values();
                $cardItems = $photos->map(fn ($path, $n) => $this->publicItem('a:'.$a->id.':'.$n, $box, 'not_delivered', $path, $n + 1, $photos->count(), [
                    'ref' => 'Trip '.($a->deliverylog?->trip_number ?? '—').' · '.$a->reason->getLabel(),
                    'who' => $a->user?->full_name, 'at' => $a->created_at, 'note' => $a->note,
                ]))->filter();
                $items = $items->merge($cardItems);
                $missCards->push(['reason' => $a->reason->getLabel(), 'at' => $a->created_at, 'who' => $a->user?->full_name,
                    'trip' => $a->deliverylog?->trip_number, 'note' => $a->note, 'keys' => $cardItems->pluck('key')->all()]);
            }

            $delivered = null;
            if ($row = $trips->get($box->id)?->sortByDesc('delivered_at')->first()) {
                $photos = collect($row->delivery_picture)->filter()->values();
                $at = $row->delivered_at ? Carbon::parse($row->delivered_at) : $row->updated_at;
                $trip = $row->hubTrip?->trip_number ?? $row->deliverylog?->trip_number;
                // Part 44: signed on the phone (damaged, or no paper receipt)
                $sig = \Illuminate\Support\Facades\Schema::hasTable('delivery_signatures') ? \App\Models\DeliverySignature::where('tripinvoice_id', $row->id)->latest('id')->first() : null;
                $cardItems = $photos->map(fn ($path, $n) => $this->publicItem('d:'.$row->id.':'.$n, $box, 'delivered', $path, $n + 1, $photos->count(), [
                    'ref' => 'Trip '.($trip ?? '—').' · delivered to '.($sig?->recipient_name ?: ($box->receiver_name ?: 'receiver')),
                    'who' => $row->deliverer?->full_name, 'at' => $at, 'note' => null,
                ]))->filter()->map(function ($i) use ($sig) {
                    if (str_contains((string) $i['path'], '/receipt-')) {
                        $i['label'] = 'Signed receipt';
                    } elseif ($sig?->isDamaged()) {
                        $i['condition'] = 'damaged';
                        $i['note'] = $sig->damageText();
                    }

                    return $i;
                });
                $items = $items->merge($cardItems);
                $delivered = ['at' => $at, 'who' => $row->deliverer?->full_name, 'to' => $sig?->recipient_name ?: $box->receiver_name, 'trip' => $trip, 'keys' => $cardItems->pluck('key')->all(),
                    'signed' => $sig ? ['by' => $sig->recipient_name, 'rel' => $sig->relationship, 'damaged' => $sig->isDamaged(), 'damage' => $sig->damageText(),
                        'paper' => \App\Models\DeliverySignature::PAPER[$sig->paper_reason] ?? null, 'link' => $sig->link(), 'cant' => $sig->cant_sign, 'issue' => $sig->invoiceissue_id] : null];
            }

            if ($items->isEmpty()) {
                return null;
            }

            return [
                'invoice' => $box,
                'items' => $items->keyBy('key'),
                'journey' => $this->journey($items),
                'worst' => static::worst($items->pluck('condition')),
                'delivered' => $delivered,
                'attempts' => $missCards,
                'latest' => $items->max(fn ($i) => $i['at']?->timestamp ?? 0),
            ];
        })->filter()->sortByDesc('latest')->take(self::MAX_BOXES)->values();
    }

    /** All photos of one box, oldest first (for the invoice Photos window and Track a box). */
    public function forInvoice(?int $invoiceId): Collection
    {
        return $invoiceId ? ($this->boxes(collect([$invoiceId]))->first()['items'] ?? collect())->sortBy(fn ($i) => $i['at']?->timestamp ?? 0)->values() : collect();
    }

    /** Photos for the given keys, if this user may see them. */
    public function resolve(array $keys): Collection
    {
        $keys = collect($keys)->map(fn ($k) => (string) $k)->unique();
        $boxIds = collect();
        foreach ($keys as $key) {
            [$kind, $id] = array_pad(explode(':', $key), 2, null);
            $boxIds->push(match ($kind) {
                'p' => BoxPhoto::whereKey((int) $id)->value('invoice_id'),
                'd' => Tripinvoice::whereKey((int) $id)->value('invoice_id'),
                'a' => DeliveryAttempt::whereKey((int) $id)->value('invoice_id'),
                default => null,
            });
        }

        return $this->boxes($this->allowed($boxIds->filter()->unique()->values()))->flatMap(fn ($b) => $b['items']->values())
            ->filter(fn ($i) => $keys->contains($i['key']))->values();
    }

    protected function scanItem(BoxPhoto $p, ?int $n = null): array
    {
        return [
            'key' => 'p:'.$p->id, 'kind' => 'scan', 'step' => $p->step,
            'label' => BoxPhoto::SHORT[$p->step] ?? $p->step,
            'condition' => $p->condition, 'note' => $p->note,
            'ref' => $p->reference(), 'place' => $p->place(), 'who' => $p->user?->full_name, 'at' => $p->taken_at,
            'url' => $p->url(), 'download' => $p->downloadUrl(), 'name' => $n ? $p->fileName($n) : $p->fileName(),
            'disk' => 'box', 'path' => $p->path, 'size' => (int) $p->size,
            'invoice' => $p->invoice, 'photo' => $p,
        ];
    }

    protected function publicItem(string $key, Invoice $box, string $step, string $path, int $n, int $of, array $meta): ?array
    {
        $disk = Storage::disk('public');
        // Part 46: a photo in the bucket is not asked for (one slow call to R2 per photo); a photo on this server is checked here.
        $place = \App\Support\Photos\Storage\PhotoStore::placeOf('public', $path);
        if ($place === 'server' && ! Storage::disk('public')->exists($path)) {
            return null;
        }
        $size = $place === 'server'
            ? (int) rescue(fn () => $disk->size($path), 0, false)
            : (int) (\App\Support\Photos\Storage\PhotoStore::knownSize('public', $path) ?? 180 * 1024);
        $ext = strtolower(pathinfo($path, PATHINFO_EXTENSION)) ?: 'jpg';

        return [
            'key' => $key, 'kind' => $step, 'step' => $step,
            'label' => $step === 'delivered' ? 'Delivered' : 'Not delivered',
            'condition' => null, 'note' => $meta['note'], 'n' => $n, 'of' => $of,
            'ref' => $meta['ref'], 'place' => null, 'who' => $meta['who'], 'at' => $meta['at'],
            'url' => $disk->url($path), 'download' => $disk->url($path), 'name' => $box->invoice.'_'.$step.'_'.$n.'.'.$ext,
            'disk' => 'public', 'path' => $path, 'size' => $size,
            'invoice' => $box->invoice, 'photo' => null,
        ];
    }

    /** Steps in the order they happened, each with its worst condition. */
    protected function journey(Collection $items): array
    {
        return $items->reject(fn ($i) => $i['label'] === 'Signed receipt')->sortBy(fn ($i) => $i['at']?->timestamp ?? 0)->groupBy('label')
            ->map(fn ($g, $label) => ['label' => $label, 'kind' => $g->first()['kind'], 'condition' => static::worst($g->pluck('condition')), 'at' => $g->first()['at']?->timestamp ?? 0])
            ->sortBy('at')->values()->all();
    }

    public static function worst(Collection $conditions): ?string
    {
        foreach (['damaged', 'wet', 'open', 'good'] as $c) {
            if ($conditions->contains($c)) {
                return $c;
            }
        }

        return null;
    }
}
DISPATCH_FILE_END_3

# ---------------------------------------------------------------- app/Support/Photos/Storage/PhotoStore.php
mkdir -p 'app/Support/Photos/Storage'
cat > 'app/Support/Photos/Storage/PhotoStore.php' <<'DISPATCH_FILE_END_4'
<?php

namespace App\Support\Photos\Storage;

use App\Models\AppSetting;
use App\Models\Photos\PhotoFile;
use App\Models\Photos\StorageBucket;
use Illuminate\Contracts\Filesystem\Filesystem;
use Illuminate\Filesystem\FilesystemAdapter;
use Illuminate\Support\Facades\Cache;
use Illuminate\Support\Facades\Schema;
use Illuminate\Support\Facades\Storage;
use Illuminate\Support\Str;

/**
 * Settings → Photo storage. Every photo of every app (scan app, driver app, panels) is saved
 * where "New photos go to" points: this server, the Temporary bucket or the Real bucket.
 * Each photo that is not on the server has a row in photo_files saying where it is, so old
 * photos keep opening after a switch. Links to bucket photos are made when a page shows them
 * (temporary links, the buckets stay private).
 */
class PhotoStore
{
    public const PLACES = ['server' => 'This server', 'tmp' => 'Temporary bucket', 'real' => 'Real bucket'];

    public const PROVIDERS = ['r2' => 'Cloudflare R2', 's3' => 'Amazon S3', 'other' => 'Other S3-compatible'];

    /** Folders on the public disk that always stay on the server (logos and icons used in PDFs and the app). */
    public const SKIP = ['livewire-tmp', 'filament-exports', 'filament-imports', 'exports', 'imports', 'brand', 'favicon', 'logo',
        'consolidatorlogo', 'help', 'icons', 'pwa', 'invoiceissue-attachments', 'email-attachments'];

    /** Tests: buckets are folders on the disk instead of R2. */
    public static bool $fake = false;

    protected static array $memo = [];

    protected static ?int $memoApp = null;

    protected static function memo(): array
    {
        if (static::$memoApp !== spl_object_id(app())) {
            static::$memoApp = spl_object_id(app());
            static::$memo = [];
        }

        return static::$memo;
    }

    public static function forgetMemo(): void
    {
        static::$memo = [];
        Cache::forget('photo_files.any');
    }

    public static function ready(): bool
    {
        static::memo();

        return static::$memo['ready'] ??= Schema::hasTable('photo_files') && Schema::hasTable('storage_buckets');
    }

    /** The S3 driver (composer require league/flysystem-aws-s3-v3). */
    public static function driverReady(): bool
    {
        return static::$fake || class_exists(\League\Flysystem\AwsS3V3\AwsS3V3Adapter::class);
    }

    public static function target(): string
    {
        $t = (string) AppSetting::get('photos.target', 'server');

        return isset(static::PLACES[$t]) ? $t : 'server';
    }

    public static function setTarget(string $place): void
    {
        AppSetting::put('photos.target', $place);
    }

    public static function bucket(string $slot): StorageBucket
    {
        static::memo();
        if (! static::ready()) {
            return new StorageBucket(['slot' => $slot, 'provider' => 'r2']);
        }

        return static::$memo['bucket'][$slot] ??= StorageBucket::firstOrNew(['slot' => $slot], ['provider' => 'r2']);
    }

    /** A bucket new photos can go to: set, tested, not turned off, and the driver is there. */
    public static function usable(string $slot): bool
    {
        if ($slot === 'server') {
            return true;
        }
        $b = static::bucket($slot);

        return static::driverReady() && $b->exists && $b->isSet() && $b->test_ok && ! $b->is_off;
    }

    /** A bucket photos can be read from (turned off still reads, so nothing breaks). */
    public static function readable(string $slot): bool
    {
        $b = static::bucket($slot);

        return static::driverReady() && $b->exists && $b->isSet();
    }

    public static function config(StorageBucket $b): array
    {
        if (static::$fake) {
            return ['driver' => 'local', 'root' => storage_path('framework/testing/buckets/'.$b->slot.'-'.($b->bucket ?: 'x')), 'throw' => true];
        }

        return array_filter([
            'driver' => 's3',
            'key' => trim((string) $b->access_key),
            'secret' => trim((string) $b->secret),
            'region' => $b->provider === 'r2' ? 'auto' : (trim((string) $b->region) ?: 'us-east-1'),
            'bucket' => trim((string) $b->bucket),
            'endpoint' => $b->endpointUrl(),
            'use_path_style_endpoint' => $b->provider !== 's3',
            'visibility' => 'private',
            'throw' => true,
            // R2 and other S3-compatible stores: only the checksums they need.
            'request_checksum_calculation' => 'when_required',
            'response_checksum_validation' => 'when_required',
        ], fn ($v) => $v !== null && $v !== '');
    }

    /** The bucket as a Laravel disk. */
    public static function fs(string $slot): FilesystemAdapter
    {
        static::memo();
        $b = static::bucket($slot);
        $key = $slot.':'.($b->updated_at?->timestamp ?? 0);

        return static::$memo['fs'][$key] ??= Storage::build(static::config($b));
    }

    /** The disk on this server behind a routed disk (public or box). */
    public static function server(string $disk): Filesystem
    {
        static::memo();

        return static::$memo['server'][$disk] ??= Storage::build(config('filesystems.disks.'.$disk.'.inner') + ['throw' => true]);
    }

    /** The key in the bucket: the same path (old box photos, box-photos/…, under private/). */
    public static function key(string $disk, string $path): string
    {
        $path = ltrim($path, '/');

        return ($disk === 'box' && str_starts_with($path, 'box-photos/') ? 'private/' : '').$path;
    }

    public static function skip(string $disk, string $path): bool
    {
        return $disk === 'public' && in_array(explode('/', ltrim($path, '/'))[0], static::SKIP, true);
    }

    /** Any photo off the server at all? (Before anything moved, nothing is looked up.) */
    public static function any(): bool
    {
        static::memo();

        return static::$memo['any'] ??= static::ready() && Cache::rememberForever('photo_files.any', fn () => PhotoFile::query()->exists());
    }

    public static function placeOf(string $disk, string $path): string
    {
        if (! static::any()) {
            return 'server';
        }
        static::memo();
        $k = $disk.'|'.$path;
        if (! array_key_exists($k, static::$memo['place'] ?? [])) {
            if (count(static::$memo['place'] ?? []) > 5000) {
                static::$memo['place'] = [];
            }
            static::$memo['place'][$k] = PhotoFile::where('disk', $disk)->where('path', $path)->value('place') ?? 'server';
        }
        $place = static::$memo['place'][$k];

        return $place === 'server' || ! static::readable($place) ? 'server' : $place;
    }

    /**
     * Part 46: look up where many photos are with one query (a page of photos asked one by one was slow).
     * Also keeps their size, so nobody asks the bucket for it.
     */
    public static function preload(string $disk, array $paths): void
    {
        $paths = array_values(array_unique(array_filter($paths)));
        if ($paths === [] || ! static::any()) {
            return;
        }
        static::memo();
        foreach (array_chunk($paths, 500) as $chunk) {
            $rows = PhotoFile::where('disk', $disk)->whereIn('path', $chunk)->get(['path', 'place', 'size'])->keyBy('path');
            foreach ($chunk as $path) {
                static::$memo['place'][$disk.'|'.$path] = $rows[$path]->place ?? 'server';
                static::$memo['size'][$disk.'|'.$path] = $rows[$path]->size ?? null;
            }
        }
    }

    /** The size kept in photo_files (null when not known). */
    public static function knownSize(string $disk, string $path): ?int
    {
        static::memo();
        if (! array_key_exists($disk.'|'.$path, static::$memo['size'] ?? [])) {
            static::preload($disk, [$path]);
        }
        $v = static::$memo['size'][$disk.'|'.$path] ?? null;

        return $v === null ? null : (int) $v;
    }

    /** Where a new photo goes. */
    public static function targetFor(string $disk, string $path): string
    {
        if (! static::ready() || static::skip($disk, $path)) {
            return 'server';
        }
        $t = static::target();

        return $t !== 'server' && static::usable($t) ? $t : 'server';
    }

    public static function record(string $disk, string $path, string $place, ?int $size = null, ?string $note = null): void
    {
        if (! static::ready()) {
            return;
        }
        static::memo();
        if ($place === 'server' && ! $note) {
            PhotoFile::where('disk', $disk)->where('path', $path)->delete();
        } else {
            PhotoFile::updateOrCreate(['disk' => $disk, 'path' => $path], ['place' => $place, 'size' => $size, 'note' => $note ? Str::limit($note, 150, '') : null]);
            if (! (static::$memo['any'] ?? false)) {
                Cache::forever('photo_files.any', true);
                static::$memo['any'] = true;
            }
        }
        static::$memo['place'][$disk.'|'.$path] = $place;
    }

    public static function forget(string $disk, string $path): void
    {
        if (static::any()) {
            PhotoFile::where('disk', $disk)->where('path', $path)->delete();
            static::$memo['place'][$disk.'|'.$path] = 'server';
        }
    }

    /** A link for a bucket photo: valid for some hours, made again each time a page shows it. */
    public static function link(string $slot, string $key, int $hours = 6): string
    {
        $fs = static::fs($slot);
        if (static::$fake) {
            return url('/photo-storage/fake/'.$slot.'/'.$key);
        }

        return $fs->temporaryUrl($key, now()->addHours($hours));
    }

    /** Upload, read back and delete a small file. */
    public static function test(string $slot): array
    {
        $b = static::bucket($slot);
        if (! static::driverReady()) {
            return [false, 'The S3 driver is not installed yet. On the server run: composer require league/flysystem-aws-s3-v3'];
        }
        if (! $b->isSet()) {
            return [false, 'Put the bucket details first.'];
        }
        static::$memo['fs'] = [];
        $key = 'wmsv2-test/'.Str::uuid().'.txt';
        $body = 'Photo storage test '.now()->toIso8601String();
        try {
            $fs = static::fs($slot);
            $fs->put($key, $body);
            $back = $fs->get($key);
            $fs->delete($key);
            $ok = $back === $body;
            $msg = $ok ? 'Uploaded, read and deleted a test file.' : 'The test file came back different.';
        } catch (\Throwable $e) {
            $ok = false;
            $msg = static::why($e);
        }
        $b->forceFill(['test_ok' => $ok, 'test_message' => Str::limit($msg, 250, ''), 'tested_at' => now()])->save();
        static::$memo['bucket'] = [];

        return [$ok, $msg];
    }

    /** A clear reason from an S3 error. */
    public static function why(\Throwable $e): string
    {
        $all = $e->getMessage().' '.($e->getPrevious()?->getMessage() ?? '');

        return match (true) {
            str_contains($all, 'InvalidAccessKeyId') => 'The Access key ID is wrong.',
            str_contains($all, 'SignatureDoesNotMatch') => 'The Secret access key is wrong.',
            str_contains($all, 'NoSuchBucket') => 'There is no bucket with this name.',
            str_contains($all, 'AccessDenied') || str_contains($all, '403') => 'Access denied: the API token needs Object Read & Write on this bucket.',
            str_contains($all, 'Could not resolve host') || str_contains($all, 'cURL error 6') => 'The Account ID or endpoint is wrong (the address cannot be found).',
            str_contains($all, 'timed out') || str_contains($all, 'cURL error 28') => 'No answer from the bucket (timed out). Try again.',
            default => 'Could not connect: '.Str::limit(trim(preg_replace('/\s+/', ' ', $all)), 160),
        };
    }

    /** Last 7 days: photos saved to a bucket, photos that stayed on the server because the bucket did not answer. */
    public static function stats(): array
    {
        if (! static::ready()) {
            return ['bucket' => 0, 'server' => 0];
        }
        $q = PhotoFile::where('created_at', '>=', now()->subDays(7));

        return ['bucket' => (clone $q)->whereIn('place', ['tmp', 'real'])->count(), 'server' => (clone $q)->where('place', 'server')->whereNotNull('note')->count()];
    }

    public static function countIn(string $place): int
    {
        return static::ready() ? PhotoFile::where('place', $place)->where('disk', '!=', 'old')->count() : 0;
    }

    public static function queueSeen(): ?int
    {
        return Cache::get('photos.queue.seen');
    }

    public static function scheduleSeen(): ?int
    {
        return Cache::get('photos.schedule.seen');
    }

    public static function workerOn(): bool
    {
        return (static::queueSeen() ?? 0) > now()->subMinutes(5)->timestamp;
    }

    public static function schedulerOn(): bool
    {
        return (static::scheduleSeen() ?? 0) > now()->subMinutes(3)->timestamp;
    }
}
DISPATCH_FILE_END_4

# ---------------------------------------------------------------- resources/views/filament/shared/box-photos.blade.php
mkdir -p 'resources/views/filament/shared'
cat > 'resources/views/filament/shared/box-photos.blade.php' <<'DISPATCH_FILE_END_5'
@php
    $condColor = ['good' => 'ok', 'damaged' => 'bad', 'wet' => 'wet', 'open' => 'warn'];
@endphp
<x-filament-panels::page>
    <div class="ds-bp" wire:key="bp-{{ md5($q.'|'.$place.'|'.$cond.'|'.implode(',', array_keys($viewer))) }}"
         x-data="{
            {{-- Part 46: the photos come from the data block below, read again after every search (never an old list) --}}
            _raw: null, _items: {},
            get items() { const t = this.$refs.bpdata?.textContent || '{}'; if (t !== this._raw) { this._raw = t; try { this._items = JSON.parse(t) } catch (e) { this._items = {} } } return this._items },
            cur: null, open: false, zoom: 1, playing: null, picking: false,
            sel: $wire.entangle('selected'),
            isSel(k) { return this.sel.includes(k) },
            toggle(k) { this.sel = this.isSel(k) ? this.sel.filter(x => x !== k) : [...this.sel, k] },
            get it() { return this.items[this.cur] || null },
            get strip() { const inv = this.it?.invoice; return Object.keys(this.items).filter(k => this.items[k].invoice === inv) },
            get pos() { return this.strip.indexOf(this.cur) + 1 },
            get selSize() { const b = this.sel.reduce((s, k) => s + (this.items[k]?.size || 0), 0); return b >= 1048576 ? (b / 1048576).toFixed(1) + ' MB' : Math.max(1, Math.round(b / 1024)) + ' KB' },
            step(d) { const s = this.strip; const i = s.indexOf(this.cur); if (s.length) { this.cur = s[(i + d + s.length) % s.length]; this.zoom = 1 } },
            show(k) { if (this.picking) { this.toggle(k); return } if (! this.items[k]) { return } this.cur = k; this.zoom = 1; this.open = true },
            close() { this.open = false; this.zoom = 1; this.play(false) },
            play(on) { clearInterval(this.playing); this.playing = null; if (on) this.playing = setInterval(() => this.step(1), 3000) },
            fit(e) { const i = e.target; if (i.naturalWidth && i.naturalHeight) { const r = Math.min(2.4, Math.max(0.5, i.naturalWidth / i.naturalHeight)); i.closest('[data-tile]').style.flex = Math.round(r * 100) + ' 1 ' + Math.round(r * 9.5) + 'rem' } },
         }"
         x-on:keydown.arrow-right.window="open && step(1)" x-on:keydown.arrow-left.window="open && step(-1)" x-on:keydown.escape.window="open && close()">
        <script type="application/json" x-ref="bpdata">{!! json_encode($viewer, JSON_HEX_TAG | JSON_HEX_AMP | JSON_UNESCAPED_UNICODE | JSON_INVALID_UTF8_SUBSTITUTE) !!}</script>

        <header class="ds-bp__head">
            <div>
                <h1>Box Photos</h1>
                <p>Every photo of every box, from container to doorstep.</p>
            </div>
            <div class="ds-bp__stats">
                <span><strong>{{ number_format($stats['week']) }}</strong><small>photos this week</small></span>
                <span class="is-bad"><strong>{{ $stats['damaged'] }}</strong><small>damaged</small></span>
                <span class="is-wet"><strong>{{ $stats['wet'] }}</strong><small>wet</small></span>
            </div>
        </header>

        {{-- Part 45 (board 72): nothing is searched while typing; Enter, 🔍 Search or the scanner (it sends Enter) starts it --}}
        <form class="ds-bp__search" x-data="{ draft: @js($q), get waiting() { return this.draft.trim() !== (this.$wire.q ?? '').trim() && this.draft.trim() !== '' } }"
              x-init="$watch('$wire.q', (v) => draft = v ?? '')" x-on:submit.prevent="$wire.searchFor(draft)" role="search">
            <x-filament::icon icon="heroicon-o-magnifying-glass" class="h-5 w-5" />
            <input type="search" x-model="draft" enterkeyhint="search" placeholder="Invoice, container or trip number…" autocomplete="off" autofocus aria-label="Search box photos">
            <span class="rounded-lg bg-[#fff6d6] px-2.5 py-1 text-[0.75rem] font-bold whitespace-nowrap text-[#8a6400]" x-show="waiting" x-cloak>Press Enter to search</span>
            @if ($q !== '')
                <button type="button" x-on:click="draft = ''; $wire.clearSearch()" class="ds-bp__clear" aria-label="Clear search">✕</button>
            @endif
            <span class="ds-bp__hint" x-show="! waiting">Type or scan</span>
            <button type="submit" class="h-10 shrink-0 rounded-xl px-4 text-[0.85rem] font-extrabold transition"
                    x-bind:class="draft.trim().length >= 3 ? 'bg-[#0e2433] text-white dark:bg-white dark:text-[#0e2433]' : 'bg-black/5 text-black/35 dark:bg-white/10 dark:text-white/40'">🔍 Search</button>
        </form>

        @if ($match === 'short')
            <section class="ds-bp__empty">
                <span class="grid size-12 place-items-center rounded-full bg-[#fff6d6] text-xl text-[#8a6400]">↵</span>
                <h2>Type at least 3 letters or numbers</h2>
                <p>Short searches would show almost every box. Finish the number, then press Enter.</p>
            </section>
        @elseif (trim($q) === '')
            <section class="ds-bp__empty">
                <span class="ds-bp__empty-icon"><x-filament::icon icon="heroicon-o-magnifying-glass" class="h-8 w-8" /></span>
                <h2>Search a box to see its photos</h2>
                <p>Type or scan an invoice, container or trip number, then press Enter. Photos stay hidden until you search.</p>
                @if ($recent)
                    <div class="ds-bp__recent">
                        <span>Recent</span>
                        @foreach ($recent as $r)
                            <button type="button" wire:click="searchFor(@js($r))">{{ $r }}</button>
                        @endforeach
                    </div>
                @endif
            </section>

            @if ($emails->isNotEmpty())
                <section class="ds-bp__panel">
                    <h3>Sent emails</h3>
                    <ul class="ds-bp__mails">
                        @foreach ($emails as $e)
                            <li>
                                <strong>{{ implode(', ', $e->recipients) }}</strong>
                                <span>{{ count($e->photo_ids) }} photos · {{ $e->status === 'sent' ? 'Sent' : 'Not sent' }}</span>
                                <small>{{ $e->user?->full_name }} · {{ $e->created_at->diffForHumans() }}</small>
                            </li>
                        @endforeach
                    </ul>
                </section>
            @endif
        @else
            <div class="ds-bp__pills" role="group" aria-label="Filters">
                <button type="button" wire:click="$set('place', '')" @class(['is-on' => $place === ''])>All places</button>
                @foreach ($places as $key => $label)
                    <button type="button" wire:click="$set('place', '{{ $key }}')" @class(['is-on' => $place === $key])>{{ $label }}</button>
                @endforeach
                <span class="ds-bp__sep" aria-hidden="true"></span>
                <button type="button" wire:click="$set('cond', '')" @class(['is-on' => $cond === ''])>Any condition</button>
                @foreach ($conditions as $key => $label)
                    <button type="button" wire:click="$set('cond', '{{ $key }}')" @class(['is-on' => $cond === $key])><i @class(['ds-bp__dot', 'is-'.$condColor[$key]])></i>{{ $label }}</button>
                @endforeach
            </div>

            @if ($boxes->isEmpty())
                <section class="ds-bp__empty is-small">
                    <h2>No photos found for “{{ $q }}”</h2>
                    <p>Check the number, or clear the filters. Photos appear here when staff add them while scanning, and when drivers deliver.</p>
                </section>
            @else
                {{-- Board 71: the photos as a gallery (rows that follow each photo), by box or all photos by day --}}
                <div class="flex flex-wrap items-center justify-between gap-3">
                    <p class="ds-bp__count">@if ($match)<span @class(['mr-1.5 rounded-full px-2 py-0.5 text-[0.7rem] font-extrabold', 'bg-[#fff6d6] text-[#8a6400]' => $match === 'like', 'bg-emerald-500/12 text-emerald-700 dark:text-emerald-300' => $match !== 'like'])>{{ ['exact' => 'Exact box', 'trip' => 'Trip', 'container' => 'Container', 'like' => 'Similar numbers'][$match] ?? '' }}</span>@endif{{ $boxes->count() }} {{ str('box')->plural($boxes->count()) }} · {{ $photoCount }} {{ str('photo')->plural($photoCount) }} · newest first</p>
                    <div class="flex items-center gap-2">
                        <span class="flex h-9 rounded-full bg-(--bp-surf) p-0.5 shadow-[inset_0_0_0_1px_var(--bp-line)]" role="group" aria-label="How to show the photos">
                            <button type="button" wire:click="$set('arrange', 'box')" @class(['rounded-full px-4 text-[0.8rem] font-bold', 'bg-(--bp-pill-on) text-(--bp-pill-on-text)' => $arrange !== 'all', 'text-(--bp-text)' => $arrange === 'all'])>By box</button>
                            <button type="button" wire:click="$set('arrange', 'all')" @class(['rounded-full px-4 text-[0.8rem] font-bold', 'bg-(--bp-pill-on) text-(--bp-pill-on-text)' => $arrange === 'all', 'text-(--bp-text)' => $arrange !== 'all'])>All photos</button>
                        </span>
                        <button type="button" x-on:click="picking = ! picking" class="h-9 rounded-full px-4 text-[0.8rem] font-extrabold transition"
                                x-bind:class="picking ? 'bg-(--bp-gold) text-[#0e2433]' : 'bg-(--bp-surf) text-(--bp-text) shadow-[inset_0_0_0_1px_var(--bp-line)]'"
                                x-text="picking ? 'Done' : '☑ Select'"></button>
                    </div>
                </div>

                @if ($arrange === 'all')
                    <div class="flex flex-col gap-5">
                        @foreach ($days as $day => $list)
                            <section class="flex flex-col gap-2" wire:key="day-{{ $day }}">
                                <h3 class="m-0 flex items-baseline gap-2 text-[0.95rem] font-extrabold">{{ $day }} <small class="text-[0.78rem] font-semibold text-(--bp-muted)">{{ $list->count() }} {{ str('photo')->plural($list->count()) }}</small></h3>
                                <div class="flex flex-wrap gap-2">
                                    @foreach ($list as $i)
                                        @include('filament.partials.box-photo-thumb', ['key' => $i['key'], 'i' => $i])
                                    @endforeach
                                    <span class="grow-[1000]" aria-hidden="true"></span>
                                </div>
                            </section>
                        @endforeach
                    </div>
                @else
                    <div class="flex flex-col gap-3.5">
                        @foreach ($boxes as $b)
                            @php($inv = $b['invoice'])
                            @php($scan = $b['items']->where('kind', 'scan'))
                            <article class="ds-bp__box" wire:key="box-{{ $inv->id }}">
                                <button type="button" class="ds-bp__boxhead" x-on:click="show(@js($b['items']->keys()->last()))">
                                    <span class="ds-bp__inv">{{ $inv->invoice }}</span>
                                    @if ($b['worst'])
                                        <span @class(['ds-bp__chip', 'is-'.$condColor[$b['worst']]])>{{ $conditions[$b['worst']] }}</span>
                                    @endif
                                    @if ($b['delivered'])
                                        <span class="ds-bp__chip is-ok">Delivered</span>
                                    @endif
                                    <span class="ds-bp__n">{{ $b['items']->count() }} {{ str('photo')->plural($b['items']->count()) }}</span>
                                    <span class="ds-bp__who">{{ collect([$inv->receiver_name, $inv->receiver_barangay, $inv->receiver_city])->filter()->map(fn ($p) => \Illuminate\Support\Str::title($p))->join(' · ') }}</span>
                                </button>

                                {{-- Part 45 (board 73): email or download the photos of this box in one tap --}}
                                <div class="flex flex-wrap gap-2">
                                    <button type="button" class="inline-flex h-9 items-center gap-1.5 rounded-full bg-[#f6be00] px-4 text-[0.8rem] font-extrabold text-[#0e2433]"
                                            x-on:click="$wire.mountAction('email', { keys: @js($b['items']->keys()->values()) })">✉ Email photos</button>
                                    <button type="button" class="inline-flex h-9 items-center gap-1.5 rounded-full bg-(--bp-raised) px-4 text-[0.8rem] font-bold text-(--bp-text) shadow-[inset_0_0_0_1px_var(--bp-line)]"
                                            x-on:click="$wire.downloadSelected(@js($b['items']->keys()->values()))">↓ Download</button>
                                </div>

                                <ol class="ds-bp__journey" aria-label="Where this box has been">
                                    @foreach ($b['journey'] as $j)
                                        @php($tone = $j['kind'] === 'delivered' ? ($j['condition'] === 'damaged' ? 'bad' : 'ok') : ($j['kind'] === 'not_delivered' ? 'warn' : ($condColor[$j['condition']] ?? 'none')))
                                        <li><i @class(['ds-bp__dot', 'is-'.$tone])></i>{{ $j['label'] }}{{ $j['kind'] === 'delivered' && $j['condition'] === 'damaged' ? ' · damaged' : '' }}</li>
                                    @endforeach
                                </ol>

                                @if ($scan->isNotEmpty())
                                    <div class="flex flex-col gap-2 rounded-2xl bg-(--bp-raised) p-2.5">
                                        <span class="flex items-center gap-2 px-0.5 text-[0.82rem]"><b>Scan photos</b><small class="text-(--bp-muted)">{{ $scan->count() }} {{ str('photo')->plural($scan->count()) }} · warehouse and hub</small></span>
                                        <div class="flex flex-wrap gap-2">
                                            @foreach ($scan as $key => $i)
                                                @include('filament.partials.box-photo-thumb', ['key' => $key, 'i' => $i])
                                            @endforeach
                                            <span class="grow-[1000]" aria-hidden="true"></span>
                                        </div>
                                    </div>
                                @endif

                                @foreach ($b['attempts'] as $a)
                                    <div class="ds-bp__card is-warn">
                                        <div class="ds-bp__cardhead">
                                            <span class="ds-bp__badge">!</span>
                                            <span><strong>Not delivered · {{ $a['reason'] }}</strong><small>{{ $a['at']?->format('d M Y · g:i A') }} · {{ $a['who'] ?? 'Driver' }}{{ $a['trip'] ? ' · Trip '.$a['trip'] : '' }}</small></span>
                                            <em>{{ count($a['keys']) }} {{ str('photo')->plural(count($a['keys'])) }}</em>
                                        </div>
                                        @if ($a['note'])<p class="ds-bp__cardnote">“{{ $a['note'] }}”</p>@endif
                                        @if ($a['keys'])
                                            <div class="flex flex-wrap gap-2">
                                                @foreach ($a['keys'] as $key)
                                                    @include('filament.partials.box-photo-thumb', ['key' => $key, 'i' => $b['items'][$key]])
                                                @endforeach
                                                <span class="grow-[1000]" aria-hidden="true"></span>
                                            </div>
                                        @endif
                                    </div>
                                @endforeach

                                @if ($d = $b['delivered'])
                                    <div class="ds-bp__card is-ok">
                                        <div class="ds-bp__cardhead">
                                            <span class="ds-bp__badge">✓</span>
                                            <span><strong>Delivered{{ ($d['signed']['damaged'] ?? false) ? ' · damaged' : '' }}</strong><small>{{ $d['at']?->format('d M Y · g:i A') }} · {{ $d['who'] ?? 'Driver' }}{{ $d['to'] ? ' · to '.\Illuminate\Support\Str::title($d['to']) : '' }}{{ $d['trip'] ? ' · Trip '.$d['trip'] : '' }}</small></span>
                                            <em>{{ count($d['keys']) }} {{ str('photo')->plural(count($d['keys'])) }}</em>
                                        </div>
                                        @if ($sg = $d['signed'] ?? null)
                                            <div class="flex flex-wrap items-center gap-x-3 gap-y-1 px-1 text-[0.8rem]">
                                                <span>✍ Signed on the phone by <b>{{ \Illuminate\Support\Str::title($sg['by']) }}</b>{{ $sg['rel'] ? ' ('.strtolower($sg['rel']).')' : '' }}{{ $sg['cant'] ? ' · could not sign' : '' }}</span>
                                                @if ($sg['damaged'])<span @class(['ds-bp__chip', 'is-bad'])>Damaged: {{ $sg['damage'] }}</span>@endif
                                                @if ($sg['paper'])<span class="text-(--bp-muted)">No paper receipt: {{ strtolower($sg['paper']) }}</span>@endif
                                                <a href="{{ $sg['link'] }}" target="_blank" rel="noopener" class="font-bold underline">📄 Signed receipt (PDF)</a>
                                            </div>
                                        @endif
                                        @if ($d['keys'])
                                            <div class="flex flex-wrap gap-2">
                                                @foreach ($d['keys'] as $key)
                                                    @include('filament.partials.box-photo-thumb', ['key' => $key, 'i' => $b['items'][$key]])
                                                @endforeach
                                                <span class="grow-[1000]" aria-hidden="true"></span>
                                            </div>
                                        @else
                                            <p class="ds-bp__cardnote">No delivery photo was taken.</p>
                                        @endif
                                    </div>
                                @endif
                            </article>
                        @endforeach
                    </div>
                @endif

                {{-- Board 71 C: full-screen viewer with a strip of the box's photos, slideshow, zoom, download --}}
                <div class="fixed inset-0 z-[60] flex flex-col bg-[#05090d] text-[#eef3f6]" x-show="open" x-cloak x-transition.opacity
                     x-effect="document.documentElement.style.overflow = open ? 'hidden' : ''" role="dialog" aria-modal="true" aria-label="Photo">
                    <div class="flex flex-wrap items-center gap-2 px-4 py-3 sm:px-6">
                        <span class="flex min-w-0 flex-1 flex-col">
                            <strong class="truncate text-[0.98rem]" x-text="it?.title"></strong>
                            <small class="truncate text-[0.78rem] text-white/65" x-text="[it?.ref, it?.when, it?.who].filter(Boolean).join(' · ')"></small>
                        </span>
                        <span class="ds-bp__chip" x-show="it?.condLabel" x-text="it?.condLabel" x-bind:class="{ 'is-ok': it?.cond === 'good', 'is-bad': it?.cond === 'damaged', 'is-wet': it?.cond === 'wet', 'is-warn': it?.cond === 'open' }"></span>
                        <span class="rounded-full bg-white/10 px-3 py-1 text-[0.75rem] font-extrabold tabular-nums" x-text="pos + ' / ' + strip.length"></span>
                        <button type="button" class="grid size-10 place-items-center rounded-full bg-white/10 hover:bg-white/20" x-on:click="zoom = zoom >= 2.5 ? 1 : zoom + 0.75" aria-label="Zoom">🔍</button>
                        <button type="button" class="h-10 rounded-full px-4 text-[0.8rem] font-extrabold" x-show="strip.length > 1" x-on:click="play(! playing)"
                                x-bind:class="playing ? 'bg-(--bp-gold) text-[#0e2433]' : 'bg-white/10 hover:bg-white/20'" x-text="playing ? '❚❚ Pause' : '▶ Slideshow'"></button>
                        <a class="grid size-10 place-items-center rounded-full bg-white/10 hover:bg-white/20" x-bind:href="it?.dl" x-bind:download="it?.name" aria-label="Download">⬇</a>
                        <button type="button" class="h-10 rounded-full bg-[#f6be00] px-4 text-[0.8rem] font-extrabold text-[#0e2433]" x-on:click="const k = cur; close(); $wire.mountAction('email', { keys: [k] })">✉ Email this photo</button>
                        <button type="button" class="h-10 rounded-full px-4 text-[0.8rem] font-extrabold" x-on:click="toggle(cur)"
                                x-bind:class="isSel(cur) ? 'bg-(--bp-gold) text-[#0e2433]' : 'bg-white/10 hover:bg-white/20'" x-text="isSel(cur) ? '✓ Selected' : 'Select'"></button>
                        <button type="button" class="grid size-10 place-items-center rounded-full bg-white/10 hover:bg-white/20" x-on:click="close()" aria-label="Close">✕</button>
                    </div>
                    <div class="relative flex min-h-0 flex-1 items-center justify-center overflow-hidden px-3 sm:px-16"
                         x-data="{ sx: null }" x-on:touchstart="sx = $event.touches[0].clientX" x-on:touchend="if (sx !== null && zoom === 1) { const dx = $event.changedTouches[0].clientX - sx; if (Math.abs(dx) > 60) step(dx < 0 ? 1 : -1) } sx = null">
                        <span class="absolute inset-0 grid place-items-center text-sm text-white/50" aria-hidden="true">Loading photo…</span>
                        <img x-bind:src="it?.src" x-bind:alt="it?.name" x-on:dblclick="zoom = zoom > 1 ? 1 : 2.5"
                             class="relative max-h-full max-w-full select-none object-contain transition-transform duration-200" x-bind:style="'transform: scale(' + zoom + ')'" x-bind:class="zoom > 1 ? 'cursor-zoom-out' : 'cursor-zoom-in'">
                        <button type="button" class="absolute left-3 top-1/2 grid size-12 -translate-y-1/2 place-items-center rounded-full bg-white/12 text-2xl hover:bg-white/25" x-show="strip.length > 1" x-on:click="step(-1)" aria-label="Previous photo">‹</button>
                        <button type="button" class="absolute right-3 top-1/2 grid size-12 -translate-y-1/2 place-items-center rounded-full bg-white/12 text-2xl hover:bg-white/25" x-show="strip.length > 1" x-on:click="step(1)" aria-label="Next photo">›</button>
                        <span class="absolute inset-x-0 bottom-0 h-1 bg-white/10" x-show="playing"><span class="block h-full w-full origin-left animate-pulse bg-(--bp-gold)"></span></span>
                    </div>
                    <blockquote class="mx-4 my-0 rounded-lg border-l-3 border-(--bp-gold) bg-white/6 px-3 py-2 text-[0.85rem] italic sm:mx-6" x-show="it?.note" x-text="it?.note"></blockquote>
                    <div class="flex gap-2 overflow-x-auto px-4 py-3 sm:px-6" x-show="strip.length > 1">
                        <template x-for="k in strip" x-bind:key="k">
                            <button type="button" x-on:click="cur = k; zoom = 1" class="h-14 w-20 shrink-0 overflow-hidden rounded-md transition"
                                    x-bind:class="k === cur ? 'opacity-100 ring-3 ring-(--bp-gold)' : 'opacity-45 hover:opacity-80'"><img x-bind:src="items[k].src" alt="" class="size-full object-cover" loading="lazy"></button>
                        </template>
                    </div>
                    <div class="flex items-center justify-between gap-3 border-t border-white/10 px-4 py-2.5 text-[0.75rem] text-white/55 sm:px-6">
                        <span class="truncate font-mono" x-text="it?.name"></span>
                        <span class="hidden sm:inline">Swipe or ‹ › · double-tap or 🔍 to zoom · Esc to close</span>
                        @if (auth()->user()?->hasRole('super_admin'))
                            <button type="button" class="text-(--bp-bad) underline" x-show="it?.scan" x-on:click="close(); $wire.mountAction('delete', { key: cur })">Delete this photo</button>
                        @endif
                    </div>
                </div>
            @endif
        @endif

        <div class="ds-bp__dock" x-show="sel.length" x-cloak x-transition.opacity>
            <span class="ds-bp__dockn" x-text="sel.length"></span>
            <span class="ds-bp__docktext"><strong x-text="sel.length === 1 ? '1 photo selected' : sel.length + ' photos selected'"></strong><small x-text="'about ' + selSize"></small></span>
            <button type="button" class="is-ghost" x-on:click="sel = []">Clear</button>
            <button type="button" class="is-dark" wire:click="downloadSelected"><span x-text="sel.length > 1 ? '↓ Download ZIP' : '↓ Download'"></span></button>
            {{ $this->emailAction }}
        </div>
    </div>

    <x-filament-actions::modals />
</x-filament-panels::page>
DISPATCH_FILE_END_5

# ---------------------------------------------------------------- tests/Feature/PhotoGalleryTest.php
mkdir -p 'tests/Feature'
cat > 'tests/Feature/PhotoGalleryTest.php' <<'DISPATCH_FILE_END_6'
<?php

use App\Filament\Company\Pages\BoxPhotos as CompanyBoxPhotos;
use App\Filament\Pages\BoxPhotos;
use App\Filament\Warehouse\Pages\BoxPhotos as WarehouseBoxPhotos;
use App\Models\Container;
use App\Models\Invoice;
use App\Models\User;
use App\Support\Photos\BoxPhotos as Photos;
use Database\Seeders\DemoSeeder;
use Filament\Facades\Filament;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Illuminate\Http\UploadedFile;
use Illuminate\Support\Facades\Storage;
use Livewire\Livewire;

uses(RefreshDatabase::class);

beforeEach(function () {
    $this->seed(DemoSeeder::class);
    Storage::fake('local');
    Storage::fake('box');
    Filament::setCurrentPanel(Filament::getPanel('admin'));
    $this->admin = User::where('email', 'admin@example.com')->firstOrFail();
    $this->actingAs($this->admin);
    $this->container = Container::firstOrFail();
    $this->box = Invoice::where('container_id', $this->container->id)->firstOrFail();
    $this->photo = fn (string $step, ?string $cond = null) => Photos::store(UploadedFile::fake()->image('p.jpg', 640, 360), $step, $this->box,
        ['container_id' => $this->box->container_id], User::first(), $cond);
});

it('keeps the Box Photos look and shows the photos as a gallery by box', function () {
    $a = ($this->photo)('unload', 'damaged');
    $b = ($this->photo)('load');

    Livewire::test(BoxPhotos::class)
        ->assertSee('Every photo of every box, from container to doorstep.')->assertSee('Type or scan')
        ->set('q', $this->box->invoice)
        ->assertSee('All places')->assertSee('Any condition')
        ->assertSee('By box')->assertSee('All photos')->assertSee('Scan photos')
        ->assertSeeHtml('data-tile')->assertSeeHtml('[flex:133_1_12.5rem]')
        ->assertSee('Open '.$a->fileName())->assertSee('Open '.$b->fileName())
        ->assertSee('▶ Slideshow')->assertSee('Delete this photo');
});

it('shows all photos in one gallery, grouped by day', function () {
    $a = ($this->photo)('unload');
    $a->update(['taken_at' => now()->subDays(2)]);
    $b = ($this->photo)('load');

    Livewire::test(BoxPhotos::class)->set('q', $this->box->invoice)->set('arrange', 'all')
        ->assertSet('arrange', 'all')->assertDontSee('Scan photos')
        ->assertSee('Today · '.now()->format('D d M Y'))->assertSee(now()->subDays(2)->format('D d M Y'))
        ->assertSee('Open '.$a->fileName())->assertSee('Open '.$b->fileName());
});

it('uses the same gallery in the warehouse and company panels', function () {
    expect(is_subclass_of(WarehouseBoxPhotos::class, \App\Filament\Shared\BoxPhotosPage::class))->toBeTrue()
        ->and(is_subclass_of(CompanyBoxPhotos::class, \App\Filament\Shared\BoxPhotosPage::class))->toBeTrue();
});

it('gives the full-screen viewer a strip, a slideshow and download in galleries', function () {
    $js = file_get_contents(resource_path('js/photo-viewer.js'));
    expect($js)->toContain('dspv__strip')->toContain('▶ Slideshow')->toContain('⬇ Save');
});

it('reads the photo list again after every search, so the viewer never shows an empty photo', function () {
    ($this->photo)('unload');
    Livewire::test(BoxPhotos::class)->call('searchFor', $this->box->invoice)
        ->assertSeeHtml('x-ref="bpdata"')->assertSeeHtml('get items()')->assertSee('Loading photo…');
});
DISPATCH_FILE_END_6

# ---------------------------------------------------------------- tests/Feature/PhotoStorageTest.php
mkdir -p 'tests/Feature'
cat > 'tests/Feature/PhotoStorageTest.php' <<'DISPATCH_FILE_END_7'
<?php

use App\Filament\Pages\PhotoStorage;
use App\Models\AppSetting;
use App\Models\Photos\PhotoFile;
use App\Models\Photos\PhotoTask;
use App\Models\User;
use App\Support\Photos\Storage\OldSystem;
use App\Support\Photos\Storage\PhotoStore;
use App\Support\Photos\Storage\PhotoWork;
use Database\Seeders\DemoSeeder;
use Filament\Facades\Filament;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Illuminate\Http\UploadedFile;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\File;
use Illuminate\Support\Facades\Storage;
use Livewire\Livewire;

uses(RefreshDatabase::class);

beforeEach(function () {
    $this->seed(DemoSeeder::class);
    $this->admin = User::where('email', 'admin@example.com')->firstOrFail();
    $this->actingAs($this->admin);
    Filament::setCurrentPanel(Filament::getPanel('admin'));
    PhotoStore::$fake = true;
    PhotoStore::forgetMemo();
    $this->root = storage_path('framework/testing/photostore-'.getmypid());
    File::deleteDirectory($this->root);
    // the server folders behind the routed disks, in a test folder
    config(['filesystems.disks.public.inner.root' => $this->root.'/public', 'filesystems.disks.box.inner.root' => $this->root.'/private']);
    Storage::forgetDisk(['public', 'box']);
    File::deleteDirectory(storage_path('framework/testing/buckets'));
});

afterEach(function () {
    PhotoStore::$fake = false;
    File::deleteDirectory($this->root);
    File::deleteDirectory(storage_path('framework/testing/buckets'));
});

function bucketOn(string $slot = 'tmp', string $name = 'negosmart'): void
{
    PhotoStore::bucket($slot)->fill(['provider' => 'r2', 'account_id' => 'acc123', 'bucket' => $name, 'access_key' => 'key', 'secret' => 's3cret'])->save();
    PhotoStore::forgetMemo();
    expect(PhotoStore::test($slot)[0])->toBeTrue();
    PhotoStore::forgetMemo();
}

it('saves on the server like before until a bucket is chosen', function () {
    Storage::disk('public')->put('shipments/a.jpg', 'AAA');
    expect(File::exists($this->root.'/public/shipments/a.jpg'))->toBeTrue()
        ->and(PhotoFile::count())->toBe(0)
        ->and(Storage::disk('public')->url('shipments/a.jpg'))->toEndWith('/storage/shipments/a.jpg');
});

it('saves new photos of every disk to the chosen bucket and keeps old ones opening', function () {
    Storage::disk('public')->put('fuel/old.jpg', 'OLD');
    bucketOn();
    PhotoStore::setTarget('tmp');
    PhotoStore::forgetMemo();

    Storage::disk('public')->put('fuel/new.jpg', 'NEW');
    Storage::disk('box')->put('box-photos/2026/11/x.jpg', 'BOX');
    Storage::disk('public')->put('logo/company.png', 'LOGO'); // logos stay on the server

    expect(File::exists($this->root.'/public/fuel/new.jpg'))->toBeFalse()
        ->and(PhotoFile::where('place', 'tmp')->pluck('path')->sort()->values()->all())->toBe(['box-photos/2026/11/x.jpg', 'fuel/new.jpg'])
        ->and(Storage::disk('public')->get('fuel/new.jpg'))->toBe('NEW')
        ->and(Storage::disk('public')->get('fuel/old.jpg'))->toBe('OLD')
        ->and(Storage::disk('box')->get('box-photos/2026/11/x.jpg'))->toBe('BOX')
        ->and(Storage::disk('public')->exists('fuel/new.jpg'))->toBeTrue()
        ->and(Storage::disk('public')->url('fuel/new.jpg'))->toContain('/photo-storage/fake/tmp/fuel/new.jpg')
        ->and(File::exists($this->root.'/public/logo/company.png'))->toBeTrue();

    // a file upload (Filament / Livewire) goes the same way
    Storage::disk('public')->putFileAs('unmanifested', UploadedFile::fake()->image('p.jpg'), 'p.jpg');
    expect(PhotoStore::placeOf('public', 'unmanifested/p.jpg'))->toBe('tmp');

    Storage::disk('public')->delete('fuel/new.jpg');
    expect(PhotoFile::where('path', 'fuel/new.jpg')->exists())->toBeFalse();
});

it('keeps the photo on the server when the bucket does not answer', function () {
    bucketOn();
    PhotoStore::setTarget('tmp');
    PhotoStore::bucket('tmp')->update(['bucket' => '']); // broken details: not usable
    PhotoStore::forgetMemo();
    Storage::disk('public')->put('fuel/z.jpg', 'Z');
    expect(File::exists($this->root.'/public/fuel/z.jpg'))->toBeTrue();
});

it('moves the server photos, then switches to the real bucket and turns Temporary off', function () {
    Storage::disk('public')->put('shipments/1.jpg', 'ONE');
    Storage::disk('box')->put('box-photos/2026/11/2.jpg', 'TWO');
    bucketOn();
    PhotoStore::setTarget('tmp');
    PhotoStore::forgetMemo();

    $move = PhotoWork::startMove('tmp');
    expect($move->total)->toBe(2);
    PhotoWork::work(10);
    expect($move->fresh()->status)->toBe('done')
        ->and(File::exists($this->root.'/public/shipments/1.jpg'))->toBeFalse()
        ->and(Storage::disk('public')->get('shipments/1.jpg'))->toBe('ONE')
        ->and(Storage::disk('box')->get('box-photos/2026/11/2.jpg'))->toBe('TWO');

    bucketOn('real', 'icargo-photos');
    $sw = PhotoWork::startSwitch(true);
    PhotoWork::work(10);
    PhotoStore::forgetMemo();
    expect($sw->fresh()->status)->toBe('done')
        ->and(PhotoStore::target())->toBe('real')
        ->and(PhotoStore::countIn('tmp'))->toBe(0)
        ->and(PhotoStore::bucket('tmp')->is_off)->toBeTrue()
        ->and(Storage::disk('public')->get('shipments/1.jpg'))->toBe('ONE')
        ->and(PhotoStore::placeOf('box', 'box-photos/2026/11/2.jpg'))->toBe('real');
});

it('copies the old system photos with the same path, smaller, and skips what is there', function () {
    // the old site next to wmsv2, same database
    $old = $this->root.'/wms';
    File::ensureDirectoryExists($old.'/storage/app/public/photos/pod');
    File::put($old.'/artisan', '');
    $c = config('database.connections.'.config('database.default'));
    File::put($old.'/.env', "APP_URL=https://wms.example.test\nDB_HOST=".($c['host'] ?? '')."\nDB_DATABASE=".($c['database'] ?? '')."\n");
    $im = imagecreatetruecolor(2400, 1600); // noise: a big photo
    for ($i = 0; $i < 60000; $i++) {
        imagefilledrectangle($im, $x = random_int(0, 2390), $y = random_int(0, 1590), $x + 9, $y + 9, random_int(0, 0xFFFFFF));
    }
    ob_start();
    imagejpeg($im, null, 95);
    $img = (string) ob_get_clean();
    expect(strlen($img))->toBeGreaterThan(400 * 1024);
    File::put($old.'/storage/app/public/photos/pod/INV-1.jpg', $img);
    AppSetting::put('photos.old_folder', $old);
    DB::table('fuel_fills')->exists() || true;
    $u = User::first();
    DB::table('users')->where('id', $u->id)->update(['profile_picture' => 'photos/pod/INV-1.jpg']);
    DB::table('users')->where('id', '!=', $u->id)->limit(1)->update(['profile_picture' => 'photos/pod/GONE.jpg']);

    $find = OldSystem::find();
    expect($find['found'])->toBeTrue()->and($find['same'])->toBeTrue()
        ->and(OldSystem::columns()->firstWhere('column', 'profile_picture'))->not->toBeNull();

    bucketOn();
    $task = OldSystem::scan();
    $byPath = $task->items()->get()->keyBy('path');
    expect($byPath['photos/pod/INV-1.jpg']->found)->toBe('wms')
        ->and($byPath['photos/pod/GONE.jpg']->status)->toBe('missing');

    $task->update(['status' => 'running']);
    PhotoWork::work(15);
    $task->refresh();
    $item = $task->items()->where('path', 'photos/pod/INV-1.jpg')->first();
    // put in the new folders (board 67): people/…, and the record now points there
    expect($task->status)->toBe('done')->and($item->status)->toBe('done')->and($item->checked)->toBeTrue()
        ->and($item->size_after)->toBeLessThan($item->size_before)
        ->and($item->new_path)->toBe('people/INV-1.jpg')
        ->and(DB::table('users')->where('id', $u->id)->value('profile_picture'))->toBe('people/INV-1.jpg')
        ->and(PhotoStore::placeOf('public', 'people/INV-1.jpg'))->toBe('tmp')
        ->and(Storage::disk('public')->exists('people/INV-1.jpg'))->toBeTrue()
        ->and(File::exists($old.'/storage/app/public/photos/pod/INV-1.jpg'))->toBeTrue(); // the old site is never touched

    // copy again: nothing new
    OldSystem::scan()->update(['status' => 'running']);
    PhotoWork::work(5);
    expect($task->fresh()->items()->where('path', 'photos/pod/INV-1.jpg')->value('status'))->toBe('done');
});

it('shows the photo storage page with its tabs and saves a bucket', function () {
    Livewire::test(PhotoStorage::class)
        ->assertSee('Setup checklist')->assertSee('Copy from the old system')
        ->call('setTab', 'bucket')->assertSee('New photos go to')->assertSee('Temporary bucket')
        ->set('form.tmp.account_id', 'acc9')->set('form.tmp.bucket', 'negosmart')->set('form.tmp.access_key', 'AK')->set('form.tmp.secret', 'SEC')
        ->call('saveBucket', 'tmp')->assertSee('Uploaded, read and deleted a test file')
        ->call('setTarget', 'tmp')
        ->call('turnOff', 'tmp')->assertSee('new photos still go here')
        ->call('setTab', 'work')->assertSee('Run here');
    expect(PhotoStore::target())->toBe('tmp')
        ->and(PhotoStore::bucket('tmp')->secret)->toBe('SEC')
        ->and(DB::table('storage_buckets')->value('secret'))->not->toBe('SEC'); // kept encrypted
});


it('saves new photos in the tidy folders, at most 200 KB', function () {
    expect(\App\Support\Photos\Storage\PhotoFolders::dir('delivery', '0144033', '2026-11-20'))->toBe('delivery/2026/11/0144033')
        ->and(\App\Support\Photos\Storage\PhotoFolders::dir('trucks', 'ABC 1234'))->toBe('trucks/ABC-1234');
    $im = imagecreatetruecolor(2000, 1500);
    for ($i = 0; $i < 40000; $i++) {
        imagefilledrectangle($im, $x = random_int(0, 1990), $y = random_int(0, 1490), $x + 9, $y + 9, random_int(0, 0xFFFFFF));
    }
    ob_start();
    imagejpeg($im, null, 92);
    $big = (string) ob_get_clean();
    Storage::disk('public')->put('delivery/2026/11/1/a.jpg', $big);
    expect(strlen(Storage::disk('public')->get('delivery/2026/11/1/a.jpg')))->toBeLessThan(strlen($big))
        ->and(strlen(Storage::disk('public')->get('delivery/2026/11/1/a.jpg')))->toBeLessThanOrEqual(320 * 1024); // pure noise; a real photo ends near 200 KB

    $box = \App\Models\Invoice::firstOrFail();
    $p = \App\Support\Photos\BoxPhotos::store(UploadedFile::fake()->image('b.jpg', 800, 600), 'unload', $box, [], $this->admin);
    expect($p->path)->toStartWith('scan/unload/'.now()->format('Y/m').'/'.$box->invoice.'/')
        ->and(Storage::disk('box')->exists($p->path))->toBeTrue();
});

it('moves the server photos into the tidy folders and changes the path in the record', function () {
    $trip = \App\Models\Tripinvoice::firstOrFail();
    Storage::disk('public')->put('0144033/pod.jpg', 'POD');
    DB::table('tripinvoices')->where('id', $trip->id)->update(['delivery_picture' => json_encode(['0144033/pod.jpg']), 'delivered_at' => '2025-08-14 10:00:00']);
    bucketOn();
    PhotoStore::setTarget('tmp');
    PhotoStore::forgetMemo();

    $move = PhotoWork::startMove('tmp', true);
    PhotoWork::work(10);
    $new = 'delivery/2025/08/'.\App\Support\Photos\Storage\PhotoFolders::clean($trip->invoice).'/pod.jpg';
    expect($move->fresh()->status)->toBe('done')
        ->and(json_decode(DB::table('tripinvoices')->where('id', $trip->id)->value('delivery_picture'), true))->toBe([$new])
        ->and(Storage::disk('public')->get($new))->toBe('POD')
        ->and(File::exists($this->root.'/public/0144033/pod.jpg'))->toBeFalse();
});

it('sends a bucket photo straight from the bucket and lists bucket photos without asking the bucket', function () {
    bucketOn();
    PhotoStore::setTarget('tmp');
    PhotoStore::forgetMemo();
    $box = \App\Models\Invoice::firstOrFail();
    $p = \App\Support\Photos\BoxPhotos::store(UploadedFile::fake()->image('b.jpg', 800, 600), 'unload', $box, [], $this->admin);
    expect(PhotoStore::placeOf('box', $p->path))->toBe('tmp');

    $r = $this->get($p->url());
    expect($r->status())->toBe(302)->and($r->headers->get('Location'))->toContain('/photo-storage/fake/tmp/');

    // a delivery photo in the bucket: shown with its link, its size from the record (no call to the bucket)
    $trip = \App\Models\Tripinvoice::where('invoice_id', $box->id)->first() ?? \App\Models\Tripinvoice::firstOrFail();
    Storage::disk('public')->put('delivery/x/pod.jpg', str_repeat('x', 2048));
    DB::table('tripinvoices')->where('id', $trip->id)->update(['delivery_picture' => json_encode(['delivery/x/pod.jpg']), 'is_delivered' => true, 'invoice_id' => $box->id]);
    PhotoStore::forgetMemo();
    $items = (new \App\Support\Photos\BoxAlbum($this->admin))->forInvoice($box->id);
    $pod = $items->firstWhere('path', 'delivery/x/pod.jpg');
    expect($pod)->not->toBeNull()->and($pod['url'])->toContain('/photo-storage/fake/tmp/');
});
DISPATCH_FILE_END_7

echo "▶ Rebuilding the design"
npm run build

echo "▶ Clearing caches"
php artisan optimize:clear

echo "▶ Running the tests"
php artisan test || echo "Some tests failed — send the red text for help."

echo
echo "✓ Done. Backup: $BACKUP"
echo "  Start the app with:  PHP_CLI_SERVER_WORKERS=4 php artisan serve   (or open https://dispatchsystem.test in Herd)"
