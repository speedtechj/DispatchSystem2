<?php

namespace App\Filament\Shared\Ai;

use App\Mail\BoxPhotosMail;
use App\Models\BoxPhotoEmail;
use App\Models\Invoiceissue;
use App\Support\Ai\Ai;
use App\Support\Ai\AiUnavailable;
use App\Support\Ai\IssueHelper;
use App\Support\Photos\BoxAlbum;
use Filament\Actions\Action;
use Filament\Forms\Components\Textarea;
use Filament\Forms\Components\TextInput;
use Filament\Forms\Components\Toggle;
use Filament\Forms\Components\ToggleButtons;
use Filament\Schemas\Components\Utilities\Get;
use Filament\Schemas\Components\Utilities\Set;
use App\Support\Ai\EmailLanguages;
use Filament\Notifications\Notification;
use Filament\Schemas\Components\Text;
use Filament\Support\Icons\Heroicon;
use Illuminate\Support\Facades\Auth;
use Illuminate\Support\Facades\Mail;
use Throwable;

/** "AI helper" on an Invoice Issue: summary, next step, and the email to the consolidator with the photos. */
class IssueHelperAction
{
    public static function make(): Action
    {
        return Action::make('aiHelper')
            ->label('AI helper')
            ->icon(Heroicon::OutlinedSparkles)
            ->color('info')
            ->visible(fn () => Ai::switchedOn('issues'))
            ->modalHeading(fn (Invoiceissue $record) => 'Box '.$record->invoice)
            ->modalSubmitActionLabel('Send email')
            ->modalWidth('2xl')
            ->fillForm(function (Invoiceissue $record): array {
                $lang = EmailLanguages::for(static::consolidatorId($record));
                try {
                    $d = IssueHelper::draft($record, $lang);
                } catch (AiUnavailable $e) {
                    return ['summary' => $e->getMessage(), 'next' => '', 'to' => '', 'subject' => 'Box '.$record->invoice, 'body' => '', 'photos' => true, 'lang' => $lang, 'english' => false];
                }

                return ['summary' => $d['summary'], 'next' => $d['next'], 'to' => $d['to'], 'subject' => $d['subject'], 'body' => $d['body'], 'photos' => true, 'lang' => $lang, 'english' => false];
            })
            ->schema([
                Textarea::make('summary')->label('AI summary')->rows(2)->disabled()->dehydrated(false),
                Textarea::make('next')->label('Suggested next step')->rows(2)->disabled()->dehydrated(false),
                TextInput::make('to')->label('To (consolidator email)')->email()->required(),
                // Part 45: the email in the consolidator's language (remembered), English below if asked
                ToggleButtons::make('lang')->label('Language of the email')->options(EmailLanguages::options())->inline()->live()
                    ->helperText(fn (Get $get) => in_array($get('lang'), EmailLanguages::CHECK, true)
                        ? 'The AI writes this language less surely: read it before sending, or tick Add English below.' : null),
                Toggle::make('english')->label('Add English below')->inline(),
                TextInput::make('subject')->required()->maxLength(200),
                Textarea::make('body')->label('Email (written by AI · edit as you like)')->rows(10)->required()
                    ->hintAction(Action::make('rewrite')->label('✨ Write again in this language')->color('info')
                        ->action(function (Invoiceissue $record, Get $get, Set $set) {
                            try {
                                $d = IssueHelper::draft($record, (string) $get('lang'), (bool) $get('english'));
                            } catch (AiUnavailable $e) {
                                Notification::make()->title('The AI helper is not available')->body($e->getMessage())->warning()->send();

                                return;
                            }
                            $set('subject', $d['subject']);
                            $set('body', $d['body']);
                        })),
                Toggle::make('photos')->label('Attach the box photos'),
                Text::make('The email is only sent when you press Send.'),
            ])
            ->action(function (Invoiceissue $record, array $data): void {
                EmailLanguages::remember(static::consolidatorId($record), (string) ($data['lang'] ?? 'en'));
                $photos = collect();
                if ($data['photos'] ?? false) {
                    $photos = (new BoxAlbum(Auth::user()))->forInvoice($record->invoice_id)->take(15);
                }
                $log = BoxPhotoEmail::create([
                    'user_id' => Auth::id(), 'recipients' => [$data['to']], 'subject' => $data['subject'],
                    'message' => $data['body'], 'photo_ids' => $photos->pluck('key')->all(),
                ]);
                try {
                    Mail::to($data['to'])->send(new BoxPhotosMail($data['subject'], $data['body'], $photos, Auth::user()?->full_name));
                    $log->update(['status' => 'sent']);
                } catch (Throwable $e) {
                    report($e);
                    $log->update(['status' => 'failed', 'error' => mb_substr($e->getMessage(), 0, 250)]);
                    Notification::make()->title('The email could not be sent')->body($e->getMessage())->danger()->send();

                    return;
                }
                Notification::make()->title('Email sent to '.$data['to'])->success()->send();
            });
    }

    protected static function consolidatorId(Invoiceissue $record): ?int
    {
        $inv = $record->invoice_id ? \App\Models\Invoice::with('container')->find($record->invoice_id) : null;

        return $inv ? ($inv->consolidator?->id ?? $inv->container?->consolidator_id) : null;
    }
}
