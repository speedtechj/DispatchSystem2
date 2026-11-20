<?php

namespace App\Filament\Shared\Trucks;

use App\Models\RentalCompany;
use App\Support\Rentals;
use Filament\Forms\Components\Select;
use Filament\Forms\Components\TextInput;
use Filament\Forms\Components\ToggleButtons;
use Filament\Schemas\Components\Section;
use Filament\Schemas\Components\Utilities\Get;
use Illuminate\Support\Facades\Auth;

/** Truck form: who owns it (own or rental), the rental company, how it charges and the rental driver. */
class OwnershipSection
{
    public static function make(): Section
    {
        $rental = fn (Get $get) => $get('ownership') === 'rental';

        return Section::make('Who owns this truck')
            ->visible(fn () => Rentals::ready())
            ->columns(2)
            ->schema([
                ToggleButtons::make('ownership')->label('')->options(['own' => 'Own', 'rental' => 'Rental'])->default('own')->inline()->live()->columnSpanFull(),
                Select::make('rental_company_id')->label('Rental company')->visible($rental)->required($rental)
                    ->options(fn () => Rentals::companies(Auth::user()?->logistichub_id ? (int) Auth::user()->logistichub_id : null)->pluck('name', 'id'))
                    ->searchable()
                    ->createOptionForm([
                        TextInput::make('name')->required(),
                        TextInput::make('contact_name')->label('Contact person'),
                        TextInput::make('phone'),
                    ])
                    ->createOptionUsing(fn (array $data) => RentalCompany::create($data + ['logistichub_id' => Auth::user()?->logistichub_id])->id),
                TextInput::make('rental_driver')->label('Rental driver (default)')->visible($rental),
                TextInput::make('rate_trip')->label('Per trip (₱)')->numeric()->minValue(0)->visible($rental),
                TextInput::make('rate_day')->label('Per day (₱)')->numeric()->minValue(0)->visible($rental),
                TextInput::make('rate_km')->label('Per km (₱)')->numeric()->minValue(0)->visible($rental)
                    ->helperText('Fill one or more. A trip uses per trip first, then per day, then per km.'),
                TextInput::make('make_model')->label('Make and model')->placeholder('Isuzu Elf'),
            ]);
    }
}
