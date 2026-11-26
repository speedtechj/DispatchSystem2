<?php

namespace App\Jobs;

use App\Support\Photos\Storage\PhotoStore;
use App\Support\Photos\Storage\PhotoWork;
use Illuminate\Bus\Queueable;
use Illuminate\Contracts\Queue\ShouldBeUnique;
use Illuminate\Contracts\Queue\ShouldQueue;
use Illuminate\Foundation\Bus\Dispatchable;
use Illuminate\Queue\InteractsWithQueue;
use Illuminate\Support\Facades\Cache;

/** Settings → Photo storage: moves and copies, about 50 seconds at a time, until done. */
class RunPhotoTasks implements ShouldQueue, ShouldBeUnique
{
    use Dispatchable, InteractsWithQueue, Queueable;

    public int $timeout = 300;

    public int $uniqueFor = 120;

    public function handle(): void
    {
        Cache::put('photos.queue.seen', time(), 3600);
        PhotoWork::work(50);
        if (PhotoWork::active()) {
            static::dispatch()->delay(now()->addSeconds(2));
        }
        PhotoStore::forgetMemo();
    }
}
