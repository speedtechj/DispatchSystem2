<?php

namespace App\Http\Controllers;

use App\Models\Boxes\WhSection;
use App\Models\Warehouse;
use App\Support\Boxes\Sections;
use Illuminate\Http\Request;
use Illuminate\Http\Response;
use Milon\Barcode\DNS2D;

/** Printable QR labels for the warehouse sections: one big label per page. */
class SectionLabelsController extends Controller
{
    public function __invoke(Request $request): Response
    {
        abort_unless(Sections::ready(), 404);
        $user = $request->user();
        $warehouse = Warehouse::findOrFail((int) $request->query('warehouse'));
        abort_unless($user?->hasRole('super_admin') || (int) $user?->warehouse_id === $warehouse->id, 403);

        $sections = WhSection::with(['hub:id,hub_name', 'toWarehouse:id,name'])->where('warehouse_id', $warehouse->id)
            ->where('is_active', true)->orderBy('sort')->orderBy('code')->get()
            ->map(function (WhSection $s) {
                $svg = (new DNS2D)->getBarcodeSVG($s->qrText(), 'QRCODE,M', 10, 10, '#0b1620');

                return ['code' => $s->code, 'name' => $s->name ?: $s->goesTo(), 'color' => $s->color, 'provinces' => implode(', ', (array) $s->provinces),
                    'qr' => preg_replace('/<desc>.*?<\/desc>/s', '', preg_replace('/^.*?(<svg)/s', '$1', $svg))];
            });

        // spots inside sections, when used (board 50): one label per spot, "C2 · Nueva Ecija"
        if (Sections::spotsOn($warehouse->id)) {
            $qr = fn (string $t) => preg_replace('/<desc>.*?<\/desc>/s', '', preg_replace('/^.*?(<svg)/s', '$1', (new DNS2D)->getBarcodeSVG($t, 'QRCODE,M', 10, 10, '#0b1620')));
            $spots = WhSection::with('spots')->where('warehouse_id', $warehouse->id)->where('is_active', true)->where('use_spots', true)->orderBy('sort')->orderBy('code')->get()
                ->flatMap(fn (WhSection $s) => $s->spots->map(fn ($p) => ['code' => $p->code, 'name' => 'Spot '.$p->code.' · section '.$s->code.' · '.($s->name ?: $s->goesTo()), 'color' => $s->color,
                    'provinces' => '', 'qr' => $qr($p->qrText())]));
            $sections = $sections->concat($spots);
        }

        return response()->view('boxes.section-labels', ['warehouse' => $warehouse, 'sections' => $sections]);
    }
}
