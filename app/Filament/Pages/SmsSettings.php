<?php

namespace App\Filament\Pages;

use App\Models\AppSetting;
use App\Models\Sms\SmsMessage;
use App\Support\Ai\Ai;
use App\Support\Ai\AiUnavailable;
use App\Support\Sms\Phone;
use App\Support\Sms\SmsEvents;
use App\Support\Sms\SmsSender;
use App\Support\Sms\SmsSettings as Sms;
use App\Support\Sms\SmsWriter;
use App\Support\Sms\Templates;
use BackedEnum;
use Filament\Notifications\Notification;
use Filament\Pages\Page;
use Filament\Support\Icons\Heroicon;
use Illuminate\Support\Facades\Auth;
use Throwable;
use UnitEnum;

/** Admin → Settings → SMS: provider and key, which texts go out, the texts themselves (with the AI writer). */
class SmsSettings extends Page
{
    protected string $view = 'filament.sms.settings';

    protected static string|UnitEnum|null $navigationGroup = 'Settings';

    protected static string|BackedEnum|null $navigationIcon = Heroicon::OutlinedChatBubbleLeftRight;

    protected static ?string $navigationLabel = 'SMS';

    protected static ?string $title = 'Settings · SMS to receivers';

    protected static ?string $slug = 'sms-settings';

    protected static ?int $navigationSort = 92;

    public string $provider = 'semaphore';

    public string $key = '';

    public string $sender = '';

    public string $limit = '3000';

    public string $officePhone = '';

    public string $language = 'auto';

    public string $testNumber = '';

    public ?string $testResult = null;

    public bool $testOk = false;

    /** kind => on/off */
    public array $enabled = [];

    public string $kind = 'out_for_delivery';

    public string $lang = 'en';

    public string $text = '';

    public ?string $aiNote = null;

    public ?string $aiError = null;

    public ?string $before = null;

    public static function canAccess(): bool
    {
        return (bool) Auth::user()?->hasRole('super_admin');
    }

    public function mount(): void
    {
        $this->provider = Sms::provider();
        $this->sender = Sms::sender();
        $this->limit = (string) Sms::limit();
        $this->officePhone = Sms::officePhone();
        $this->language = Sms::language();
        foreach (array_keys(Sms::KINDS) as $k) {
            $this->enabled[$k] = Sms::on($k);
        }
        $this->loadText();
    }

    protected function loadText(): void
    {
        $this->text = Templates::get($this->kind, $this->lang);
        $this->reset('aiNote', 'aiError', 'before');
    }

    public function pick(string $provider): void
    {
        if (isset(Sms::PROVIDERS[$provider])) {
            $this->provider = $provider;
            AppSetting::put('sms.provider', $provider);
            $this->reset('key', 'testResult');
        }
    }

    public function saveSetup(): void
    {
        $this->validate([
            'key' => ['nullable', 'string', 'max:300', 'regex:/^\S+$/'],
            'sender' => ['nullable', 'string', 'max:40'],
            'limit' => ['required', 'integer', 'min:0', 'max:1000000'],
            'officePhone' => ['nullable', 'string', 'max:40'],
            'language' => ['required', 'in:auto,en,tl,ceb'],
        ], ['key.regex' => 'The key has a space in it. Paste it again.']);
        if (trim($this->key) !== '') {
            Sms::putKey($this->provider, $this->key);
            $this->key = '';
        }
        AppSetting::put('sms.sender', trim($this->sender));
        AppSetting::put('sms.limit', (int) $this->limit);
        AppSetting::put('sms.office_phone', trim($this->officePhone));
        AppSetting::put('sms.language', $this->language);
        Notification::make()->title('SMS settings saved')->success()->send();
    }

    public function removeKey(): void
    {
        Sms::putKey($this->provider, null);
        Notification::make()->title('Key removed: no texts are sent')->send();
    }

    public function test(): void
    {
        $this->testOk = false;
        if (! Phone::clean($this->testNumber)) {
            $this->testResult = 'Type a mobile number like 0917 123 4567.';

            return;
        }
        $row = SmsSender::send('test', $this->testNumber, Auth::user()->full_name, 'Test from the dispatch system: SMS is working.', ['user_id' => Auth::id()]);
        $this->testOk = $row->status === 'sent';
        $this->testResult = match ($row->status) {
            'sent' => '✓ Sent to '.Phone::pretty($row->number).' · 1 text · check your phone',
            'no_key' => Sms::PROVIDERS[$this->provider][2] ? 'Save the API key first.' : Sms::PROVIDERS[$this->provider][0].' is not connected yet.',
            'opted_out' => 'This number replied STOP or was stopped in the SMS log.',
            default => 'Did not send: '.str((string) $row->error)->limit(200),
        };
    }

    public function toggle(string $kind): void
    {
        if (isset(Sms::KINDS[$kind])) {
            $this->enabled[$kind] = ! ($this->enabled[$kind] ?? false);
            AppSetting::put('sms.on.'.$kind, $this->enabled[$kind] ? 1 : 0);
        }
    }

    public function edit(string $kind, ?string $lang = null): void
    {
        if (isset(Sms::KINDS[$kind])) {
            $this->kind = $kind;
            $this->lang = isset(Templates::LANGS[$lang ?? $this->lang]) ? ($lang ?? $this->lang) : 'en';
            $this->loadText();
        }
    }

    public function saveText(): void
    {
        $this->validate(['text' => ['required', 'string', 'max:600']]);
        $unknown = array_diff(Templates::blanksIn($this->text), Templates::BLANKS);
        if ($unknown) {
            $this->addError('text', 'Unknown blank: '.implode(', ', $unknown).'. Use only the blanks listed.');

            return;
        }
        Templates::put($this->kind, $this->lang, $this->text);
        $this->reset('aiNote', 'before');
        Notification::make()->title('Message saved')->success()->send();
    }

    public function resetText(): void
    {
        Templates::put($this->kind, $this->lang, null);
        $this->loadText();
    }

    /** AI SMS writer: short, friendly, or translate (tl / ceb / en). */
    public function ai(string $action): void
    {
        $this->reset('aiError');
        if (! isset(SmsWriter::ACTIONS[$action])) {
            return;
        }
        try {
            $res = SmsWriter::rewrite($this->text, $action);
            $this->before = $this->text;
            if (in_array($action, ['tl', 'ceb', 'en'], true)) {
                // a translation goes to that language's text
                $this->lang = $action;
            }
            $this->text = $res['text'];
            $this->aiNote = $res['note'].' Press Save message to keep it.';
        } catch (Throwable $e) {
            $this->aiError = $e instanceof AiUnavailable ? $e->getMessage() : 'The AI could not do it: '.str($e->getMessage())->limit(160);
        }
    }

    public function undoAi(): void
    {
        if ($this->before !== null) {
            $this->text = $this->before;
            $this->reset('aiNote', 'before');
        }
    }

    protected function getViewData(): array
    {
        $sample = ['name' => 'Liza', 'boxes' => '52211, 52212', 'box_count' => 2, 'truck' => 'ABC 1234', 'driver' => 'Dan', 'time' => '10:42 AM',
            'minutes' => 20, 'reason' => 'nobody was home', 'next_day' => SmsEvents::nextDay(), 'hub' => 'Cebu Partner Hub', 'hub_phone' => $this->officePhone ?: '0917 555 0101'];
        $preview = Templates::render($this->text, $sample);
        $parts = Templates::parts($preview);
        $month = SmsMessage::where('created_at', '>=', now()->startOfMonth())->get(['kind', 'status', 'parts']);

        return [
            'providers' => Sms::PROVIDERS,
            'masked' => Sms::masked($this->provider),
            'ready' => Sms::ready(),
            'used' => Sms::usedThisMonth(),
            'kinds' => Sms::KINDS,
            'counts' => $month->where('status', 'sent')->countBy('kind'),
            'langs' => Templates::LANGS,
            'blanks' => Templates::BLANKS,
            'preview' => $preview,
            'parts' => $parts,
            'chars' => mb_strlen($preview),
            'unknown' => array_diff(Templates::blanksIn($this->text), Templates::BLANKS),
            'emoji' => (bool) preg_match('/[\x{1F300}-\x{1FAFF}\x{2600}-\x{27BF}]/u', $this->text),
            'aiOn' => Ai::enabled('sms_writer'),
            'aiSwitched' => Ai::switchedOn('sms_writer'),
            'badNumbers' => SmsMessage::where('status', 'bad_number')->where('created_at', '>=', now()->subDays(7))->count(),
            'others' => collect(Templates::LANGS)->keys()->reject(fn ($l) => $l === $this->lang)->mapWithKeys(fn ($l) => [$l => Templates::get($this->kind, $l)]),
        ];
    }
}
