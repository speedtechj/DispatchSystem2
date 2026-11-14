<?php

namespace App\Jobs;

use App\Models\Ai\AiPhotoCheck;
use App\Support\Ai\PhotoCheck;
use Illuminate\Contracts\Queue\ShouldQueue;
use Illuminate\Foundation\Queue\Queueable;

class CheckPhotoWithAi implements ShouldQueue
{
    use Queueable;

    public function __construct(public int $checkId) {}

    public function handle(): void
    {
        if ($check = AiPhotoCheck::find($this->checkId)) {
            PhotoCheck::run($check);
        }
    }
}
