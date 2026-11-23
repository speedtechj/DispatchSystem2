<?php

namespace App\Filament\Resources\UserResource\Pages;

use App\Filament\Resources\UserResource;
use App\Models\User;
use App\Support\People\People;
use Filament\Actions\CreateAction;
use Filament\Resources\Pages\ListRecords;
use Filament\Schemas\Components\Tabs\Tab;
use Illuminate\Contracts\Pagination\CursorPaginator;
use Illuminate\Contracts\Pagination\Paginator;
use Illuminate\Contracts\Support\Htmlable;
use Illuminate\Database\Eloquent\Builder;
use Illuminate\Database\Eloquent\Collection;

/** Users (board 59): a tab per panel (from Settings → Panel categories) and Turned off. */
class ListUsers extends ListRecords
{
    protected static string $resource = UserResource::class;

    /** @var array<int, int>|null last activity per user on this page */
    protected ?array $seen = null;

    public function getSubheading(): string|Htmlable|null
    {
        $all = User::count();

        return $all.' '.str('person')->plural($all).' · '.User::where('is_active', true)->count().' active';
    }

    protected function getHeaderActions(): array
    {
        return [
            CreateAction::make()->label('New user')->icon('heroicon-m-plus')
                ->slideOver()->modalWidth('2xl')->modalHeading('Add a person')
                ->modalDescription('They sign in with their email and password. You can change everything later.')
                ->modalSubmitActionLabel('Create user')->createAnother(false),
        ];
    }

    public function getTabs(): array
    {
        $count = fn (callable $q) => $q(User::query())->count();
        $tabs = ['all' => Tab::make('All')->badge($count(fn ($q) => $q))];
        foreach (People::panels() as $p) {
            $n = $count(fn ($q) => $q->where('is_active', true)->where('panelcategory_id', $p->id));
            if ($n || in_array($p->code, People::WITH_APP, true)) {
                $tabs['p'.$p->id] = Tab::make(People::look($p)['label'])->badge($n)
                    ->modifyQueryUsing(fn (Builder $query) => $query->where('is_active', true)->where('panelcategory_id', $p->id));
            }
        }
        $tabs['off'] = Tab::make('Turned off')->badge($count(fn ($q) => $q->where('is_active', false)))
            ->modifyQueryUsing(fn (Builder $query) => $query->where('is_active', false));

        return $tabs;
    }

    /** Last activity of the people on this page, in one question. */
    public function lastActive(): array
    {
        return $this->seen ??= People::lastActive($this->pageIds());
    }

    protected function pageIds(): array
    {
        $records = $this->getTableRecords();
        $items = $records instanceof Paginator || $records instanceof CursorPaginator ? $records->items() : ($records instanceof Collection ? $records->all() : []);

        return array_map(fn ($u) => (int) $u->getKey(), $items);
    }
}
