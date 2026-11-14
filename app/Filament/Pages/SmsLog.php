<?php

namespace App\Filament\Pages;

use App\Models\Invoice;
use App\Models\Sms\SmsMessage;
use App\Models\Sms\SmsOptout;
use App\Support\Sms\Phone;
use App\Support\Sms\SmsSender;
use App\Support\Sms\SmsSettings as Sms;
use BackedEnum;
use Filament\Actions\Action;
use Filament\Notifications\Notification;
use Filament\Pages\Page;
use Filament\Support\Icons\Heroicon;
use Filament\Tables\Columns\TextColumn;
use Filament\Tables\Concerns\InteractsWithTable;
use Filament\Tables\Contracts\HasTable;
use Filament\Tables\Filters\SelectFilter;
use Filament\Tables\Table;
use Illuminate\Support\Facades\Auth;
use UnitEnum;

/** SMS log: every text, who got it, and what happened (sent, bad number, STOP, failed). */
class SmsLog extends Page implements HasTable
{
    use InteractsWithTable;

    protected string $view = 'filament.sms.log';

    protected static string|UnitEnum|null $navigationGroup = 'Settings';

    protected static string|BackedEnum|null $navigationIcon = Heroicon::OutlinedInboxStack;

    protected static ?string $navigationLabel = 'SMS log';

    protected static ?string $title = 'SMS log';

    protected static ?string $slug = 'sms-log';

    protected static ?int $navigationSort = 93;

    public static function canAccess(): bool
    {
        return (bool) Auth::user()?->hasRole('super_admin');
    }

    public function table(Table $table): Table
    {
        return $table
            ->query(SmsMessage::query())
            ->defaultSort('id', 'desc')
            ->columns([
                TextColumn::make('created_at')->label('Time')->dateTime('M j, g:i A')->sortable(),
                TextColumn::make('name')->label('Receiver')->searchable()->placeholder('—'),
                TextColumn::make('number')->label('Number')->searchable()->formatStateUsing(fn ($state, $record) => $state ? Phone::pretty($state) : ($record->raw_number ?: '—')),
                TextColumn::make('kind')->label('Message')->formatStateUsing(fn ($state) => Sms::KINDS[$state][0] ?? ($state === 'test' ? 'Test' : $state)),
                TextColumn::make('message')->label('Text')->limit(60)->tooltip(fn ($record) => $record->message)->searchable()->toggleable(),
                TextColumn::make('status')->badge()
                    ->formatStateUsing(fn ($state) => SmsMessage::STATUS[$state][0] ?? $state)
                    ->color(fn ($state) => SmsMessage::STATUS[$state][1] ?? 'gray')
                    ->tooltip(fn ($record) => $record->error),
                TextColumn::make('parts')->label('Texts')->alignEnd(),
            ])
            ->filters([
                SelectFilter::make('status')->options(collect(SmsMessage::STATUS)->map(fn ($s) => $s[0])->all()),
                SelectFilter::make('kind')->label('Message')->options(collect(Sms::KINDS)->map(fn ($k) => $k[0])->put('test', 'Test')->all()),
                SelectFilter::make('when')->label('When')->default('month')
                    ->options(['today' => 'Today', 'week' => 'Last 7 days', 'month' => 'This month', 'all' => 'All'])
                    ->query(fn ($query, array $data) => match ($data['value'] ?? 'month') {
                        'today' => $query->whereDate('created_at', today()),
                        'week' => $query->where('created_at', '>=', now()->subDays(7)),
                        'all' => $query,
                        default => $query->where('created_at', '>=', now()->startOfMonth()),
                    }),
            ])
            ->recordActions([
                Action::make('again')->label('Send again')->icon('heroicon-o-arrow-path')
                    ->visible(fn (SmsMessage $r) => in_array($r->status, ['failed', 'bad_number', 'over_limit', 'no_key'], true))
                    ->action(function (SmsMessage $r) {
                        // a fixed number on the box is used
                        $raw = $r->number ?: (Invoice::whereIn('id', $r->invoice_ids ?? [])->value('receiver_mobile_no') ?? $r->raw_number);
                        $new = SmsSender::send($r->kind, $raw, $r->name, $r->message, ['deliverylog_id' => $r->deliverylog_id, 'receiver_key' => $r->receiver_key, 'invoice_ids' => $r->invoice_ids, 'lang' => $r->lang, 'user_id' => Auth::id()]);
                        Notification::make()->title($new->status === 'sent' ? 'Sent' : 'Not sent: '.(SmsMessage::STATUS[$new->status][0] ?? $new->status))->color($new->status === 'sent' ? 'success' : 'warning')->send();
                    }),
                Action::make('stop')->label('Stop texting')->icon('heroicon-o-no-symbol')->color('gray')
                    ->visible(fn (SmsMessage $r) => $r->number && ! SmsOptout::where('number', $r->number)->exists())
                    ->requiresConfirmation()->modalDescription('This number will not get texts again (for example when the receiver asked to stop).')
                    ->action(fn (SmsMessage $r) => SmsOptout::firstOrCreate(['number' => $r->number], ['why' => 'Stopped by '.Auth::user()->full_name])),
                Action::make('allow')->label('Allow texts again')->icon('heroicon-o-check')->color('gray')
                    ->visible(fn (SmsMessage $r) => $r->number && SmsOptout::where('number', $r->number)->exists())
                    ->action(fn (SmsMessage $r) => SmsOptout::where('number', $r->number)->delete()),
            ]);
    }

    protected function getViewData(): array
    {
        return [
            'today' => SmsMessage::where('status', 'sent')->whereDate('created_at', today())->sum('parts'),
            'month' => Sms::usedThisMonth(),
            'limit' => Sms::limit(),
            'failed' => SmsMessage::whereIn('status', ['failed', 'bad_number'])->where('created_at', '>=', now()->startOfMonth())->count(),
            'stopped' => SmsOptout::count(),
            'credits' => SmsSender::credits(),
        ];
    }
}
