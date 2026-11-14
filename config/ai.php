<?php

/*
 * AI helpers. The API key, models, spending limit and on/off switches are set in
 * Admin → Settings → AI (saved in the database). This file only holds defaults.
 */
return [
    'url' => env('AI_URL', 'https://api.anthropic.com/v1/messages'),
    'version' => '2023-06-01',
    'timeout' => (int) env('AI_TIMEOUT', 120),

    // US dollars per million tokens [input, output]. Check https://platform.claude.com/docs/en/about-claude/pricing
    // and correct them here if Anthropic changes prices. Used only to show and limit your monthly spending.
    'prices' => [
        'claude-haiku-5-5' => [0.10, 0.50],
        'claude-sonnet-5-5' => [2.00, 10.00],
        'claude-opus-5-5' => [4.00, 20.00],
        'default' => [2.00, 10.00],
    ],
];
