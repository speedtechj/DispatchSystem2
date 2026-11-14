<?php

namespace App\Filament\Company\Resources\Deliverylogs;

use App\Filament\Company\Resources\Deliverylogs\Pages\CreateDeliverylog;
use App\Filament\Company\Resources\Deliverylogs\Pages\EditDeliverylog;
use App\Filament\Company\Resources\Deliverylogs\Pages\ListDeliverylogs;
use App\Filament\Company\Resources\Deliverylogs\RelationManagers\TripinvoicesRelationManager as RelationManagersTripinvoicesRelationManager;
use App\Filament\Company\Resources\Deliverylogs\Schemas\DeliverylogForm;
use App\Filament\Company\Resources\Deliverylogs\Tables\DeliverylogsTable;
use App\Models\Deliverylog;
use BackedEnum;
use Filament\Resources\Resource;
use Filament\Schemas\Schema;
use Filament\Support\Icons\Heroicon;
use Filament\Tables\Table;
use Illuminate\Database\Eloquent\Builder;
use Illuminate\Support\Facades\Auth;

class DeliverylogResource extends Resource
{
    protected static ?string $model = Deliverylog::class;

    protected static string|BackedEnum|null $navigationIcon = Heroicon::OutlinedRectangleStack;

    protected static ?string $recordTitleAttribute = 'id';

    public static function form(Schema $schema): Schema
    {
        return DeliverylogForm::configure($schema);
    }

    public static function table(Table $table): Table
    {
        return DeliverylogsTable::configure($table);
    }

    public static function getRelations(): array
    {
        return [
            RelationManagersTripinvoicesRelationManager::class,
        ];
    }

    public static function getPages(): array
    {
        return [
            'index' => ListDeliverylogs::route('/'),
            'create' => CreateDeliverylog::route('/create'),
            'edit' => EditDeliverylog::route('/{record}/edit'),
        ];
    }

    /**
     * Users only ever see (and can only open) trips that belong to their own hub.
     */
    public static function getEloquentQuery(): Builder
    {
        return parent::getEloquentQuery()->where('logistichub_id', Auth::user()?->logistichub_id);
    }
}
