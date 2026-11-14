<?php

namespace App\Filament\Pages;

use App\Models\Ai\AiSetting;
use App\Models\Ai\AiUsage;
use App\Support\Ai\Ai;
use App\Support\Ai\AiFeatures;
use App\Support\Ai\AiUnavailable;
use BackedEnum;
use Filament\Notifications\Notification;
use Filament\Pages\Page;
use Filament\Support\Icons\Heroicon;
use Illuminate\Support\Facades\Auth;
use UnitEnum;

/** Admin → Settings → AI: the API key, models, monthly limit and which AI helpers are on. */
class AiSettings extends Page
{
    protected string $view = 'filament.pages.ai-settings';

    protected static string|UnitEnum|null $navigationGroup = 'Settings';

    protected static string|BackedEnum|null $navigationIcon = Heroicon::OutlinedSparkles;

    protected static ?string $navigationLabel = 'AI';

    protected static ?string $title = 'AI';

    protected static ?string $slug = 'ai-settings';

    public string $apiKey = '';

    public string $modelFast = '';

    public string $modelSmart = '';

    public string $limit = '20';

    /** @var array<string, bool> */
    public array $enabled = [];

    public ?string $testResult = null;

    public bool $testOk = false;

    public static function canAccess(): bool
    {
        return (bool) Auth::user()?->hasRole('super_admin');
    }

    public function getSubheading(): ?string
    {
        return 'Paste your Anthropic API key, then switch on the helpers you want. Nothing is sent to the AI while a helper is off.';
    }

    public function mount(): void
    {
        $s = AiSetting::current();
        $this->modelFast = (string) $s->model_fast;
        $this->modelSmart = (string) $s->model_smart;
        $this->limit = (string) (float) $s->monthly_limit;
        foreach (array_keys(AiFeatures::ALL) as $k) {
            $this->enabled[$k] = $s->isOn($k);
        }
    }

    protected function row(): AiSetting
    {
        return AiSetting::query()->first() ?? new AiSetting;
    }

    public function save(): void
    {
        $this->validate([
            'apiKey' => ['nullable', 'string', 'max:300', 'regex:/^\S+$/'],
            'modelFast' => ['required', 'string', 'max:80'],
            'modelSmart' => ['required', 'string', 'max:80'],
            'limit' => ['required', 'numeric', 'min:0', 'max:100000'],
        ], ['apiKey.regex' => 'The key has a space in it. Paste it again.']);

        $row = $this->row();
        if (trim($this->apiKey) !== '') {
            $row->api_key = trim($this->apiKey);
        }
        $row->fill([
            'model_fast' => trim($this->modelFast),
            'model_smart' => trim($this->modelSmart),
            'monthly_limit' => (float) $this->limit,
            'features' => array_keys(array_filter($this->enabled)),
        ])->save();

        $this->apiKey = '';
        Notification::make()->title('AI settings saved')->success()->send();
    }

    public function removeKey(): void
    {
        $row = $this->row();
        $row->api_key = null;
        $row->save();
        $this->testResult = null;
        Notification::make()->title('AI key removed. All AI helpers that need it are paused.')->warning()->send();
    }

    public function test(): void
    {
        if (trim($this->apiKey) !== '') {
            $this->save();
        }
        try {
            foreach (['fast', 'smart'] as $kind) {
                $data = Ai::call('test', 'Reply with the word OK.', [['role' => 'user', 'content' => 'Test']], $kind, 5, check: false);
            }
            $this->testOk = true;
            $this->testResult = 'Connected. Both models answered.';
        } catch (AiUnavailable $e) {
            $this->testOk = false;
            $this->testResult = $e->getMessage();
        }
    }

    protected function getViewData(): array
    {
        $s = AiSetting::current();
        $key = $s->hasKey() ? (string) $s->api_key : '';
        $month = AiUsage::where('created_at', '>=', now()->startOfMonth());

        return [
            'features' => AiFeatures::ALL,
            'hasKey' => $s->hasKey(),
            'keyEnd' => $key ? substr($key, -4) : '',
            'spent' => AiUsage::spentThisMonth(),
            'limitNow' => (float) $s->monthly_limit,
            'byFeature' => (clone $month)->selectRaw('feature, count(*) as n, sum(cost) as c')->groupBy('feature')->get()->keyBy('feature'),
            'failures' => (clone $month)->where('ok', false)->latest('id')->limit(3)->get(),
            'chatUrl' => route('ai-chat.show'),
        ];
    }
}
