<?php

namespace App\Filament\Resources\HelpGuides\Pages;

use App\Filament\Resources\HelpGuides\HelpGuideResource;
use App\Support\Help\Help;
use Filament\Actions\Action;
use Filament\Actions\DeleteAction;
use Filament\Resources\Pages\EditRecord;
use Illuminate\Support\Facades\Auth;

class EditHelpGuide extends EditRecord
{
    protected static string $resource = HelpGuideResource::class;

    protected function mutateFormDataBeforeFill(array $data): array
    {
        return HelpGuideResource::stepsForForm($data);
    }

    protected function mutateFormDataBeforeSave(array $data): array
    {
        $data = HelpGuideResource::stepsForSave($data);
        $data['updated_by'] = Auth::id();

        return $data;
    }

    protected function getHeaderActions(): array
    {
        return [
            Action::make('view')->label('View guide')->color('gray')->url(fn () => Help::centerUrl('admin', $this->record->slug)),
            DeleteAction::make(),
        ];
    }
}
