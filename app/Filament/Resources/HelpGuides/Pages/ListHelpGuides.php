<?php

namespace App\Filament\Resources\HelpGuides\Pages;

use App\Filament\Resources\HelpGuides\HelpGuideResource;
use App\Support\Help\Help;
use Filament\Actions\Action;
use Filament\Actions\CreateAction;
use Filament\Notifications\Notification;
use Filament\Resources\Pages\ListRecords;

class ListHelpGuides extends ListRecords
{
    protected static string $resource = HelpGuideResource::class;

    protected function getHeaderActions(): array
    {
        return [
            Action::make('defaults')->label('Add missing built-in guides')->color('gray')
                ->requiresConfirmation()
                ->modalDescription('Guides you deleted come back. Guides you changed are not touched.')
                ->action(function () {
                    $n = Help::installDefaults();
                    Notification::make()->title($n ? "{$n} guides added" : 'All built-in guides are already here')->success()->send();
                }),
            CreateAction::make()->label('New guide'),
        ];
    }
}
