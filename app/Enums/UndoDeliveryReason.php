<?php

namespace App\Enums;

use Filament\Support\Contracts\HasLabel;

/**
 * Why a delivery was undone.
 */
enum UndoDeliveryReason: string implements HasLabel
{
    case TappedByMistake = 'tapped_by_mistake';
    case WrongBox = 'wrong_box';
    case NotHandedOver = 'not_handed_over';
    case ReceiverChangedMind = 'receiver_changed_mind';
    case ReceiverDidNotGetIt = 'receiver_did_not_get_it';
    case WrongAddress = 'wrong_address';
    case Other = 'other';

    public function getLabel(): string
    {
        return match ($this) {
            self::TappedByMistake => 'Undone right away (tapped by mistake)',
            self::WrongBox => 'Wrong box was scanned or tapped',
            self::NotHandedOver => 'Box was not actually handed over',
            self::ReceiverChangedMind => 'Receiver changed their mind',
            self::ReceiverDidNotGetIt => 'Receiver says they did not get the box',
            self::WrongAddress => 'Delivered to the wrong address',
            self::Other => 'Other',
        };
    }

    /** @return array<string, string> choices shown to drivers */
    public static function driverOptions(): array
    {
        return self::options([self::WrongBox, self::NotHandedOver, self::ReceiverChangedMind, self::Other]);
    }

    /** @return array<string, string> choices shown to the office */
    public static function officeOptions(): array
    {
        return self::options([self::ReceiverDidNotGetIt, self::WrongBox, self::WrongAddress, self::NotHandedOver, self::Other]);
    }

    public function requiresNote(): bool
    {
        return $this === self::Other;
    }

    /** @param  array<int, self>  $cases */
    protected static function options(array $cases): array
    {
        return collect($cases)->mapWithKeys(fn (self $case) => [$case->value => $case->getLabel()])->all();
    }
}
