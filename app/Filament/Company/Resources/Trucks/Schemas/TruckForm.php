<?php

namespace App\Filament\Company\Resources\Trucks\Schemas;

use Filament\Forms\Components\DatePicker;
use Filament\Forms\Components\FileUpload;
use Filament\Forms\Components\MarkdownEditor;
use Filament\Forms\Components\TextInput;
use Filament\Forms\Components\Toggle;
use Filament\Schemas\Components\Group;
use Filament\Schemas\Components\Section;
use Filament\Schemas\Schema;

class TruckForm
{
    public static function configure(Schema $schema): Schema
    {
        return $schema
            ->components([
                Group::make()
                    ->schema([
                        \App\Filament\Shared\Trucks\OwnershipSection::make(),
                        Section::make('vehicles Information')
                            ->schema([
                                TextInput::make('category')
                                    ->hint('Ex. Ten Wheeler, Truck, Mini Truck or Van')
                                    ->hintColor('warning')
                                    ->hintIcon('heroicon-m-truck')
                                    ->required()
                                    ->maxLength(255),
                                TextInput::make('description')
                                    ->hint('Ex Brand, Color, Model')
                                    ->hintColor('warning')
                                    ->hintIcon('heroicon-m-truck')
                                    ->required()
                                    ->maxLength(255),
                                TextInput::make('registration_no')
                                    ->label('Registration Number')
                                    ->required()
                                    ->maxLength(255),
                                TextInput::make('plate_no')
                                    ->label('Plate Number')
                                    ->required()
                                    ->maxLength(255),
                                TextInput::make('capacity')
                                    ->label(fn () => \App\Support\BoxSizes::on() ? 'Capacity (space, in normal boxes)' : 'Capacity (boxes)')
                                    ->numeric()
                                    ->minValue(1)
                                    ->placeholder('60')
                                    ->helperText(fn () => \App\Support\BoxSizes::on()
                                        ? 'How many of your normal box fit. Bigger boxes take more space: Settings → Box sizes. Empty means 50.'
                                        : 'About how many boxes fit. Used to plan trips; empty means 50.'),
                                MarkdownEditor::make('Note')
                                    ->columnSpanFull(),
                            ]),

                    ]),
                Group::make()
                    ->schema([
                        Section::make('Other Information')
                            ->schema([
                                FileUpload::make('truck_picture')
                                    ->image()
                                    ->avatar()
                                    ->imageEditor()
                                    ->circleCropper()
                                    ->uploadingMessage('Uploading attachment...')
                                    ->openable()
                                    ->maxSize(1024)
                                    ->disk('public')
                                    ->directory('truckypictures')
                                    ->visibility('private')
                                    ->removeUploadedFileButtonPosition('right')
                                    ->label('Vehicles Picture')
                                    ->columnSpanFull(),
                                DatePicker::make('date_registered')
                                    ->native(false)
                                    ->closeOnDateSelection(true)
                                    ->label('Date Register')
                                    ->required(),
                                DatePicker::make('date_expired')
                                    ->label('Registration Expiration Date')
                                    ->native(false)
                                    ->closeOnDateSelection(true)
                                    ->required()
                                    ->rules(['after_or_equal:today']),
                                Toggle::make('is_active')
                                    ->default(true)
                                    ->required(),
                            ]),

                    ]),

            ]);
    }
}
