<?php

namespace App\Http\Controllers;

use App\Models\BoxPhoto;
use App\Models\Invoice;
use App\Models\PhotoSetting;
use App\Support\Photos\BoxPhotos;
use App\Support\ScanModes;
use Illuminate\Http\JsonResponse;
use Illuminate\Http\Request;

/**
 * Scan app: a box photo sent in the back (board 51), so the crew scans the next box while it uploads.
 * Only for a box this person just scanned in the Scan app (kept in the session for 2 hours).
 */
class ScanPhotoController extends Controller
{
    public function store(Request $request): JsonResponse
    {
        $data = $request->validate([
            'photo' => 'required|image|max:12288',
            'invoice_id' => 'required|integer',
            'condition' => 'nullable|string|in:'.implode(',', array_keys(BoxPhoto::CONDITIONS)),
            'note' => 'nullable|string|max:250',
        ], ['photo.image' => 'That file is not a photo.']);

        $ok = session('scan-app.photo-ok', [])[(int) $data['invoice_id']] ?? null;
        $user = $request->user();
        $mode = $ok ? (ScanModes::for($user)[$ok['mode']] ?? null) : null;
        if (! $ok || ! $mode || ($ok['at'] ?? 0) < now()->subHours(2)->timestamp) {
            return response()->json(['message' => 'Scan the box again, then take the photo.'], 403);
        }
        $station = app($mode['class']);
        $station->data = [$mode['field'] => $ok['choice']];
        $step = $station->photoStep();
        if (! $step || ! PhotoSetting::current()->allows($step)) {
            return response()->json(['message' => 'Photos are off for this scan.'], 403);
        }
        $invoice = Invoice::findOrFail((int) $data['invoice_id']);
        $photo = BoxPhotos::store($request->file('photo'), $step, $invoice, $station->photoContext(), $user, $data['condition'] ?? null, $data['note'] ?? null);

        return response()->json(['id' => $photo->id]);
    }
}
