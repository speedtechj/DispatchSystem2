<?php

return [

    /*
    |--------------------------------------------------------------------------
    | Third Party Services
    |--------------------------------------------------------------------------
    |
    | This file is for storing the credentials for third party services such
    | as Mailgun, Postmark, AWS and more. This file provides the de facto
    | location for this type of information, allowing packages to have
    | a conventional file to locate the various service credentials.
    |
    */

    'postmark' => [
        'token' => env('POSTMARK_TOKEN'),
    ],

    'ses' => [
        'key' => env('AWS_ACCESS_KEY_ID'),
        'secret' => env('AWS_SECRET_ACCESS_KEY'),
        'region' => env('AWS_DEFAULT_REGION', 'us-east-1'),
    ],

    'resend' => [
        'key' => env('RESEND_KEY'),
    ],

    'slack' => [
        'notifications' => [
            'bot_user_oauth_token' => env('SLACK_BOT_USER_OAUTH_TOKEN'),
            'channel' => env('SLACK_BOT_USER_DEFAULT_CHANNEL'),
        ],
    ],
    'locations' => [
    '01' => ['url' => env('LOCATION_1_URL'), 'token' => env('LOCATION_1_TOKEN')],
    '02' => ['url' => env('LOCATION_2_URL'), 'token' => env('LOCATION_2_TOKEN')],
    '03' => ['url' => env('LOCATION_3_URL'), 'token' => env('LOCATION_3_TOKEN')],
    '04' => ['url' => env('LOCATION_4_URL'), 'token' => env('LOCATION_4_TOKEN')],
],

];
