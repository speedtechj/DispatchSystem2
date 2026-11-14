<?php

namespace App\Http\Controllers;

use App\Models\Ai\AiChat;
use App\Support\Ai\Ai;
use App\Support\Ai\AiUnavailable;
use App\Support\Ai\CustomerChat;
use App\Support\Branding;
use Illuminate\Http\RedirectResponse;
use Illuminate\Http\Request;
use Illuminate\View\View;

/** Public page where receivers ask about their box. Only works while "Customer chat" is on. */
class AiChatController extends Controller
{
    protected function guard(): void
    {
        abort_unless(Ai::switchedOn('customer_chat'), 404);
    }

    public function show(): View
    {
        $this->guard();

        return view('ai.chat', ['company' => Branding::companyName(), 'chat' => null, 'left' => 0]);
    }

    public function start(Request $request): RedirectResponse
    {
        $this->guard();
        $data = $request->validate(['box' => 'required|string|max:40', 'last4' => 'required|string|max:8']);
        $chat = CustomerChat::start($data['box'], $data['last4'], $request->ip());
        if (! $chat) {
            return back()->withInput()->withErrors(['box' => 'We could not find that box with those phone digits. Check the box number on your receipt.']);
        }

        return redirect()->route('ai-chat.chat', $chat->token);
    }

    public function chat(string $token): View
    {
        $this->guard();
        $chat = AiChat::where('token', $token)->where('created_at', '>=', now()->subDays(3))->firstOrFail();

        return view('ai.chat', ['company' => Branding::companyName(), 'chat' => $chat, 'left' => CustomerChat::questionsLeft($chat)]);
    }

    public function ask(Request $request, string $token): RedirectResponse
    {
        $this->guard();
        $chat = AiChat::where('token', $token)->where('created_at', '>=', now()->subDays(3))->firstOrFail();
        $data = $request->validate(['q' => 'required|string|max:500']);
        if (CustomerChat::questionsLeft($chat) === 0) {
            return back()->withErrors(['q' => 'This chat is full. Please call us, or start again tomorrow.']);
        }
        try {
            CustomerChat::reply($chat, $data['q']);
        } catch (AiUnavailable) {
            return back()->withInput()->withErrors(['q' => 'Sorry, we can\'t answer right now. Please try again later or call us.']);
        }

        return redirect()->route('ai-chat.chat', $chat->token);
    }
}
