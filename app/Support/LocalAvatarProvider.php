<?php

namespace App\Support;

use Filament\AvatarProviders\Contracts\AvatarProvider;
use Filament\Facades\Filament;
use Illuminate\Contracts\Auth\Authenticatable;
use Illuminate\Database\Eloquent\Model;

/** The round initials picture in the top bar, drawn by the app (no call to ui-avatars.com). */
class LocalAvatarProvider implements AvatarProvider
{
    public function get(Model|Authenticatable $record): string
    {
        $initials = str(Filament::getNameForDefaultAvatar($record))->trim()->explode(' ')
            ->filter()->map(fn (string $w) => mb_strtoupper(mb_substr($w, 0, 1)))->take(2)->join('');
        $initials = htmlspecialchars($initials ?: '?', ENT_QUOTES | ENT_XML1);

        $svg = '<svg xmlns="http://www.w3.org/2000/svg" width="64" height="64" viewBox="0 0 64 64">'
            .'<rect width="64" height="64" fill="#0e2433"/>'
            .'<text x="32" y="33" dy=".35em" text-anchor="middle" font-family="Archivo, Arial, sans-serif" font-size="26" font-weight="700" fill="#f6be00">'.$initials.'</text></svg>';

        return 'data:image/svg+xml;base64,'.base64_encode($svg);
    }
}
