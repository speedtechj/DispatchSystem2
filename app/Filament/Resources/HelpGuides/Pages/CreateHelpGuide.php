<?php

namespace App\Filament\Resources\HelpGuides\Pages;

use App\Filament\Resources\HelpGuides\HelpGuideResource;
use Filament\Resources\Pages\CreateRecord;
use Illuminate\Support\Facades\Auth;

class CreateHelpGuide extends CreateRecord
{
    protected static string $resource = HelpGuideResource::class;

    protected function mutateFormDataBeforeCreate(array $data): array
    {
        return HelpGuideResource::stepsForSave($data) + ['updated_by' => Auth::id()];
    }
}
