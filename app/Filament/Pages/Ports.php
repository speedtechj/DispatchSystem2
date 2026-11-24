<?php

namespace App\Filament\Pages;

use App\Models\Shipping\Port;
use BackedEnum;
use Filament\Actions\Action;
use Filament\Forms\Components\Select;
use Filament\Forms\Components\TextInput;
use Filament\Forms\Components\Toggle;
use Filament\Notifications\Notification;
use Filament\Pages\Page;
use Filament\Schemas\Components\Grid;
use Filament\Support\Icons\Heroicon;
use Illuminate\Support\Facades\Auth;
use Illuminate\Support\Facades\Schema;

/** Settings → Ports (board 64): where the truck takes the van, and where it arrives. */
class Ports extends Page
{
    protected string $view = 'filament.shipping.ports';

    protected static string|BackedEnum|null $navigationIcon = Heroicon::OutlinedMapPin;

    protected static ?string $title = 'Ports';

    protected static ?string $slug = 'ports';

    public static function canAccess(): bool
    {
        return Schema::hasTable('ports') && (bool) Auth::user()?->is_admin;
    }

    protected function schema(): array
    {
        return [
            Grid::make(2)->schema([
                TextInput::make('name')->label('Port')->required()->maxLength(80)->placeholder('Manila North Harbor'),
                Select::make('kind')->label('For')->options(Port::KINDS)->default('both')->required(),
            ]),
            TextInput::make('address')->maxLength(200),
            Grid::make(2)->schema([TextInput::make('lat')->label('Map pin · lat')->numeric(), TextInput::make('lng')->label('lng')->numeric()]),
            Toggle::make('is_active')->label('Active')->default(true),
        ];
    }

    public function newAction(): Action
    {
        return Action::make('new')->label('New port')->icon('heroicon-m-plus')->modalWidth('lg')->modalHeading('New port')
            ->schema($this->schema())
            ->action(fn (array $data) => Port::create($data) && Notification::make()->title('Port added')->success()->send());
    }

    public function editAction(): Action
    {
        return Action::make('edit')->modalWidth('lg')->modalHeading('Port')
            ->fillForm(fn (array $arguments) => Port::find($arguments['id'] ?? 0)?->only(['name', 'kind', 'address', 'lat', 'lng', 'is_active']) ?? [])
            ->schema($this->schema())
            ->action(fn (array $data, array $arguments) => Port::find($arguments['id'] ?? 0)?->update($data));
    }

    protected function getViewData(): array
    {
        return ['ports' => Port::orderByDesc('is_active')->orderBy('name')->get()];
    }
}
