<?php

namespace App\Filament\Shared\Ai;

use App\Models\Invoice;
use App\Support\Ai\AiUnavailable;
use App\Support\Ai\AskAgent;
use BackedEnum;
use Filament\Support\Icons\Heroicon;
use Illuminate\Support\Facades\Auth;

/** Ask the system: plain-word questions answered from your own data. Read only. */
abstract class AskPage extends AiPage
{
    protected string $view = 'filament.ai.ask';

    protected static string $feature = 'ask';

    protected static string|BackedEnum|null $navigationIcon = Heroicon::OutlinedChatBubbleLeftRight;

    protected static ?string $navigationLabel = 'Ask the system';

    protected static ?string $title = 'Ask the system';

    protected static ?string $slug = 'ai-ask';

    protected static ?int $navigationSort = 2;

    public string $question = '';

    /** @var list<array{role: string, text: string}> */
    public array $chat = [];

    public ?string $error = null;

    public function getSubheading(): ?string
    {
        return 'Ask about boxes, containers, trips and drivers in plain words. It can only read; it never changes anything.';
    }

    public function mount(): void
    {
        $this->chat = session('ai.ask.chat', []);
    }

    public function ask(?string $q = null): void
    {
        $q = trim($q ?? $this->question);
        if ($q === '') {
            return;
        }
        $this->error = null;
        try {
            $answer = (new AskAgent(Auth::user()))->answer($q, $this->chat);
            $this->chat[] = ['role' => 'user', 'text' => $q];
            $this->chat[] = ['role' => 'assistant', 'text' => $answer];
            $this->chat = array_slice($this->chat, -20);
            $this->question = '';
            session(['ai.ask.chat' => $this->chat]);
        } catch (AiUnavailable $e) {
            $this->error = $e->getMessage();
        }
    }

    public function clear(): void
    {
        $this->chat = [];
        session()->forget('ai.ask.chat');
    }

    protected function getViewData(): array
    {
        return [
            'paused' => $this->pausedReason(),
            'examples' => [
                'Where is box '.(Invoice::latest('id')->value('invoice') ?? '52135').'?',
                'Which drivers had the most failed deliveries this week?',
                'How many boxes were delivered this month?',
                'What is still not delivered on active trips?',
            ],
        ];
    }
}
