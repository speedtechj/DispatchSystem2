<?php

namespace App\Filament\Resources\HelpGuides;

use App\Filament\Resources\HelpGuides\Pages\CreateHelpGuide;
use App\Filament\Resources\HelpGuides\Pages\EditHelpGuide;
use App\Filament\Resources\HelpGuides\Pages\ListHelpGuides;
use App\Models\Help\HelpGuide;
use App\Support\Help\DefaultGuides;
use App\Support\Help\Help;
use BackedEnum;
use Filament\Actions\Action;
use Filament\Actions\DeleteAction;
use Filament\Actions\EditAction;
use Filament\Forms\Components\CheckboxList;
use Filament\Forms\Components\FileUpload;
use Filament\Forms\Components\Hidden;
use Filament\Forms\Components\Repeater;
use Filament\Forms\Components\Select;
use Filament\Forms\Components\TagsInput;
use Filament\Forms\Components\Textarea;
use Filament\Forms\Components\TextInput;
use Filament\Forms\Components\Toggle;
use Filament\Resources\Resource;
use Filament\Schemas\Components\Grid;
use Filament\Schemas\Components\Section;
use Filament\Schemas\Components\Tabs;
use Filament\Schemas\Components\Tabs\Tab;
use Filament\Schemas\Schema;
use Filament\Support\Icons\Heroicon;
use Filament\Tables\Columns\IconColumn;
use Filament\Tables\Columns\TextColumn;
use Filament\Tables\Filters\SelectFilter;
use Filament\Tables\Table;
use Illuminate\Database\Eloquent\Builder;
use Illuminate\Database\Eloquent\Model;
use Illuminate\Support\Facades\Auth;
use Illuminate\Support\Str;
use UnitEnum;

/** Admin → Settings → Help guides: edit the guides, add screenshots, write new ones. */
class HelpGuideResource extends Resource
{
    protected static ?string $model = HelpGuide::class;

    protected static ?string $slug = 'help-guides';

    protected static string|UnitEnum|null $navigationGroup = 'Settings';

    protected static string|BackedEnum|null $navigationIcon = Heroicon::OutlinedBookOpen;

    protected static ?string $navigationLabel = 'Help guides';

    protected static ?string $modelLabel = 'help guide';

    protected static ?int $navigationSort = 98;

    public static function canViewAny(): bool
    {
        return (bool) Auth::user()?->hasRole('super_admin');
    }

    public static function canCreate(): bool
    {
        return static::canViewAny();
    }

    public static function canEdit(Model $record): bool
    {
        return static::canViewAny();
    }

    public static function canDelete(Model $record): bool
    {
        return static::canViewAny();
    }

    public static function form(Schema $schema): Schema
    {
        $apps = Help::APP_NAMES;
        $topics = collect(DefaultGuides::TOPICS)->map(fn ($t) => $t[0].' '.$t[1])->all();

        return $schema->components([
            Section::make('Who sees it')->columns(3)->schema([
                TextInput::make('title_en')->label('Title (English)')->required()->maxLength(255)
                    ->live(onBlur: true)
                    ->afterStateUpdated(fn ($state, $set, $get, ?HelpGuide $record) => $record ? null : ($get('slug') ? null : $set('slug', Str::slug((string) $state)))),
                TextInput::make('slug')->label('Short name (in the link)')->required()->maxLength(80)->alphaDash()->unique(ignoreRecord: true),
                TextInput::make('icon')->label('Icon (an emoji)')->maxLength(16)->placeholder('📦'),
                Select::make('topic')->options($topics)->required()->default('boxes'),
                TextInput::make('sort')->numeric()->default(100)->helperText('Lower comes first in its topic.'),
                Toggle::make('is_published')->label('Shown to users')->default(true)->inline(false),
                CheckboxList::make('apps')->label('Show in')->options($apps)->required()->columns(5)->columnSpanFull(),
            ]),
            Tabs::make('lang')->columnSpanFull()->tabs([
                Tab::make('English')->schema([
                    Textarea::make('summary_en')->label('In one or two sentences')->rows(2)->required(),
                    Textarea::make('when_en')->label('When to use it')->rows(2),
                    Textarea::make('result_en')->label('What you get at the end')->rows(2),
                ]),
                Tab::make('Tagalog')->schema([
                    TextInput::make('title_tl')->label('Title (Tagalog)')->maxLength(255),
                    Textarea::make('summary_tl')->label('Sa isa o dalawang pangungusap')->rows(2),
                    Textarea::make('when_tl')->label('Kailan gagamitin')->rows(2),
                    Textarea::make('result_tl')->label('Resulta')->rows(2),
                ])->badge(fn ($get) => $get('title_tl') ? null : 'empty'),
            ]),
            Section::make('Steps')->description('In order. Add a screenshot to a step if it helps.')->schema([
                Repeater::make('steps')->hiddenLabel()->reorderable()->collapsible()->cloneable()
                    ->itemLabel(fn (array $state) => $state['title_en'] ?? null)
                    ->addActionLabel('Add a step')
                    ->schema([
                        Grid::make(2)->schema([
                            TextInput::make('title_en')->label('Step (English)')->required(),
                            TextInput::make('title_tl')->label('Hakbang (Tagalog)'),
                            Textarea::make('text_en')->label('What to do (English)')->rows(2)->required(),
                            Textarea::make('text_tl')->label('Gagawin (Tagalog)')->rows(2),
                        ]),
                        FileUpload::make('image')->label('Screenshot')->image()->disk('public')->directory('help')->maxSize(4096)
                            ->helperText(fn ($get) => $get('builtin_image') ? 'This step has a built-in screenshot. Upload one to replace it.' : null),
                        Hidden::make('builtin_image'),
                    ]),
            ]),
            Section::make('If something goes wrong')->collapsed()->schema([
                Repeater::make('problems')->hiddenLabel()->defaultItems(0)->collapsible()->addActionLabel('Add a problem')
                    ->itemLabel(fn (array $state) => $state['q_en'] ?? null)
                    ->schema([Grid::make(2)->schema([
                        TextInput::make('q_en')->label('Problem (English)')->required(),
                        TextInput::make('q_tl')->label('Problema (Tagalog)'),
                        Textarea::make('a_en')->label('What to do (English)')->rows(2)->required(),
                        Textarea::make('a_tl')->label('Gagawin (Tagalog)')->rows(2),
                    ])]),
            ]),
            Section::make('Links')->collapsed()->columns(2)->schema([
                TagsInput::make('pages')->label('Pages where "?" opens this guide')
                    ->helperText('Page names like pages.scanload or resources.deliverylogs.* (the part after the panel in the route name).'),
                TagsInput::make('related')->label('Related guides (short names)')
                    ->suggestions(fn () => HelpGuide::pluck('slug')->all()),
            ]),
        ]);
    }

    /** Edit form: built-in screenshots (public/images/help) are kept aside, so the upload box only holds uploads. */
    public static function stepsForForm(array $data): array
    {
        $data['steps'] = collect($data['steps'] ?? [])->map(function ($s) {
            $img = $s['image'] ?? null;
            if (is_string($img) && str_starts_with($img, 'images/')) {
                $s['builtin_image'] = $img;
                $s['image'] = null;
            }

            return $s;
        })->all();

        return $data;
    }

    /** Saving: an uploaded screenshot wins; with no upload the built-in one stays. */
    public static function stepsForSave(array $data): array
    {
        $data['steps'] = collect($data['steps'] ?? [])->map(function ($s) {
            $img = $s['image'] ?? null;
            if (is_array($img)) {
                $img = reset($img) ?: null;
            }
            $s['image'] = $img ?: ($s['builtin_image'] ?? null);
            unset($s['builtin_image']);

            return $s;
        })->values()->all();
        $data['problems'] = array_values($data['problems'] ?? []);

        return $data;
    }

    public static function table(Table $table): Table
    {
        return $table
            ->defaultSort('topic')
            ->columns([
                TextColumn::make('icon')->label(''),
                TextColumn::make('title_en')->label('Guide')->searchable(['title_en', 'title_tl', 'summary_en'])->description(fn (HelpGuide $r) => $r->title_tl),
                TextColumn::make('topic')->formatStateUsing(fn ($state) => DefaultGuides::TOPICS[$state][1] ?? Str::headline($state))->sortable(),
                TextColumn::make('apps')->label('Shown in')->badge()->formatStateUsing(fn ($state) => Help::APP_NAMES[$state] ?? $state),
                TextColumn::make('steps')->label('Steps')->state(fn (HelpGuide $r) => count($r->steps ?? [])),
                TextColumn::make('views')->label('Opened')->sortable(),
                TextColumn::make('helpful')->label('Helpful')->state(fn (HelpGuide $r) => $r->helpful_yes + $r->helpful_no ? '👍 '.$r->helpful_yes.' · 👎 '.$r->helpful_no : '—'),
                IconColumn::make('is_published')->label('Shown')->boolean(),
                TextColumn::make('updated_at')->label('Changed')->since()->sortable()->toggleable(isToggledHiddenByDefault: true),
            ])
            ->filters([
                SelectFilter::make('topic')->options(collect(DefaultGuides::TOPICS)->map(fn ($t) => $t[1])->all()),
                SelectFilter::make('app')->label('Shown in')->options(Help::APP_NAMES)
                    ->query(fn (Builder $q, array $data) => $data['value'] ? $q->whereJsonContains('apps', $data['value']) : $q),
            ])
            ->recordActions([
                Action::make('view')->label('View')->icon(Heroicon::OutlinedEye)->color('gray')
                    ->url(fn (HelpGuide $r) => Help::centerUrl('admin', $r->slug)),
                EditAction::make(),
                DeleteAction::make(),
            ]);
    }

    public static function getPages(): array
    {
        return [
            'index' => ListHelpGuides::route('/'),
            'create' => CreateHelpGuide::route('/create'),
            'edit' => EditHelpGuide::route('/{record}/edit'),
        ];
    }
}
