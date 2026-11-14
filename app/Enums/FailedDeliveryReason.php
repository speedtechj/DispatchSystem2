<?php

namespace App\Enums;

use Filament\Support\Contracts\HasColor;
use Filament\Support\Contracts\HasIcon;
use Filament\Support\Contracts\HasLabel;
use Filament\Support\Icons\Heroicon;

/**
 * Why a driver could not hand a box over.
 */
enum FailedDeliveryReason: string implements HasColor, HasIcon, HasLabel
{
    case NoOneHome = 'no_one_home';
    case AddressNotFound = 'address_not_found';
    case PhoneUnreachable = 'phone_unreachable';
    case Refused = 'refused';
    case Rescheduled = 'rescheduled';
    case AreaInaccessible = 'area_inaccessible';
    case BoxDamaged = 'box_damaged';
    case OutOfTime = 'out_of_time';
    case Other = 'other';

    public function getLabel(): string
    {
        return match ($this) {
            self::NoOneHome => 'No one home',
            self::AddressNotFound => 'Address not found',
            self::PhoneUnreachable => 'Phone wrong / not answering',
            self::Refused => 'Receiver refused',
            self::Rescheduled => 'Asked for another day',
            self::AreaInaccessible => "Can't reach the area",
            self::BoxDamaged => 'Box damaged',
            self::OutOfTime => 'Ran out of time',
            self::Other => 'Other',
        };
    }

    /** One line under the button, so drivers pick the right one. */
    public function getDescription(): string
    {
        return match ($this) {
            self::NoOneHome => 'Nobody there to receive the box.',
            self::AddressNotFound => 'Address is wrong, incomplete or could not be found.',
            self::PhoneUnreachable => 'Could not call the receiver to find them.',
            self::Refused => 'Receiver did not accept the box.',
            self::Rescheduled => 'Receiver asked to deliver on a different day.',
            self::AreaInaccessible => 'Flood, road closed, or gated area would not let the truck in.',
            self::BoxDamaged => 'Box is damaged and was not handed over.',
            self::OutOfTime => 'Did not reach this stop today.',
            self::Other => 'Something else — explain in the note.',
        };
    }

    public function getIcon(): Heroicon
    {
        return match ($this) {
            self::NoOneHome => Heroicon::OutlinedHome,
            self::AddressNotFound => Heroicon::OutlinedMapPin,
            self::PhoneUnreachable => Heroicon::OutlinedPhoneXMark,
            self::Refused => Heroicon::OutlinedHandRaised,
            self::Rescheduled => Heroicon::OutlinedCalendarDays,
            self::AreaInaccessible => Heroicon::OutlinedNoSymbol,
            self::BoxDamaged => Heroicon::OutlinedExclamationTriangle,
            self::OutOfTime => Heroicon::OutlinedClock,
            self::Other => Heroicon::OutlinedChatBubbleLeftEllipsis,
        };
    }

    public function getColor(): string
    {
        return match ($this) {
            self::Rescheduled, self::OutOfTime => 'warning',
            self::BoxDamaged, self::Refused => 'danger',
            default => 'gray',
        };
    }

    /** A photo is proof the driver was there (house, gate, flooded road, damage). */
    public function requiresPhoto(): bool
    {
        return in_array($this, [self::NoOneHome, self::AddressNotFound, self::AreaInaccessible, self::BoxDamaged], true);
    }

    public function requiresNote(): bool
    {
        return in_array($this, [self::Refused, self::Rescheduled, self::Other], true);
    }

    public function notePrompt(): string
    {
        return match ($this) {
            self::Rescheduled => 'Which day did they ask for?',
            self::Refused => 'Why did they refuse?',
            default => 'What happened?',
        };
    }
}
