#!/usr/bin/env bash
#
# Dispatch System — Part 45 · Search on Enter, Email photos with AI
# Only the files changed in this step; the rest of your project is left as it is.
#
#   cd ~/Desktop/Project/DispatchSystem
#   bash ~/Desktop/Project/part45-search-email-ai.sh

set -euo pipefail
[ -f artisan ] || { echo "Run this from inside your DispatchSystem project folder (the one with 'artisan')."; exit 1; }

STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="../DispatchSystem-backup-$STAMP.tar.gz"
echo "▶ Backing up the project to $BACKUP"
tar -czf "$BACKUP" --exclude=vendor --exclude=node_modules --exclude=storage/logs .

echo "▶ Writing 15 files"

# ---------------------------------------------------------------- app/Filament/Resources/Invoiceissues/InvoiceissueResource.php
mkdir -p 'app/Filament/Resources/Invoiceissues'
cat > 'app/Filament/Resources/Invoiceissues/InvoiceissueResource.php' <<'DISPATCH_FILE_END_0'
<?php

namespace App\Filament\Resources\Invoiceissues;

use App\Filament\Resources\Invoiceissues\Pages\CreateInvoiceissue;
use App\Filament\Resources\Invoiceissues\Pages\EditInvoiceissue;
use App\Filament\Resources\Invoiceissues\Pages\ListInvoiceissues;
use App\Filament\Resources\Invoiceissues\Schemas\InvoiceissueForm;
use App\Filament\Resources\Invoiceissues\Tables\InvoiceissuesTable;
use App\Models\Invoiceissue;
use BackedEnum;
use Filament\Resources\Resource;
use Filament\Schemas\Schema;
use Filament\Support\Icons\Heroicon;
use Filament\Tables\Table;

class InvoiceissueResource extends Resource
{
    protected static ?string $model = Invoiceissue::class;
protected static ?string $navigationLabel = 'Invoice Issue';
    protected static string|BackedEnum|null $navigationIcon = Heroicon::OutlinedQueueList;

    public static function form(Schema $schema): Schema
    {
        return InvoiceissueForm::configure($schema);
    }

    public static function table(Table $table): Table
    {
        return InvoiceissuesTable::configure($table)->searchOnBlur(); // Part 45: search when Enter is pressed, not on every key
    }

    public static function getRelations(): array
    {
        return [
            //
        ];
    }

    public static function getPages(): array
    {
        return [
            'index' => ListInvoiceissues::route('/'),
           // 'create' => CreateInvoiceissue::route('/create'),
          //  'edit' => EditInvoiceissue::route('/{record}/edit'),
        ];
    }
}
DISPATCH_FILE_END_0

# ---------------------------------------------------------------- app/Filament/Resources/Searchinvs/SearchinvResource.php
mkdir -p 'app/Filament/Resources/Searchinvs'
cat > 'app/Filament/Resources/Searchinvs/SearchinvResource.php' <<'DISPATCH_FILE_END_1'
<?php

namespace App\Filament\Resources\Searchinvs;

use App\Filament\Resources\Searchinvs\Pages\CreateSearchinv;
use App\Filament\Resources\Searchinvs\Pages\EditSearchinv;
use App\Filament\Resources\Searchinvs\Pages\ListSearchinvs;
use App\Filament\Resources\Searchinvs\Schemas\SearchinvForm;
use App\Filament\Resources\Searchinvs\Tables\SearchinvsTable;
use App\Models\Searchinv;
use BackedEnum;
use Filament\Resources\Resource;
use Filament\Schemas\Schema;
use Filament\Support\Icons\Heroicon;
use Filament\Tables\Table;

class SearchinvResource extends Resource
{
    protected static ?string $model = Searchinv::class;
     protected static ?string $navigationLabel = 'Search Invoice';
    public static ?string $label = 'Search Invoice';


    protected static string|BackedEnum|null $navigationIcon = Heroicon::MagnifyingGlass;

    protected static ?string $recordTitleAttribute = 'invoice';

    public static function form(Schema $schema): Schema
    {
        return SearchinvForm::configure($schema);
    }

    public static function table(Table $table): Table
    {
        return SearchinvsTable::configure($table)->searchOnBlur(); // Part 45: search when Enter is pressed, not on every key
    }

    public static function getRelations(): array
    {
        return [
            //
        ];
    }

    public static function getPages(): array
    {
        return [
            'index' => ListSearchinvs::route('/'),
            'create' => CreateSearchinv::route('/create'),
         //   'edit' => EditSearchinv::route('/{record}/edit'),
        ];
    }
}
DISPATCH_FILE_END_1

# ---------------------------------------------------------------- app/Filament/Shared/Ai/IssueHelperAction.php
mkdir -p 'app/Filament/Shared/Ai'
cat > 'app/Filament/Shared/Ai/IssueHelperAction.php' <<'DISPATCH_FILE_END_2'
<?php

namespace App\Filament\Shared\Ai;

use App\Mail\BoxPhotosMail;
use App\Models\BoxPhotoEmail;
use App\Models\Invoiceissue;
use App\Support\Ai\Ai;
use App\Support\Ai\AiUnavailable;
use App\Support\Ai\IssueHelper;
use App\Support\Photos\BoxAlbum;
use Filament\Actions\Action;
use Filament\Forms\Components\Textarea;
use Filament\Forms\Components\TextInput;
use Filament\Forms\Components\Toggle;
use Filament\Forms\Components\ToggleButtons;
use Filament\Schemas\Components\Utilities\Get;
use Filament\Schemas\Components\Utilities\Set;
use App\Support\Ai\EmailLanguages;
use Filament\Notifications\Notification;
use Filament\Schemas\Components\Text;
use Filament\Support\Icons\Heroicon;
use Illuminate\Support\Facades\Auth;
use Illuminate\Support\Facades\Mail;
use Throwable;

/** "AI helper" on an Invoice Issue: summary, next step, and the email to the consolidator with the photos. */
class IssueHelperAction
{
    public static function make(): Action
    {
        return Action::make('aiHelper')
            ->label('AI helper')
            ->icon(Heroicon::OutlinedSparkles)
            ->color('info')
            ->visible(fn () => Ai::switchedOn('issues'))
            ->modalHeading(fn (Invoiceissue $record) => 'Box '.$record->invoice)
            ->modalSubmitActionLabel('Send email')
            ->modalWidth('2xl')
            ->fillForm(function (Invoiceissue $record): array {
                $lang = EmailLanguages::for(static::consolidatorId($record));
                try {
                    $d = IssueHelper::draft($record, $lang);
                } catch (AiUnavailable $e) {
                    return ['summary' => $e->getMessage(), 'next' => '', 'to' => '', 'subject' => 'Box '.$record->invoice, 'body' => '', 'photos' => true, 'lang' => $lang, 'english' => false];
                }

                return ['summary' => $d['summary'], 'next' => $d['next'], 'to' => $d['to'], 'subject' => $d['subject'], 'body' => $d['body'], 'photos' => true, 'lang' => $lang, 'english' => false];
            })
            ->schema([
                Textarea::make('summary')->label('AI summary')->rows(2)->disabled()->dehydrated(false),
                Textarea::make('next')->label('Suggested next step')->rows(2)->disabled()->dehydrated(false),
                TextInput::make('to')->label('To (consolidator email)')->email()->required(),
                // Part 45: the email in the consolidator's language (remembered), English below if asked
                ToggleButtons::make('lang')->label('Language of the email')->options(EmailLanguages::options())->inline()->live()
                    ->helperText(fn (Get $get) => in_array($get('lang'), EmailLanguages::CHECK, true)
                        ? 'The AI writes this language less surely: read it before sending, or tick Add English below.' : null),
                Toggle::make('english')->label('Add English below')->inline(),
                TextInput::make('subject')->required()->maxLength(200),
                Textarea::make('body')->label('Email (written by AI · edit as you like)')->rows(10)->required()
                    ->hintAction(Action::make('rewrite')->label('✨ Write again in this language')->color('info')
                        ->action(function (Invoiceissue $record, Get $get, Set $set) {
                            try {
                                $d = IssueHelper::draft($record, (string) $get('lang'), (bool) $get('english'));
                            } catch (AiUnavailable $e) {
                                Notification::make()->title('The AI helper is not available')->body($e->getMessage())->warning()->send();

                                return;
                            }
                            $set('subject', $d['subject']);
                            $set('body', $d['body']);
                        })),
                Toggle::make('photos')->label('Attach the box photos'),
                Text::make('The email is only sent when you press Send.'),
            ])
            ->action(function (Invoiceissue $record, array $data): void {
                EmailLanguages::remember(static::consolidatorId($record), (string) ($data['lang'] ?? 'en'));
                $photos = collect();
                if ($data['photos'] ?? false) {
                    $photos = (new BoxAlbum(Auth::user()))->forInvoice($record->invoice_id)->take(15);
                }
                $log = BoxPhotoEmail::create([
                    'user_id' => Auth::id(), 'recipients' => [$data['to']], 'subject' => $data['subject'],
                    'message' => $data['body'], 'photo_ids' => $photos->pluck('key')->all(),
                ]);
                try {
                    Mail::to($data['to'])->send(new BoxPhotosMail($data['subject'], $data['body'], $photos, Auth::user()?->full_name));
                    $log->update(['status' => 'sent']);
                } catch (Throwable $e) {
                    report($e);
                    $log->update(['status' => 'failed', 'error' => mb_substr($e->getMessage(), 0, 250)]);
                    Notification::make()->title('The email could not be sent')->body($e->getMessage())->danger()->send();

                    return;
                }
                Notification::make()->title('Email sent to '.$data['to'])->success()->send();
            });
    }

    protected static function consolidatorId(Invoiceissue $record): ?int
    {
        $inv = $record->invoice_id ? \App\Models\Invoice::with('container')->find($record->invoice_id) : null;

        return $inv ? ($inv->consolidator?->id ?? $inv->container?->consolidator_id) : null;
    }
}
DISPATCH_FILE_END_2

# ---------------------------------------------------------------- app/Filament/Shared/BoxPhotosPage.php
mkdir -p 'app/Filament/Shared'
cat > 'app/Filament/Shared/BoxPhotosPage.php' <<'DISPATCH_FILE_END_3'
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
DISPATCH_FILE_END_3

# ---------------------------------------------------------------- app/Filament/Warehouse/Resources/Invoiceissues/InvoiceissueResource.php
mkdir -p 'app/Filament/Warehouse/Resources/Invoiceissues'
cat > 'app/Filament/Warehouse/Resources/Invoiceissues/InvoiceissueResource.php' <<'DISPATCH_FILE_END_4'
<?php

namespace App\Filament\Warehouse\Resources\Invoiceissues;

use App\Filament\Warehouse\Resources\Invoiceissues\Pages\CreateInvoiceissue;
use App\Filament\Warehouse\Resources\Invoiceissues\Pages\EditInvoiceissue;
use App\Filament\Warehouse\Resources\Invoiceissues\Pages\ListInvoiceissues;
use App\Filament\Warehouse\Resources\Invoiceissues\Pages\ViewInvoiceissue;
use App\Filament\Warehouse\Resources\Invoiceissues\Schemas\InvoiceissueForm;
use App\Filament\Warehouse\Resources\Invoiceissues\Schemas\InvoiceissueInfolist;
use App\Filament\Warehouse\Resources\Invoiceissues\Tables\InvoiceissuesTable;
use App\Models\Invoiceissue;
use BackedEnum;
use Filament\Resources\Resource;
use Filament\Schemas\Schema;
use Filament\Support\Icons\Heroicon;
use Filament\Tables\Table;
use UnitEnum;

class InvoiceissueResource extends Resource
{
    protected static ?string $model = Invoiceissue::class;
     protected static string | UnitEnum | null $navigationGroup = 'Invoice Management';
     protected static ?string $navigationLabel = 'Invoice Issue';
    public static ?string $label = 'Invoice Issue';


  //  protected static string|BackedEnum|null $navigationIcon = Heroicon::ExclamationCircle;

    protected static ?string $recordTitleAttribute = 'invoice';

    public static function form(Schema $schema): Schema
    {
        return InvoiceissueForm::configure($schema);
    }

    public static function infolist(Schema $schema): Schema
    {
        return InvoiceissueInfolist::configure($schema);
    }

    public static function table(Table $table): Table
    {
        return InvoiceissuesTable::configure($table)->searchOnBlur(); // Part 45: search when Enter is pressed, not on every key
    }

    public static function getRelations(): array
    {
        return [
            //
        ];
    }

    public static function getPages(): array
    {
        return [
            'index' => ListInvoiceissues::route('/'),
        //    'create' => CreateInvoiceissue::route('/create'),
       //     'view' => ViewInvoiceissue::route('/{record}'),
       //     'edit' => EditInvoiceissue::route('/{record}/edit'),
        ];
    }
}
DISPATCH_FILE_END_4

# ---------------------------------------------------------------- app/Filament/Warehouse/Resources/Searchinvs/SearchinvResource.php
mkdir -p 'app/Filament/Warehouse/Resources/Searchinvs'
cat > 'app/Filament/Warehouse/Resources/Searchinvs/SearchinvResource.php' <<'DISPATCH_FILE_END_5'
<?php

namespace App\Filament\Warehouse\Resources\Searchinvs;

use App\Filament\Warehouse\Resources\Searchinvs\Pages\CreateSearchinv;
use App\Filament\Warehouse\Resources\Searchinvs\Pages\EditSearchinv;
use App\Filament\Warehouse\Resources\Searchinvs\Pages\ListSearchinvs;
use App\Filament\Warehouse\Resources\Searchinvs\Schemas\SearchinvForm;
use App\Filament\Warehouse\Resources\Searchinvs\Tables\SearchinvsTable;
use App\Models\Searchinv;
use BackedEnum;
use Filament\Resources\Resource;
use Filament\Schemas\Schema;
use Filament\Support\Icons\Heroicon;
use Filament\Tables\Table;
use UnitEnum;

class SearchinvResource extends Resource
{
    protected static ?string $model = Searchinv::class;
    protected static string | UnitEnum | null $navigationGroup = 'Invoice Management';

      protected static ?string $navigationLabel = 'Search Invoice';
    public static ?string $label = 'Search Invoice';


 //   protected static string|BackedEnum|null $navigationIcon = Heroicon::MagnifyingGlass;

    protected static ?string $recordTitleAttribute = 'invoice';

    public static function form(Schema $schema): Schema
    {
        return SearchinvForm::configure($schema);
    }

    public static function table(Table $table): Table
    {
        return SearchinvsTable::configure($table)->searchOnBlur(); // Part 45: search when Enter is pressed, not on every key
    }

    public static function getRelations(): array
    {
        return [
            //
        ];
    }

    public static function getPages(): array
    {
        return [
            'index' => ListSearchinvs::route('/'),
         //   'create' => CreateSearchinv::route('/create'),
        //    'edit' => EditSearchinv::route('/{record}/edit'),
        ];
    }
}
DISPATCH_FILE_END_5

# ---------------------------------------------------------------- app/Providers/AppServiceProvider.php
mkdir -p 'app/Providers'
cat > 'app/Providers/AppServiceProvider.php' <<'DISPATCH_FILE_END_6'
<?php

namespace App\Providers;

use App\Models\Consolidator;
use App\Support\Navigation\DispatchNavigationManager;
use App\Support\Photos\PhotoShrinker;
use App\Support\SchemaMemo;
use Filament\Actions\DeleteAction;
use Filament\Forms\Components\FileUpload;
use Filament\Navigation\NavigationManager;
use Filament\Notifications\Notification;
use Filament\Schemas\Components\Section;
use Filament\Support\Assets\Css;
use Filament\Support\Assets\Js;
use Filament\Support\Facades\FilamentAsset;
use Filament\Tables\Table;
use Illuminate\Console\Events\CommandFinished;
use Illuminate\Database\Eloquent\Model;
use Illuminate\Database\Events\MigrationEnded;
use Illuminate\Database\Events\MigrationsEnded;
use Illuminate\Database\Events\SchemaLoaded;
use Illuminate\Database\QueryException;
use Illuminate\Database\Schema\Builder;
use Illuminate\Support\Facades\Event;
use Illuminate\Support\Facades\Queue;
use Illuminate\Support\ServiceProvider;

class AppServiceProvider extends ServiceProvider
{
    public function register(): void
    {
        // Speed: Schema::hasTable / hasColumn answers are remembered (App\Support\SchemaMemo); forgotten when migrations run.
        $this->app->extend('db.schema', fn ($schema) => $schema instanceof Builder ? new SchemaMemo($schema) : $schema);
    }

    public function boot(): void
    {
        // Side menus: groups in the order of the work, clear names, numbers on what waits (App\Support\Navigation\Menu).
        $this->app->scoped(NavigationManager::class, fn () => new DispatchNavigationManager);

        // Forms are built with Filament schemas, which only pass the fields they render.
        Model::unguard();

        // Photos on this server or in a bucket (Settings → Photo storage): the public and box disks.
        \Illuminate\Support\Facades\Storage::extend('routed', function ($app, array $config) {
            $adapter = new \App\Support\Photos\Storage\RoutedAdapter($config['name'], $config);

            return new \Illuminate\Filesystem\FilesystemAdapter(new \League\Flysystem\Filesystem($adapter, $config), $adapter, $config);
        });
        // Local only: buckets as folders, to try the page without R2 (PHOTOS_FAKE_BUCKETS=1 in .env).
        if ($this->app->environment('local') && env('PHOTOS_FAKE_BUCKETS')) {
            \App\Support\Photos\Storage\PhotoStore::$fake = true;
        }
        // The page shows if a queue worker runs (Supervisor or Plesk): it is seen here.
        Event::listen(\Illuminate\Queue\Events\Looping::class, function () {
            static $last = 0;
            if (time() - $last > 60) {
                $last = time();
                \Illuminate\Support\Facades\Cache::put('photos.queue.seen', $last, 3600);
            }
        });

        Section::configureUsing(fn (Section $section) => $section->columnSpanFull());

        // Photos are made smaller on the phone before upload (longest side 1600 px), like the
        // Scan app and the Driver app. A 3 MB phone photo becomes a few hundred KB.
        // Non-photo files are not touched; small pictures (logos) are never made bigger.
        FileUpload::configureUsing(fn (FileUpload $upload) => $upload
            ->automaticallyResizeImagesMode('contain')
            ->automaticallyResizeImagesToWidth((string) PhotoShrinker::MAX_SIDE)
            ->automaticallyResizeImagesToHeight((string) PhotoShrinker::MAX_SIDE)
            ->imageResizeUpscale(false));

        // Consistent, roomier tables in every panel.
        Table::configureUsing(fn (Table $table) => $table
            ->paginationPageOptions([10, 25, 50, 100])
            ->defaultPaginationPageOption(25)
            ->striped());

        // Deleting something that is still in use (e.g. a truck that has trips) used to end in a
        // database error page. Show a clear message instead.
        DeleteAction::configureUsing(fn (DeleteAction $action) => $action->using(
            function (Model $record, DeleteAction $action): bool {
                try {
                    return (bool) $record->delete();
                } catch (QueryException $exception) {
                    if (! in_array($exception->getCode(), ['23000', '23503'], true)) {
                        throw $exception;
                    }

                    Notification::make()
                        ->title('Cannot delete this record')
                        ->body('It is still used by other records (for example trips or invoices). Remove those first.')
                        ->danger()
                        ->persistent()
                        ->send();

                    $action->halt();

                    return false;
                }
            },
        ));

        // Queue workers live for hours; start every job with fresh lookups.
        Queue::looping(function () {
            Consolidator::flushNameCache();
            SchemaMemo::reset();
        });

        // Tables changed: forget the remembered Schema answers.
        Event::listen([MigrationsEnded::class, MigrationEnded::class, SchemaLoaded::class], fn () => SchemaMemo::flush());
        Event::listen(CommandFinished::class, function ($e) {
            if (in_array($e->command, ['optimize:clear', 'cache:clear', 'migrate', 'migrate:fresh', 'migrate:rollback', 'migrate:refresh', 'migrate:reset', 'db:wipe'], true)) {
                SchemaMemo::flush();
            }
        });

        FilamentAsset::register([
            Js::make('barcode-scanner', resource_path('js/barcode-scanner.js')),
            Js::make('driver-offline', resource_path('js/driver-offline.js')),
            // Check photos: full screen with zoom, and Use photo / Retake right after a photo (board 68).
            Js::make('photo-viewer', resource_path('js/photo-viewer.js')),
            // The receiver signs on the driver's phone (Part 44).
            Js::make('sign-pad', resource_path('js/sign-pad.js')),
            // Table searches wait for Enter or the scanner (Part 45).
            Js::make('search-enter', resource_path('js/search-enter.js')),
            // Maps & routes: the stops map (Leaflet 1.9.4 + OpenStreetMap), only on the pages that show it.
            // Kept in resources/vendor so the server does not need node_modules (composer runs
            // filament:upgrade, which publishes these files, before any npm step).
            Js::make('leaflet', resource_path('vendor/leaflet/leaflet.js'))->loadedOnRequest(),
            Css::make('leaflet', resource_path('vendor/leaflet/leaflet.css'))->loadedOnRequest(),
            Js::make('trip-map', resource_path('js/trip-map.js'))->loadedOnRequest(),
            Js::make('truck-map', resource_path('js/truck-map.js'))->loadedOnRequest(),
        ]);
    }
}
DISPATCH_FILE_END_6

# ---------------------------------------------------------------- app/Support/Ai/BoxEmailWriter.php
mkdir -p 'app/Support/Ai'
cat > 'app/Support/Ai/BoxEmailWriter.php' <<'DISPATCH_FILE_END_7'
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
DISPATCH_FILE_END_7

# ---------------------------------------------------------------- app/Support/Ai/EmailLanguages.php
mkdir -p 'app/Support/Ai'
cat > 'app/Support/Ai/EmailLanguages.php' <<'DISPATCH_FILE_END_8'
<?php

namespace App\Support\Ai;

use App\Models\AppSetting;

/** Part 45 (board 73): the languages the AI writes emails to consolidators in; the last one is remembered for each consolidator. */
class EmailLanguages
{
    public const ALL = [
        'en' => ['English', 'English'],
        'tl' => ['Tagalog', 'Tagalog (Filipino)'],
        'ceb' => ['Bisaya', 'Cebuano (Bisaya)'],
        'hil' => ['Ilonggo', 'Hiligaynon (Ilonggo)'],
        'ilo' => ['Ilocano', 'Ilocano (Iloko)'],
        'pag' => ['Pangasinan', 'Pangasinan'],
        'pam' => ['Kapampangan', 'Kapampangan'],
    ];

    /** Languages the AI writes less surely: the person is asked to check, and English below is suggested. */
    public const CHECK = ['pag', 'pam'];

    public static function options(): array
    {
        return array_map(fn ($l) => $l[0], self::ALL);
    }

    public static function name(string $code): string
    {
        return self::ALL[$code][1] ?? 'English';
    }

    public static function for(?int $consolidatorId): string
    {
        $v = $consolidatorId ? (string) AppSetting::get('email.lang.'.$consolidatorId, 'en') : 'en';

        return isset(self::ALL[$v]) ? $v : 'en';
    }

    public static function remember(?int $consolidatorId, string $code): void
    {
        if ($consolidatorId && isset(self::ALL[$code])) {
            AppSetting::put('email.lang.'.$consolidatorId, $code);
        }
    }

    /** The instruction for the AI: write in this language (and the English version under it if asked). */
    public static function instruction(string $code, bool $withEnglish): string
    {
        $name = static::name($code);
        $s = $code === 'en' ? 'Write in clear, simple English.' : "Write the email in {$name}, the way a polite office worker from that region writes. Keep box numbers, container numbers, names and dates exactly as given.";
        if ($withEnglish && $code !== 'en') {
            $s .= ' Then add a line "— English —" and the same email in English.';
        }

        return $s;
    }
}
DISPATCH_FILE_END_8

# ---------------------------------------------------------------- app/Support/Ai/IssueHelper.php
mkdir -p 'app/Support/Ai'
cat > 'app/Support/Ai/IssueHelper.php' <<'DISPATCH_FILE_END_9'
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
DISPATCH_FILE_END_9

# ---------------------------------------------------------------- app/Support/Photos/BoxAlbum.php
mkdir -p 'app/Support/Photos'
cat > 'app/Support/Photos/BoxAlbum.php' <<'DISPATCH_FILE_END_10'
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

        return $invoices->map(function (Invoice $box) use ($scan, $trips, $attempts) {
            $items = collect();
            foreach ($scan->get($box->id, collect()) as $p) {
                $items->push($this->scanItem($p));
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

    protected function scanItem(BoxPhoto $p): array
    {
        return [
            'key' => 'p:'.$p->id, 'kind' => 'scan', 'step' => $p->step,
            'label' => BoxPhoto::SHORT[$p->step] ?? $p->step,
            'condition' => $p->condition, 'note' => $p->note,
            'ref' => $p->reference(), 'place' => $p->place(), 'who' => $p->user?->full_name, 'at' => $p->taken_at,
            'url' => $p->url(), 'download' => $p->downloadUrl(), 'name' => $p->fileName(),
            'disk' => 'box', 'path' => $p->path, 'size' => (int) $p->size,
            'invoice' => $p->invoice, 'photo' => $p,
        ];
    }

    protected function publicItem(string $key, Invoice $box, string $step, string $path, int $n, int $of, array $meta): ?array
    {
        $disk = Storage::disk('public');
        if (! $disk->exists($path)) {
            return null;
        }
        $ext = strtolower(pathinfo($path, PATHINFO_EXTENSION)) ?: 'jpg';

        return [
            'key' => $key, 'kind' => $step, 'step' => $step,
            'label' => $step === 'delivered' ? 'Delivered' : 'Not delivered',
            'condition' => null, 'note' => $meta['note'], 'n' => $n, 'of' => $of,
            'ref' => $meta['ref'], 'place' => null, 'who' => $meta['who'], 'at' => $meta['at'],
            'url' => $disk->url($path), 'download' => $disk->url($path), 'name' => $box->invoice.'_'.$step.'_'.$n.'.'.$ext,
            'disk' => 'public', 'path' => $path, 'size' => (int) rescue(fn () => $disk->size($path), 0, false),
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
DISPATCH_FILE_END_10

# ---------------------------------------------------------------- public/js/app/search-enter.js
mkdir -p 'public/js/app'
cat > 'public/js/app/search-enter.js' <<'DISPATCH_FILE_END_11'
/*
 * Part 45 (board 72): table searches wait for Enter. Filament's "search on blur" field updates when it
 * loses focus; Enter (typed, or sent by a barcode scanner after the code) does that, then the cursor comes back.
 */
(function () {
    if (window.dsSearchEnter) return;
    window.dsSearchEnter = true;
    document.addEventListener('keydown', (e) => {
        const t = e.target;
        if (e.key !== 'Enter' || !t || !t.matches || !t.matches('.fi-ta-search-field input')) return;
        e.preventDefault();
        t.blur();
        setTimeout(() => { try { t.focus({ preventScroll: true }); t.select(); } catch (err) {} }, 250);
    });
})();
DISPATCH_FILE_END_11

# ---------------------------------------------------------------- resources/js/search-enter.js
mkdir -p 'resources/js'
cat > 'resources/js/search-enter.js' <<'DISPATCH_FILE_END_12'
/*
 * Part 45 (board 72): table searches wait for Enter. Filament's "search on blur" field updates when it
 * loses focus; Enter (typed, or sent by a barcode scanner after the code) does that, then the cursor comes back.
 */
(function () {
    if (window.dsSearchEnter) return;
    window.dsSearchEnter = true;
    document.addEventListener('keydown', (e) => {
        const t = e.target;
        if (e.key !== 'Enter' || !t || !t.matches || !t.matches('.fi-ta-search-field input')) return;
        e.preventDefault();
        t.blur();
        setTimeout(() => { try { t.focus({ preventScroll: true }); t.select(); } catch (err) {} }, 250);
    });
})();
DISPATCH_FILE_END_12

# ---------------------------------------------------------------- resources/views/filament/shared/box-photos.blade.php
mkdir -p 'resources/views/filament/shared'
cat > 'resources/views/filament/shared/box-photos.blade.php' <<'DISPATCH_FILE_END_13'
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
DISPATCH_FILE_END_13

# ---------------------------------------------------------------- tests/Feature/SearchAndEmailTest.php
mkdir -p 'tests/Feature'
cat > 'tests/Feature/SearchAndEmailTest.php' <<'DISPATCH_FILE_END_14'
<?php

use App\Filament\Pages\BoxPhotos;
use App\Models\Ai\AiSetting;
use App\Models\BoxPhotoEmail;
use App\Models\Container;
use App\Models\Consolidator;
use App\Models\Invoice;
use App\Models\User;
use App\Support\Ai\EmailLanguages;
use App\Support\Photos\BoxPhotos as Photos;
use Database\Seeders\DemoSeeder;
use Filament\Facades\Filament;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Illuminate\Http\Client\Request;
use Illuminate\Http\UploadedFile;
use Illuminate\Support\Facades\Cache;
use Illuminate\Support\Facades\Http;
use Illuminate\Support\Facades\Mail;
use Illuminate\Support\Facades\Storage;
use Livewire\Livewire;

uses(RefreshDatabase::class);

beforeEach(function () {
    $this->seed(DemoSeeder::class);
    Storage::fake('local');
    Storage::fake('box');
    Mail::fake();
    Filament::setCurrentPanel(Filament::getPanel('admin'));
    $this->admin = User::where('email', 'admin@example.com')->firstOrFail();
    $this->admin->assignRole('super_admin');
    $this->actingAs($this->admin);
    $this->box = Invoice::whereNotNull('container_id')->firstOrFail();
    $this->photo = Photos::store(UploadedFile::fake()->image('p.jpg', 640, 480), 'unload', $this->box, ['container_id' => $this->box->container_id], $this->admin, 'damaged');
    $this->con = Consolidator::first() ?? Consolidator::create(['code' => 'FX', 'company_name' => 'Forex Cargo', 'email' => 'claims@forex.test']);
    $this->con->update(['email' => 'claims@forex.test']);
    Container::whereKey($this->box->container_id)->update(['consolidator_id' => $this->con->id]);
    Invoice::whereKey($this->box->id)->update(['location_code' => $this->con->code]);
});

it('searches only on Enter: nothing while typing, exact box first, at least 3', function () {
    $page = Livewire::test(BoxPhotos::class)
        ->assertSeeHtml('x-model="draft"')->assertDontSeeHtml('wire:model.live.debounce.400ms="q"')
        ->assertSee('Press Enter to search')->assertSee('🔍 Search');

    $page->call('searchFor', 'IN')->assertSet('q', 'IN')->assertSee('Type at least 3 letters or numbers');
    $page->call('searchFor', '  '.$this->box->invoice.' ')->assertSet('q', $this->box->invoice)
        ->assertSee('Exact box')->assertSee($this->photo->fileName());

    // a part of the number: similar numbers, marked as such
    $page->call('searchFor', substr($this->box->invoice, 1))->assertSee('Similar numbers');
    expect(session('box-photos.recent'))->toContain($this->box->invoice);
});

it('makes table searches wait for Enter in Find a box and Box issues', function () {
    expect(file_get_contents(resource_path('js/search-enter.js')))->toContain('.fi-ta-search-field input');
    foreach ([\App\Filament\Resources\Searchinvs\SearchinvResource::class, \App\Filament\Resources\Invoiceissues\InvoiceissueResource::class] as $r) {
        expect(file_get_contents((new ReflectionClass($r))->getFileName()))->toContain('->searchOnBlur()');
    }
});

it('emails the photos of one box from its card, written by AI in the language of the consolidator', function () {
    AiSetting::query()->delete();
    AiSetting::create(['api_key' => 'sk-ant-test', 'features' => ['issues']]);
    (fn () => static::$memo = null)->call(new AiSetting);
    Cache::flush();
    $asked = null;
    Http::fake(function (Request $r) use (&$asked) {
        $asked = $r->data();

        return Http::response(['content' => [['type' => 'text', 'text' => json_encode(['subject' => 'Mga litrato · box', 'body' => "Magandang araw po,\n\nAng box ay may sira."])]], 'stop_reason' => 'end_turn', 'usage' => ['input_tokens' => 5, 'output_tokens' => 5]]);
    });
    $key = 'p:'.$this->photo->id;

    $page = Livewire::test(BoxPhotos::class)->call('searchFor', $this->box->invoice)
        ->assertSee('✉ Email photos')->assertSee('✉ Email this photo')
        ->mountAction('email', ['keys' => [$key]])
        ->assertActionDataSet(['to' => ['claims@forex.test'], 'lang' => 'en', 'keys' => [$key]])
        ->setActionData(['lang' => 'tl', 'english' => true])
        ->callAction(\Filament\Actions\Testing\TestAction::make('aiWrite')->schemaComponent('message', schema: 'mountedActionSchema0'))
        ->assertActionDataSet(['message' => "Magandang araw po,\n\nAng box ay may sira.", 'subject' => 'Mga litrato · box']);

    $d = \App\Support\Ai\BoxEmailWriter::draft((new \App\Support\Photos\BoxAlbum($this->admin))->resolve([$key]), 'tl', true);
    expect($d)->toBe(['subject' => 'Mga litrato · box', 'body' => "Magandang araw po,\n\nAng box ay may sira."]);
    expect(json_encode($asked))->toContain('Tagalog')->toContain('English')->toContain($this->box->invoice);
});

it('remembers the language for the consolidator and sends the email', function () {
    $key = 'p:'.$this->photo->id;
    Livewire::test(BoxPhotos::class)->call('searchFor', $this->box->invoice)
        ->callAction('email', ['to' => ['claims@forex.test'], 'lang' => 'ilo', 'english' => false, 'subject' => 'Ladawan', 'message' => 'Naimbag nga aldaw', 'keys' => [$key]], ['keys' => [$key]])
        ->assertHasNoActionErrors();

    expect(BoxPhotoEmail::firstOrFail()->photo_ids)->toBe([$key])
        ->and(EmailLanguages::for($this->con->id))->toBe('ilo');
});
DISPATCH_FILE_END_14

echo "▶ Rebuilding the design"
npm run build

echo "▶ Clearing caches"
php artisan optimize:clear

echo "▶ Running the tests"
php artisan test || echo "Some tests failed — send the red text for help."

echo
echo "✓ Done. Backup: $BACKUP"
echo "  Start the app with:  PHP_CLI_SERVER_WORKERS=4 php artisan serve   (or open https://dispatchsystem.test in Herd)"
