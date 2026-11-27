<?php

namespace App\Http\Controllers;

use App\Models\BoxPhoto;
use App\Support\Photos\Storage\PhotoStore;
use Illuminate\Support\Facades\Auth;
use Illuminate\Support\Facades\Storage;
use Symfony\Component\HttpFoundation\Response;

/** Photos are private files: only signed-in users who may see the box get them. */
class BoxPhotoController extends Controller
{
    /**
     * Part 46: a photo in the bucket (R2) is not copied through this server any more (that was slow):
     * the browser is sent to a short-lived private link and loads it straight from the bucket.
     * A photo still on this server is sent as a file.
     */
    public function show(int $photo): Response
    {
        $p = $this->find($photo, check: false);
        $place = PhotoStore::placeOf('box', $p->path);
        if ($place !== 'server') {
            return redirect()->away(PhotoStore::link($place, PhotoStore::key('box', $p->path)))
                ->header('Cache-Control', 'private, max-age=3000');
        }
        abort_unless(Storage::disk('box')->exists($p->path), 404);

        return response(Storage::disk('box')->get($p->path), 200, [
            'Content-Type' => 'image/jpeg',
            'Cache-Control' => 'private, max-age=86400',
        ]);
    }

    public function download(int $photo): Response
    {
        $p = $this->find($photo);

        return Storage::disk('box')->download($p->path, $p->fileName());
    }

    protected function find(int $id, bool $check = true): BoxPhoto
    {
        abort_unless(Auth::check(), 403);
        $p = BoxPhoto::visibleTo(Auth::user())->find($id);
        abort_unless($p && (! $check || $p->exists()), 404);

        return $p;
    }
}
