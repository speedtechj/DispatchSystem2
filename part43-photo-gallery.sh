#!/usr/bin/env bash
#
# Dispatch System — Part 43 · Box Photos gallery
# Only the files changed in this step; the rest of your project is left as it is.
#
#   cd ~/Desktop/Project/DispatchSystem
#   bash ~/Desktop/Project/part43-photo-gallery.sh

set -euo pipefail
[ -f artisan ] || { echo "Run this from inside your DispatchSystem project folder (the one with 'artisan')."; exit 1; }

STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="../DispatchSystem-backup-$STAMP.tar.gz"
echo "▶ Backing up the project to $BACKUP"
tar -czf "$BACKUP" --exclude=vendor --exclude=node_modules --exclude=storage/logs .

echo "▶ Writing 6 files"

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

# ---------------------------------------------------------------- public/js/app/photo-viewer.js
mkdir -p 'public/js/app'
cat > 'public/js/app/photo-viewer.js' <<'DISPATCH_FILE_END_1'
/*
 * Part 42 · Check photos (board 68), in every app.
 *
 * window.dsPhotoViewer.open(list, index, opts)  full screen: zoom (pinch, double-tap, button),
 *     swipe or ‹ › for the next, ✕ to go back. opts.onDelete(i) / opts.onRetake(i) add the buttons.
 * window.dsPhotoCheck(file, { auto })  the photo big, right after it is taken: Retake or Use photo
 *     (used by itself after `auto` seconds, 0 = wait for a tap). Resolves 'use' or 'retake'.
 * Any <img data-ds-photo> inside [data-ds-gallery] opens the viewer for that gallery on a tap.
 * While a viewer is open, the barcode scanner rests (it never reads a box behind the photo).
 */
(function () {
    if (window.dsPhotoViewer) return;

    const css = `
.dspv{position:fixed;inset:0;z-index:90;background:#05090d;color:#eef3f6;display:flex;flex-direction:column;font-family:Archivo,system-ui,sans-serif;touch-action:none;-webkit-tap-highlight-color:transparent}
.dspv__top{display:flex;align-items:center;justify-content:space-between;gap:.6rem;padding:max(.8rem,env(safe-area-inset-top)) 1rem .6rem}
.dspv__x{width:2.6rem;height:2.6rem;border-radius:99px;background:rgb(255 255 255/.12);font-size:1.15rem;color:#fff}
.dspv__pill{padding:.25rem .7rem;border-radius:99px;background:rgb(255 255 255/.12);font-size:.8rem;font-weight:800}
.dspv__stage{position:relative;flex:1;overflow:hidden;display:flex;align-items:center;justify-content:center}
.dspv__img{max-width:100%;max-height:100%;object-fit:contain;transform-origin:center;transition:transform .15s ease-out;user-select:none;-webkit-user-drag:none}
.dspv__img.is-moving{transition:none}
.dspv__nav{position:absolute;top:50%;margin-top:-1.4rem;width:2.8rem;height:2.8rem;border-radius:99px;background:rgb(0 0 0/.45);color:#fff;font-size:1.4rem}
.dspv__nav.is-prev{left:.6rem}.dspv__nav.is-next{right:.6rem}
.dspv__hint{position:absolute;left:0;right:0;bottom:.7rem;text-align:center;font-size:.75rem;color:#cfd8de;pointer-events:none}
.dspv__cd{position:absolute;top:.7rem;right:.7rem;padding:.25rem .7rem;border-radius:99px;background:rgb(0 0 0/.55);font-size:.8rem;font-weight:800}
.dspv__bar{display:grid;gap:.5rem;padding:.7rem 1rem max(1rem,env(safe-area-inset-bottom))}
.dspv__bar.is-3{grid-template-columns:repeat(3,1fr)}.dspv__bar.is-4{grid-template-columns:repeat(4,1fr)}
.dspv__strip{display:flex;gap:.45rem;overflow-x:auto;padding:.55rem 1rem 0}.dspv__strip button{flex:none;width:4.2rem;height:3.1rem;border-radius:.45rem;overflow:hidden;opacity:.45;padding:0}.dspv__strip button.is-on{opacity:1;box-shadow:0 0 0 3px #f6be00}.dspv__strip img{width:100%;height:100%;object-fit:cover}
.dspv__btn.is-on{background:#f6be00;color:#0a1219}a.dspv__btn{display:flex;align-items:center;justify-content:center;text-decoration:none}.dspv__bar.is-2{grid-template-columns:1fr 1.4fr}.dspv__bar.is-1{grid-template-columns:1fr}
.dspv__btn{height:3.3rem;border-radius:1rem;background:rgb(255 255 255/.1);color:#fff;font-weight:800;font-size:1rem}
.dspv__btn.is-use{background:#3ddc97;color:#0a1219}.dspv__btn.is-del{background:rgb(200 55 45/.28);color:#ff8a80}
[data-ds-photo]{cursor:zoom-in}`;

    let root = null;
    let keyHandler = null;
    let wasPaused = null;

    function scanner(paused) {
        window.dispatchEvent(new CustomEvent('ds-scanner', { detail: { paused } }));
    }
    /** The scanner rests while a photo is open, and goes back to how it was after. */
    function rest() {
        wasPaused = window.dsScanner ? !!window.dsScanner.paused : null;
        scanner(true);
    }

    function el(tag, cls, html) {
        const e = document.createElement(tag);
        if (cls) e.className = cls;
        if (html != null) e.innerHTML = html;
        return e;
    }

    function close() {
        if (!root) return;
        root.remove();
        root = null;
        if (keyHandler) document.removeEventListener('keydown', keyHandler);
        keyHandler = null;
        document.documentElement.style.overflow = '';
        if (wasPaused === false) scanner(false);
        wasPaused = null;
    }

    /** Pinch, drag and double-tap zoom on one image; swipe calls onSwipe(-1|1) when not zoomed. */
    function zoomable(img, stage, onSwipe, onZoom) {
        let z = 1, x = 0, y = 0;
        const pts = new Map();
        let start = null;
        let lastTap = 0;
        const apply = () => { img.style.transform = `translate(${x}px, ${y}px) scale(${z})`; onZoom && onZoom(z); };
        const set = (nz) => { z = Math.min(4, Math.max(1, nz)); if (z === 1) { x = 0; y = 0; } apply(); };
        stage.addEventListener('pointerdown', (e) => {
            stage.setPointerCapture && stage.setPointerCapture(e.pointerId);
            pts.set(e.pointerId, { x: e.clientX, y: e.clientY });
            img.classList.add('is-moving');
            if (pts.size === 1) {
                start = { x: e.clientX, y: e.clientY, ox: x, oy: y, t: Date.now() };
                if (Date.now() - lastTap < 300) { set(z > 1 ? 1 : 2.5); lastTap = 0; } else lastTap = Date.now();
            } else if (pts.size === 2) {
                const [a, b] = [...pts.values()];
                start = { d: Math.hypot(a.x - b.x, a.y - b.y), z };
            }
        });
        stage.addEventListener('pointermove', (e) => {
            if (!pts.has(e.pointerId) || !start) return;
            pts.set(e.pointerId, { x: e.clientX, y: e.clientY });
            if (pts.size === 2 && start.d) {
                const [a, b] = [...pts.values()];
                z = Math.min(4, Math.max(1, start.z * Math.hypot(a.x - b.x, a.y - b.y) / start.d));
                apply();
            } else if (pts.size === 1 && z > 1) {
                x = start.ox + e.clientX - start.x; y = start.oy + e.clientY - start.y; apply();
            }
        });
        const up = (e) => {
            const p = pts.get(e.pointerId);
            pts.delete(e.pointerId);
            img.classList.remove('is-moving');
            if (pts.size === 0 && start && start.x != null && z === 1 && p) {
                const dx = p.x - start.x;
                if (Math.abs(dx) > 60 && Date.now() - start.t < 600 && onSwipe) onSwipe(dx < 0 ? 1 : -1);
            }
            if (pts.size === 0) { start = null; if (z <= 1.05) set(1); }
        };
        stage.addEventListener('pointerup', up);
        stage.addEventListener('pointercancel', up);
        return { zoomStep() { set(z >= 3 ? 1 : z + 1); }, reset() { set(1); } };
    }

    function mount() {
        if (!document.getElementById('dspv-css')) {
            const s = el('style'); s.id = 'dspv-css'; s.textContent = css; document.head.appendChild(s);
        }
        close();
        root = el('div', 'dspv');
        root.setAttribute('role', 'dialog');
        root.setAttribute('aria-modal', 'true');
        document.body.appendChild(root);
        document.documentElement.style.overflow = 'hidden';
        return root;
    }

    window.dsPhotoViewer = {
        /** list: [{ src, label? }] or [src, …] */
        open(list, index = 0, opts = {}) {
            const items = (list || []).map((p) => (typeof p === 'string' ? { src: p } : p)).filter((p) => p && p.src);
            if (!items.length) return;
            let i = Math.min(Math.max(0, index), items.length - 1);
            const r = mount();
            rest();
            const top = el('div', 'dspv__top');
            const x = el('button', 'dspv__x', '✕'); x.type = 'button'; x.setAttribute('aria-label', 'Close');
            const count = el('b');
            const zl = el('span', 'dspv__pill', 'Fit');
            top.append(x, count, zl);
            const stage = el('div', 'dspv__stage');
            const img = el('img', 'dspv__img'); img.alt = 'Photo'; img.draggable = false;
            const prev = el('button', 'dspv__nav is-prev', '‹'); prev.type = 'button'; prev.setAttribute('aria-label', 'Previous photo');
            const next = el('button', 'dspv__nav is-next', '›'); next.type = 'button'; next.setAttribute('aria-label', 'Next photo');
            const hint = el('span', 'dspv__hint', 'Pinch or double-tap to zoom' + (items.length > 1 ? ' · swipe for the next' : ''));
            stage.append(img, prev, next, hint);
            // Board 71: in galleries (no Retake/Delete) the viewer also plays a slideshow and downloads the photo
            const gallery = !opts.onRetake && !opts.onDelete;
            let timer = null;
            const btns = [['🔍 Zoom', '', () => z.zoomStep()]];
            if (gallery && items.length > 1) btns.push(['▶ Slideshow', 'is-play', (e) => {
                const b = e.currentTarget;
                if (timer) { clearInterval(timer); timer = null; b.textContent = '▶ Slideshow'; b.classList.remove('is-on'); return; }
                timer = setInterval(() => { if (!r.isConnected) { clearInterval(timer); timer = null; return; } i = (i + 1) % items.length; show(); }, 3000);
                b.textContent = '❚❚ Pause'; b.classList.add('is-on');
            }]);
            if (gallery) btns.push(['⬇ Save', 'is-dl', null]);
            if (opts.onRetake) btns.push(['↺ Retake', '', () => { const k = i; close(); opts.onRetake(k); }]);
            if (opts.onDelete) btns.push(['🗑 Delete', 'is-del', () => { const k = i; close(); opts.onDelete(k); }]);
            const bar = el('div', 'dspv__bar is-' + btns.length);
            let dl = null;
            btns.forEach(([t, c, f]) => {
                if (!f) { dl = el('a', 'dspv__btn ' + c, t); dl.setAttribute('download', ''); bar.appendChild(dl); return; }
                const b = el('button', 'dspv__btn ' + c, t); b.type = 'button'; b.addEventListener('click', f); bar.appendChild(b);
            });
            const strip = el('div', 'dspv__strip');
            const thumbs = items.length > 1 ? items.map((p, k) => {
                const b = el('button'); b.type = 'button'; b.setAttribute('aria-label', 'Photo ' + (k + 1));
                const im = el('img'); im.src = p.src; im.alt = ''; im.loading = 'lazy'; b.appendChild(im);
                b.addEventListener('click', () => { i = k; show(); });
                strip.appendChild(b); return b;
            }) : [];
            const stop = () => { if (timer) clearInterval(timer); timer = null; };
            if (thumbs.length) r.append(top, stage, strip, bar); else r.append(top, stage, bar);

            const show = () => {
                img.src = items[i].src;
                count.textContent = items.length > 1 ? `${i + 1} of ${items.length}` : (items[i].label || 'Photo');
                prev.style.display = i > 0 ? '' : 'none';
                next.style.display = i < items.length - 1 ? '' : 'none';
                if (timer) { prev.style.display = ''; next.style.display = ''; }
                thumbs.forEach((b, k) => b.classList.toggle('is-on', k === i));
                if (thumbs[i]) thumbs[i].scrollIntoView({ block: 'nearest', inline: 'nearest' });
                if (dl) dl.href = items[i].src;
                z && z.reset();
            };
            const go = (d) => { const n = i + d; if (n >= 0 && n < items.length) { i = n; show(); } };
            const z = zoomable(img, stage, go, (v) => { zl.textContent = v > 1.05 ? `Zoom ${v.toFixed(1)}×` : 'Fit'; });
            prev.addEventListener('click', (e) => { e.stopPropagation(); go(-1); });
            next.addEventListener('click', (e) => { e.stopPropagation(); go(1); });
            prev.addEventListener('pointerdown', (e) => e.stopPropagation());
            next.addEventListener('pointerdown', (e) => e.stopPropagation());
            x.addEventListener('click', () => { stop(); close(); opts.onClose && opts.onClose(); });
            keyHandler = (e) => { if (e.key === 'Escape') { stop(); close(); opts.onClose && opts.onClose(); } else if (e.key === 'ArrowLeft') go(-1); else if (e.key === 'ArrowRight') go(1); };
            document.addEventListener('keydown', keyHandler);
            show();
        },
        close,
    };

    /** The photo big, right after it is taken: Retake or Use photo (used by itself after `auto` seconds). */
    window.dsPhotoCheck = function (file, opts = {}) {
        return new Promise((resolve) => {
            const r = mount();
            rest();
            const url = URL.createObjectURL(file);
            let left = Math.max(0, parseInt(opts.auto ?? 3, 10) || 0);
            let timer = null;
            const done = (what) => { clearInterval(timer); URL.revokeObjectURL(url); close(); resolve(what); };
            const top = el('div', 'dspv__top');
            top.append(el('b', '', opts.title || 'Check the photo'), el('span', 'dspv__pill', 'Pinch to zoom'));
            const stage = el('div', 'dspv__stage');
            const img = el('img', 'dspv__img'); img.alt = 'Photo you took'; img.src = url; img.draggable = false;
            const cd = el('span', 'dspv__cd');
            stage.append(img, cd);
            const bar = el('div', 'dspv__bar is-2');
            const re = el('button', 'dspv__btn', '↺ Retake'); re.type = 'button';
            const use = el('button', 'dspv__btn is-use', '✓ Use photo'); use.type = 'button';
            bar.append(re, use);
            r.append(top, stage, bar);
            zoomable(img, stage, null, (v) => { if (v > 1.05 && timer) { clearInterval(timer); timer = null; cd.textContent = 'Waiting for you'; } });
            re.addEventListener('click', () => done('retake'));
            use.addEventListener('click', () => done('use'));
            keyHandler = (e) => { if (e.key === 'Escape') done('retake'); if (e.key === 'Enter') done('use'); };
            document.addEventListener('keydown', keyHandler);
            if (left > 0) {
                cd.textContent = `Uses it in ${left} s`;
                timer = setInterval(() => { left -= 1; if (left <= 0) done('use'); else cd.textContent = `Uses it in ${left} s`; }, 1000);
            } else {
                cd.style.display = 'none';
            }
        });
    };

    // Any photo marked data-ds-photo opens the viewer with the photos of its gallery.
    document.addEventListener('click', (e) => {
        const t = e.target.closest && e.target.closest('[data-ds-photo]');
        if (!t || e.metaKey || e.ctrlKey || e.shiftKey) return;
        const g = t.closest('[data-ds-gallery]') || t.parentElement;
        const all = [...g.querySelectorAll('[data-ds-photo]')];
        const src = (n) => n.getAttribute('data-ds-photo') || n.getAttribute('href') || n.getAttribute('src') || (n.querySelector('img') && n.querySelector('img').src);
        e.preventDefault();
        window.dsPhotoViewer.open(all.map((n) => ({ src: src(n) })), all.indexOf(t), { onClose: () => g.dispatchEvent(new CustomEvent('ds-viewer-closed', { bubbles: true })) });
    });
})();
DISPATCH_FILE_END_1

# ---------------------------------------------------------------- resources/js/photo-viewer.js
mkdir -p 'resources/js'
cat > 'resources/js/photo-viewer.js' <<'DISPATCH_FILE_END_2'
/*
 * Part 42 · Check photos (board 68), in every app.
 *
 * window.dsPhotoViewer.open(list, index, opts)  full screen: zoom (pinch, double-tap, button),
 *     swipe or ‹ › for the next, ✕ to go back. opts.onDelete(i) / opts.onRetake(i) add the buttons.
 * window.dsPhotoCheck(file, { auto })  the photo big, right after it is taken: Retake or Use photo
 *     (used by itself after `auto` seconds, 0 = wait for a tap). Resolves 'use' or 'retake'.
 * Any <img data-ds-photo> inside [data-ds-gallery] opens the viewer for that gallery on a tap.
 * While a viewer is open, the barcode scanner rests (it never reads a box behind the photo).
 */
(function () {
    if (window.dsPhotoViewer) return;

    const css = `
.dspv{position:fixed;inset:0;z-index:90;background:#05090d;color:#eef3f6;display:flex;flex-direction:column;font-family:Archivo,system-ui,sans-serif;touch-action:none;-webkit-tap-highlight-color:transparent}
.dspv__top{display:flex;align-items:center;justify-content:space-between;gap:.6rem;padding:max(.8rem,env(safe-area-inset-top)) 1rem .6rem}
.dspv__x{width:2.6rem;height:2.6rem;border-radius:99px;background:rgb(255 255 255/.12);font-size:1.15rem;color:#fff}
.dspv__pill{padding:.25rem .7rem;border-radius:99px;background:rgb(255 255 255/.12);font-size:.8rem;font-weight:800}
.dspv__stage{position:relative;flex:1;overflow:hidden;display:flex;align-items:center;justify-content:center}
.dspv__img{max-width:100%;max-height:100%;object-fit:contain;transform-origin:center;transition:transform .15s ease-out;user-select:none;-webkit-user-drag:none}
.dspv__img.is-moving{transition:none}
.dspv__nav{position:absolute;top:50%;margin-top:-1.4rem;width:2.8rem;height:2.8rem;border-radius:99px;background:rgb(0 0 0/.45);color:#fff;font-size:1.4rem}
.dspv__nav.is-prev{left:.6rem}.dspv__nav.is-next{right:.6rem}
.dspv__hint{position:absolute;left:0;right:0;bottom:.7rem;text-align:center;font-size:.75rem;color:#cfd8de;pointer-events:none}
.dspv__cd{position:absolute;top:.7rem;right:.7rem;padding:.25rem .7rem;border-radius:99px;background:rgb(0 0 0/.55);font-size:.8rem;font-weight:800}
.dspv__bar{display:grid;gap:.5rem;padding:.7rem 1rem max(1rem,env(safe-area-inset-bottom))}
.dspv__bar.is-3{grid-template-columns:repeat(3,1fr)}.dspv__bar.is-4{grid-template-columns:repeat(4,1fr)}
.dspv__strip{display:flex;gap:.45rem;overflow-x:auto;padding:.55rem 1rem 0}.dspv__strip button{flex:none;width:4.2rem;height:3.1rem;border-radius:.45rem;overflow:hidden;opacity:.45;padding:0}.dspv__strip button.is-on{opacity:1;box-shadow:0 0 0 3px #f6be00}.dspv__strip img{width:100%;height:100%;object-fit:cover}
.dspv__btn.is-on{background:#f6be00;color:#0a1219}a.dspv__btn{display:flex;align-items:center;justify-content:center;text-decoration:none}.dspv__bar.is-2{grid-template-columns:1fr 1.4fr}.dspv__bar.is-1{grid-template-columns:1fr}
.dspv__btn{height:3.3rem;border-radius:1rem;background:rgb(255 255 255/.1);color:#fff;font-weight:800;font-size:1rem}
.dspv__btn.is-use{background:#3ddc97;color:#0a1219}.dspv__btn.is-del{background:rgb(200 55 45/.28);color:#ff8a80}
[data-ds-photo]{cursor:zoom-in}`;

    let root = null;
    let keyHandler = null;
    let wasPaused = null;

    function scanner(paused) {
        window.dispatchEvent(new CustomEvent('ds-scanner', { detail: { paused } }));
    }
    /** The scanner rests while a photo is open, and goes back to how it was after. */
    function rest() {
        wasPaused = window.dsScanner ? !!window.dsScanner.paused : null;
        scanner(true);
    }

    function el(tag, cls, html) {
        const e = document.createElement(tag);
        if (cls) e.className = cls;
        if (html != null) e.innerHTML = html;
        return e;
    }

    function close() {
        if (!root) return;
        root.remove();
        root = null;
        if (keyHandler) document.removeEventListener('keydown', keyHandler);
        keyHandler = null;
        document.documentElement.style.overflow = '';
        if (wasPaused === false) scanner(false);
        wasPaused = null;
    }

    /** Pinch, drag and double-tap zoom on one image; swipe calls onSwipe(-1|1) when not zoomed. */
    function zoomable(img, stage, onSwipe, onZoom) {
        let z = 1, x = 0, y = 0;
        const pts = new Map();
        let start = null;
        let lastTap = 0;
        const apply = () => { img.style.transform = `translate(${x}px, ${y}px) scale(${z})`; onZoom && onZoom(z); };
        const set = (nz) => { z = Math.min(4, Math.max(1, nz)); if (z === 1) { x = 0; y = 0; } apply(); };
        stage.addEventListener('pointerdown', (e) => {
            stage.setPointerCapture && stage.setPointerCapture(e.pointerId);
            pts.set(e.pointerId, { x: e.clientX, y: e.clientY });
            img.classList.add('is-moving');
            if (pts.size === 1) {
                start = { x: e.clientX, y: e.clientY, ox: x, oy: y, t: Date.now() };
                if (Date.now() - lastTap < 300) { set(z > 1 ? 1 : 2.5); lastTap = 0; } else lastTap = Date.now();
            } else if (pts.size === 2) {
                const [a, b] = [...pts.values()];
                start = { d: Math.hypot(a.x - b.x, a.y - b.y), z };
            }
        });
        stage.addEventListener('pointermove', (e) => {
            if (!pts.has(e.pointerId) || !start) return;
            pts.set(e.pointerId, { x: e.clientX, y: e.clientY });
            if (pts.size === 2 && start.d) {
                const [a, b] = [...pts.values()];
                z = Math.min(4, Math.max(1, start.z * Math.hypot(a.x - b.x, a.y - b.y) / start.d));
                apply();
            } else if (pts.size === 1 && z > 1) {
                x = start.ox + e.clientX - start.x; y = start.oy + e.clientY - start.y; apply();
            }
        });
        const up = (e) => {
            const p = pts.get(e.pointerId);
            pts.delete(e.pointerId);
            img.classList.remove('is-moving');
            if (pts.size === 0 && start && start.x != null && z === 1 && p) {
                const dx = p.x - start.x;
                if (Math.abs(dx) > 60 && Date.now() - start.t < 600 && onSwipe) onSwipe(dx < 0 ? 1 : -1);
            }
            if (pts.size === 0) { start = null; if (z <= 1.05) set(1); }
        };
        stage.addEventListener('pointerup', up);
        stage.addEventListener('pointercancel', up);
        return { zoomStep() { set(z >= 3 ? 1 : z + 1); }, reset() { set(1); } };
    }

    function mount() {
        if (!document.getElementById('dspv-css')) {
            const s = el('style'); s.id = 'dspv-css'; s.textContent = css; document.head.appendChild(s);
        }
        close();
        root = el('div', 'dspv');
        root.setAttribute('role', 'dialog');
        root.setAttribute('aria-modal', 'true');
        document.body.appendChild(root);
        document.documentElement.style.overflow = 'hidden';
        return root;
    }

    window.dsPhotoViewer = {
        /** list: [{ src, label? }] or [src, …] */
        open(list, index = 0, opts = {}) {
            const items = (list || []).map((p) => (typeof p === 'string' ? { src: p } : p)).filter((p) => p && p.src);
            if (!items.length) return;
            let i = Math.min(Math.max(0, index), items.length - 1);
            const r = mount();
            rest();
            const top = el('div', 'dspv__top');
            const x = el('button', 'dspv__x', '✕'); x.type = 'button'; x.setAttribute('aria-label', 'Close');
            const count = el('b');
            const zl = el('span', 'dspv__pill', 'Fit');
            top.append(x, count, zl);
            const stage = el('div', 'dspv__stage');
            const img = el('img', 'dspv__img'); img.alt = 'Photo'; img.draggable = false;
            const prev = el('button', 'dspv__nav is-prev', '‹'); prev.type = 'button'; prev.setAttribute('aria-label', 'Previous photo');
            const next = el('button', 'dspv__nav is-next', '›'); next.type = 'button'; next.setAttribute('aria-label', 'Next photo');
            const hint = el('span', 'dspv__hint', 'Pinch or double-tap to zoom' + (items.length > 1 ? ' · swipe for the next' : ''));
            stage.append(img, prev, next, hint);
            // Board 71: in galleries (no Retake/Delete) the viewer also plays a slideshow and downloads the photo
            const gallery = !opts.onRetake && !opts.onDelete;
            let timer = null;
            const btns = [['🔍 Zoom', '', () => z.zoomStep()]];
            if (gallery && items.length > 1) btns.push(['▶ Slideshow', 'is-play', (e) => {
                const b = e.currentTarget;
                if (timer) { clearInterval(timer); timer = null; b.textContent = '▶ Slideshow'; b.classList.remove('is-on'); return; }
                timer = setInterval(() => { if (!r.isConnected) { clearInterval(timer); timer = null; return; } i = (i + 1) % items.length; show(); }, 3000);
                b.textContent = '❚❚ Pause'; b.classList.add('is-on');
            }]);
            if (gallery) btns.push(['⬇ Save', 'is-dl', null]);
            if (opts.onRetake) btns.push(['↺ Retake', '', () => { const k = i; close(); opts.onRetake(k); }]);
            if (opts.onDelete) btns.push(['🗑 Delete', 'is-del', () => { const k = i; close(); opts.onDelete(k); }]);
            const bar = el('div', 'dspv__bar is-' + btns.length);
            let dl = null;
            btns.forEach(([t, c, f]) => {
                if (!f) { dl = el('a', 'dspv__btn ' + c, t); dl.setAttribute('download', ''); bar.appendChild(dl); return; }
                const b = el('button', 'dspv__btn ' + c, t); b.type = 'button'; b.addEventListener('click', f); bar.appendChild(b);
            });
            const strip = el('div', 'dspv__strip');
            const thumbs = items.length > 1 ? items.map((p, k) => {
                const b = el('button'); b.type = 'button'; b.setAttribute('aria-label', 'Photo ' + (k + 1));
                const im = el('img'); im.src = p.src; im.alt = ''; im.loading = 'lazy'; b.appendChild(im);
                b.addEventListener('click', () => { i = k; show(); });
                strip.appendChild(b); return b;
            }) : [];
            const stop = () => { if (timer) clearInterval(timer); timer = null; };
            if (thumbs.length) r.append(top, stage, strip, bar); else r.append(top, stage, bar);

            const show = () => {
                img.src = items[i].src;
                count.textContent = items.length > 1 ? `${i + 1} of ${items.length}` : (items[i].label || 'Photo');
                prev.style.display = i > 0 ? '' : 'none';
                next.style.display = i < items.length - 1 ? '' : 'none';
                if (timer) { prev.style.display = ''; next.style.display = ''; }
                thumbs.forEach((b, k) => b.classList.toggle('is-on', k === i));
                if (thumbs[i]) thumbs[i].scrollIntoView({ block: 'nearest', inline: 'nearest' });
                if (dl) dl.href = items[i].src;
                z && z.reset();
            };
            const go = (d) => { const n = i + d; if (n >= 0 && n < items.length) { i = n; show(); } };
            const z = zoomable(img, stage, go, (v) => { zl.textContent = v > 1.05 ? `Zoom ${v.toFixed(1)}×` : 'Fit'; });
            prev.addEventListener('click', (e) => { e.stopPropagation(); go(-1); });
            next.addEventListener('click', (e) => { e.stopPropagation(); go(1); });
            prev.addEventListener('pointerdown', (e) => e.stopPropagation());
            next.addEventListener('pointerdown', (e) => e.stopPropagation());
            x.addEventListener('click', () => { stop(); close(); opts.onClose && opts.onClose(); });
            keyHandler = (e) => { if (e.key === 'Escape') { stop(); close(); opts.onClose && opts.onClose(); } else if (e.key === 'ArrowLeft') go(-1); else if (e.key === 'ArrowRight') go(1); };
            document.addEventListener('keydown', keyHandler);
            show();
        },
        close,
    };

    /** The photo big, right after it is taken: Retake or Use photo (used by itself after `auto` seconds). */
    window.dsPhotoCheck = function (file, opts = {}) {
        return new Promise((resolve) => {
            const r = mount();
            rest();
            const url = URL.createObjectURL(file);
            let left = Math.max(0, parseInt(opts.auto ?? 3, 10) || 0);
            let timer = null;
            const done = (what) => { clearInterval(timer); URL.revokeObjectURL(url); close(); resolve(what); };
            const top = el('div', 'dspv__top');
            top.append(el('b', '', opts.title || 'Check the photo'), el('span', 'dspv__pill', 'Pinch to zoom'));
            const stage = el('div', 'dspv__stage');
            const img = el('img', 'dspv__img'); img.alt = 'Photo you took'; img.src = url; img.draggable = false;
            const cd = el('span', 'dspv__cd');
            stage.append(img, cd);
            const bar = el('div', 'dspv__bar is-2');
            const re = el('button', 'dspv__btn', '↺ Retake'); re.type = 'button';
            const use = el('button', 'dspv__btn is-use', '✓ Use photo'); use.type = 'button';
            bar.append(re, use);
            r.append(top, stage, bar);
            zoomable(img, stage, null, (v) => { if (v > 1.05 && timer) { clearInterval(timer); timer = null; cd.textContent = 'Waiting for you'; } });
            re.addEventListener('click', () => done('retake'));
            use.addEventListener('click', () => done('use'));
            keyHandler = (e) => { if (e.key === 'Escape') done('retake'); if (e.key === 'Enter') done('use'); };
            document.addEventListener('keydown', keyHandler);
            if (left > 0) {
                cd.textContent = `Uses it in ${left} s`;
                timer = setInterval(() => { left -= 1; if (left <= 0) done('use'); else cd.textContent = `Uses it in ${left} s`; }, 1000);
            } else {
                cd.style.display = 'none';
            }
        });
    };

    // Any photo marked data-ds-photo opens the viewer with the photos of its gallery.
    document.addEventListener('click', (e) => {
        const t = e.target.closest && e.target.closest('[data-ds-photo]');
        if (!t || e.metaKey || e.ctrlKey || e.shiftKey) return;
        const g = t.closest('[data-ds-gallery]') || t.parentElement;
        const all = [...g.querySelectorAll('[data-ds-photo]')];
        const src = (n) => n.getAttribute('data-ds-photo') || n.getAttribute('href') || n.getAttribute('src') || (n.querySelector('img') && n.querySelector('img').src);
        e.preventDefault();
        window.dsPhotoViewer.open(all.map((n) => ({ src: src(n) })), all.indexOf(t), { onClose: () => g.dispatchEvent(new CustomEvent('ds-viewer-closed', { bubbles: true })) });
    });
})();
DISPATCH_FILE_END_2

# ---------------------------------------------------------------- resources/views/filament/partials/box-photo-thumb.blade.php
mkdir -p 'resources/views/filament/partials'
cat > 'resources/views/filament/partials/box-photo-thumb.blade.php' <<'DISPATCH_FILE_END_3'
{{-- Board 71: one photo in a gallery row. Its width follows the photo (wide stays wide), caption on hover. --}}
@php($tone = ['good' => 'ok', 'damaged' => 'bad', 'wet' => 'wet', 'open' => 'warn'][$i['condition'] ?? ''] ?? null)
<figure data-tile wire:key="t-{{ $key }}" class="group relative m-0 h-40 min-w-28 overflow-hidden rounded-xl bg-(--bp-raised) [flex:133_1_12.5rem] sm:h-44"
        x-bind:class="{ 'ring-3 ring-(--bp-gold) ring-offset-2 ring-offset-(--bp-surf)': isSel(@js($key)) || (open && cur === @js($key)) }">
    <button type="button" class="block size-full cursor-zoom-in" x-on:click="show(@js($key))" aria-label="Open {{ $i['name'] }}">
        <img src="{{ $i['url'] }}" alt="{{ $i['label'] }} · {{ $i['invoice'] }}" loading="lazy" decoding="async"
             x-on:load="fit($event)" x-init="$el.complete && fit({ target: $el })"
             class="size-full object-cover transition duration-300 group-hover:scale-[1.04]">
    </button>
    <span class="pointer-events-none absolute left-2 top-2 inline-flex max-w-[calc(100%-3rem)] items-center gap-1.5 truncate whitespace-nowrap rounded-full bg-black/55 px-2 py-0.5 text-[0.68rem] font-extrabold text-white backdrop-blur-sm">
        @if ($tone)<i @class(['ds-bp__dot', 'is-'.$tone])></i>@endif
        {{ $i['kind'] === 'scan' ? $i['label'] : ($i['kind'] === 'delivered' ? 'Delivered' : 'Not delivered') }}{{ $tone && $tone !== 'ok' ? ' · '.(\App\Models\BoxPhoto::CONDITIONS[$i['condition']] ?? '') : '' }}
    </span>
    <button type="button" x-on:click.stop="toggle(@js($key))" aria-label="Select {{ $i['name'] }}" x-bind:aria-pressed="isSel(@js($key))"
            class="absolute right-2 top-2 grid size-7 place-items-center rounded-full text-sm font-black transition"
            x-bind:class="isSel(@js($key)) ? 'bg-(--bp-gold) text-[#0e2433] opacity-100' : 'bg-black/45 text-transparent ring-2 ring-white/90 ' + (picking ? 'opacity-100' : 'opacity-0 group-hover:opacity-100 focus:opacity-100')">✓</button>
    <figcaption class="pointer-events-none absolute inset-x-0 bottom-0 flex translate-y-[58%] flex-col gap-0.5 bg-linear-to-t from-black/85 via-black/55 to-transparent px-3 pb-2 pt-7 text-white transition duration-200 group-hover:translate-y-0">
        <b class="truncate text-[0.8rem] font-extrabold">{{ $i['invoice'] }}{{ $i['who'] ? ' · '.$i['who'] : '' }}</b>
        <small class="truncate text-[0.72rem] text-white/80">{{ $i['at']?->format('d M Y · g:i A') }}{{ $i['note'] ? ' · “'.\Illuminate\Support\Str::limit($i['note'], 40).'”' : '' }}</small>
    </figcaption>
</figure>
DISPATCH_FILE_END_3

# ---------------------------------------------------------------- resources/views/filament/shared/box-photos.blade.php
mkdir -p 'resources/views/filament/shared'
cat > 'resources/views/filament/shared/box-photos.blade.php' <<'DISPATCH_FILE_END_4'
@php
    $condColor = ['good' => 'ok', 'damaged' => 'bad', 'wet' => 'wet', 'open' => 'warn'];
@endphp
<x-filament-panels::page>
    <div class="ds-bp" wire:key="bp-{{ md5($q.'|'.$place.'|'.$cond.'|'.implode(',', array_keys($viewer))) }}"
         x-data="{
            items: @js($viewer),
            cur: null, open: false, zoom: 1, playing: null, picking: false,
            sel: $wire.entangle('selected'),
            isSel(k) { return this.sel.includes(k) },
            toggle(k) { this.sel = this.isSel(k) ? this.sel.filter(x => x !== k) : [...this.sel, k] },
            get it() { return this.items[this.cur] || null },
            get strip() { const inv = this.it?.invoice; return Object.keys(this.items).filter(k => this.items[k].invoice === inv) },
            get pos() { return this.strip.indexOf(this.cur) + 1 },
            get selSize() { const b = this.sel.reduce((s, k) => s + (this.items[k]?.size || 0), 0); return b >= 1048576 ? (b / 1048576).toFixed(1) + ' MB' : Math.max(1, Math.round(b / 1024)) + ' KB' },
            step(d) { const s = this.strip; const i = s.indexOf(this.cur); if (s.length) { this.cur = s[(i + d + s.length) % s.length]; this.zoom = 1 } },
            show(k) { if (this.picking) { this.toggle(k); return } this.cur = k; this.zoom = 1; this.open = true },
            close() { this.open = false; this.zoom = 1; this.play(false) },
            play(on) { clearInterval(this.playing); this.playing = null; if (on) this.playing = setInterval(() => this.step(1), 3000) },
            fit(e) { const i = e.target; if (i.naturalWidth && i.naturalHeight) { const r = Math.min(2.4, Math.max(0.5, i.naturalWidth / i.naturalHeight)); i.closest('[data-tile]').style.flex = Math.round(r * 100) + ' 1 ' + Math.round(r * 9.5) + 'rem' } },
         }"
         x-on:keydown.arrow-right.window="open && step(1)" x-on:keydown.arrow-left.window="open && step(-1)" x-on:keydown.escape.window="open && close()">

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

        <label class="ds-bp__search">
            <x-filament::icon icon="heroicon-o-magnifying-glass" class="h-5 w-5" />
            <input type="search" wire:model.live.debounce.400ms="q" placeholder="Invoice, container or trip number…" autocomplete="off" autofocus aria-label="Search box photos">
            @if ($q !== '')
                <button type="button" wire:click="clearSearch" class="ds-bp__clear" aria-label="Clear search">✕</button>
            @endif
            <span class="ds-bp__hint">Type or scan</span>
        </label>

        @if (trim($q) === '')
            <section class="ds-bp__empty">
                <span class="ds-bp__empty-icon"><x-filament::icon icon="heroicon-o-magnifying-glass" class="h-8 w-8" /></span>
                <h2>Search a box to see its photos</h2>
                <p>Type or scan an invoice number, a container number or a trip number. Photos stay hidden until you search.</p>
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
                    <p class="ds-bp__count">{{ $boxes->count() }} {{ str('box')->plural($boxes->count()) }} · {{ $photoCount }} {{ str('photo')->plural($photoCount) }} · newest first</p>
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

                                <ol class="ds-bp__journey" aria-label="Where this box has been">
                                    @foreach ($b['journey'] as $j)
                                        @php($tone = $j['kind'] === 'delivered' ? 'ok' : ($j['kind'] === 'not_delivered' ? 'warn' : ($condColor[$j['condition']] ?? 'none')))
                                        <li><i @class(['ds-bp__dot', 'is-'.$tone])></i>{{ $j['label'] }}</li>
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
                                            <span><strong>Delivered</strong><small>{{ $d['at']?->format('d M Y · g:i A') }} · {{ $d['who'] ?? 'Driver' }}{{ $d['to'] ? ' · to '.\Illuminate\Support\Str::title($d['to']) : '' }}{{ $d['trip'] ? ' · Trip '.$d['trip'] : '' }}</small></span>
                                            <em>{{ count($d['keys']) }} {{ str('photo')->plural(count($d['keys'])) }}</em>
                                        </div>
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
                        <button type="button" class="h-10 rounded-full px-4 text-[0.8rem] font-extrabold" x-on:click="toggle(cur)"
                                x-bind:class="isSel(cur) ? 'bg-(--bp-gold) text-[#0e2433]' : 'bg-white/10 hover:bg-white/20'" x-text="isSel(cur) ? '✓ Selected' : 'Select'"></button>
                        <button type="button" class="grid size-10 place-items-center rounded-full bg-white/10 hover:bg-white/20" x-on:click="close()" aria-label="Close">✕</button>
                    </div>
                    <div class="relative flex min-h-0 flex-1 items-center justify-center overflow-hidden px-3 sm:px-16"
                         x-data="{ sx: null }" x-on:touchstart="sx = $event.touches[0].clientX" x-on:touchend="if (sx !== null && zoom === 1) { const dx = $event.changedTouches[0].clientX - sx; if (Math.abs(dx) > 60) step(dx < 0 ? 1 : -1) } sx = null">
                        <img x-bind:src="it?.src" x-bind:alt="it?.name" x-on:dblclick="zoom = zoom > 1 ? 1 : 2.5"
                             class="max-h-full max-w-full select-none object-contain transition-transform duration-200" x-bind:style="'transform: scale(' + zoom + ')'" x-bind:class="zoom > 1 ? 'cursor-zoom-out' : 'cursor-zoom-in'">
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
DISPATCH_FILE_END_4

# ---------------------------------------------------------------- tests/Feature/PhotoGalleryTest.php
mkdir -p 'tests/Feature'
cat > 'tests/Feature/PhotoGalleryTest.php' <<'DISPATCH_FILE_END_5'
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
DISPATCH_FILE_END_5

echo "▶ Rebuilding the design"
npm run build

echo "▶ Clearing caches"
php artisan optimize:clear

echo "▶ Running the tests"
php artisan test || echo "Some tests failed — send the red text for help."

echo
echo "✓ Done. Backup: $BACKUP"
echo "  Start the app with:  PHP_CLI_SERVER_WORKERS=4 php artisan serve   (or open https://dispatchsystem.test in Herd)"
