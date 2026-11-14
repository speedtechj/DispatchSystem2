<?php

namespace App\Support\Aging;

use App\Mail\AgingSummaryMail;
use App\Models\Ai\AiSetting;
use App\Models\User;
use App\Support\Ai\Ai;
use App\Support\Ai\AiScope;
use Filament\Actions\Action;
use Filament\Notifications\Notification;
use Illuminate\Support\Facades\Mail;
use Throwable;

/** The morning summary (bell, and email if switched on) and the monthly "new limits suggested" note. */
class AgingNotifier
{
    public static function settings(): array
    {
        return (AiSetting::current()->aging ?? []) + ['hour' => 7, 'mail_admin' => true, 'mail_warehouse' => false, 'mail_hub' => false, 'last_summary' => null, 'last_suggest' => null];
    }

    public static function saveSettings(array $values): void
    {
        $row = AiSetting::query()->first() ?? new AiSetting(['features' => []]);
        $row->aging = array_merge(static::settings(), $values);
        $row->save();
    }

    /** Called every hour; sends once a day at the chosen hour. */
    public static function tick(bool $force = false): int
    {
        if (! Ai::enabled('aging')) {
            return 0;
        }
        $s = static::settings();
        $sent = 0;
        if ($force || ((int) now()->format('G') === (int) $s['hour'] && $s['last_summary'] !== now()->toDateString())) {
            static::saveSettings(['last_summary' => now()->toDateString()]);
            $sent = static::sendSummaries();
        }
        if (now()->day === 1 && $s['last_suggest'] !== now()->format('Y-m')) {
            static::saveSettings(['last_suggest' => now()->format('Y-m')]);
            static::suggestNote();
        }

        return $sent;
    }

    public static function sendSummaries(): int
    {
        $s = static::settings();
        $sent = 0;
        $users = User::where('is_active', true)->with('panelcategory')->get()
            ->filter(fn (User $u) => in_array($u->panelcategory?->code, ['adm', 'whse', 'co'], true));

        foreach ($users as $u) {
            $hub = AiScope::hubId($u);
            if ($hub === false) {
                continue;
            }
            $code = $u->panelcategory?->code;
            $group = $hub ? 'hub' : ($code === 'whse' ? 'warehouse' : 'admin');
            $rows = BoxAging::rows($hub ?: null, $group === 'warehouse' ? ($u->warehouse_id ?: null) : null);
            $sum = BoxAging::summary($rows);
            if ($sum['open'] === 0) {
                continue;
            }
            $advice = AgingAdvice::for($rows, ($hub ?: 'x').'.'.($group === 'warehouse' ? $u->warehouse_id : 'x'));
            $panel = ['admin' => '', 'warehouse' => '/warehouse', 'hub' => '/company'][$group];
            $url = url($panel.'/box-aging');

            Notification::make()
                ->title("Morning summary: {$sum['late']} late ".str('box')->plural($sum['late']))
                ->body("{$sum['tomorrow']} more will be late tomorrow.".($advice['items'] ? ' '.$advice['items'][0]['t'] : ''))
                ->icon('heroicon-o-clock')->color($sum['late'] ? 'danger' : 'success')
                ->actions([Action::make('open')->label('Open Box aging')->url($url)])
                ->sendToDatabase($u);

            if (($s['mail_'.$group] ?? false) && $u->email) {
                try {
                    Mail::to($u->email)->send(new AgingSummaryMail($sum, $advice['items'], $url, $u->first_name));
                } catch (Throwable $e) {
                    report($e);
                }
            }
            $sent++;
        }

        return $sent;
    }

    /** Once a month: tell Admin when the AI would suggest different limits. */
    public static function suggestNote(): void
    {
        $now = BoxAging::limits();
        $changes = collect(LimitSuggester::suggest(false))->filter(fn ($r) => $r['n'] >= LimitSuggester::MIN_SAMPLES)
            ->filter(fn ($r) => ($now[$r['stage']][$r['region']] ?? $now[$r['stage']]['all'] ?? null) !== [$r['warn'], $r['late']]);
        if ($changes->isEmpty()) {
            return;
        }
        $admins = User::where('is_active', true)->get()->filter(fn ($u) => $u->hasRole('super_admin'));
        Notification::make()->title('New aging limits suggested')
            ->body($changes->count().' '.str('limit')->plural($changes->count()).' changed with last months\' deliveries. Check them before using.')
            ->icon('heroicon-o-sparkles')->color('info')
            ->actions([Action::make('open')->label('Review limits')->url(url('/aging-limits'))])
            ->sendToDatabase($admins);
    }
}
