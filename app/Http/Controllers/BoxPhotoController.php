<?php

namespace App\Http\Controllers;

use App\Models\BoxPhoto;
use Illuminate\Support\Facades\Auth;
use Illuminate\Support\Facades\Storage;
use Symfony\Component\HttpFoundation\Response;

/** Photos are private files: only signed-in users who may see the box get them. */
class BoxPhotoController extends Controller
{
    public function show(int $photo): Response
    {
        $p = $this->find($photo);

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

    protected function find(int $id): BoxPhoto
    {
        abort_unless(Auth::check(), 403);
        $p = BoxPhoto::visibleTo(Auth::user())->find($id);
        abort_unless($p && $p->exists(), 404);

        return $p;
    }
}
