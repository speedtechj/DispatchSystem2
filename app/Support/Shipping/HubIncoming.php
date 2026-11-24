<?php

namespace App\Support\Shipping;

use App\Models\Shipping\SeaShipment;
use App\Models\TripCrew;
use App\Models\Tripinvoice;

/**
 * Board 63: a partner hub's view of a sea shipment coming to it. One card per shipment:
 * where the boxes are (steps of its kind) and what the hub must do next.
 */
class HubIncoming
{
    /** @return array{kind: string, tag: string, title: string, sub: string, facts: array, steps: array, at: int, todo: string, actions: array, received: bool} */
    public static function card(SeaShipment $s, int $hubId): array
    {
        $stop = Shipments::stopFor($s, $hubId) ?? Shipments::stops($s)->first();
        $stops = Shipments::stops($s);
        $mine = $stop ? (int) Tripinvoice::where('deliverylog_id', $stop->deliverylog_id)->count() : 0;
        $others = $stops->filter(fn ($x) => (int) $x->logistichub_id !== $hubId);
        $received = (bool) $stop?->received_at || $s->status === 'received';
        $carrier = $stop && SeaTrucks::ready() ? SeaTrucks::carrierOf($s, $stop) : (int) $s->deliverylog_id;
        $truckTrip = \App\Models\Deliverylog::with('truck:id,plate_no')->find($carrier);
        $driver = TripCrew::with('user:id,first_name,last_name')->where('deliverylog_id', $carrier)->first()?->user;
        $eta = $s->eta?->format('D M j');
        $date = fn (?string $st) => Shipments::when($s, $st);

        $base = ['code' => $s->code, 'boxes' => $mine, 'received' => $received, 'id' => $s->id,
            'title' => $s->code.' · '.$mine.' '.str('box')->plural($mine).' for you',
            'sub' => $others->isNotEmpty() ? 'With '.$others->pluck('hub.hub_name')->filter()->join(', ').' too · you are stop '.$stop?->stop : ''];

        return $base + match ($s->mode) {
            'roro' => [
                'kind' => 'roro', 'tag' => 'RoRo',
                'sub' => 'Our truck rides the ship and drives to your hub'.($stop ? ' · you are stop '.$stop->stop : ''),
                'facts' => ['Truck · driver' => trim(($truckTrip?->truck?->plate_no ?? '—').($driver ? ' · '.$driver->first_name.' '.mb_substr((string) $driver->last_name, 0, 1).'.' : '')),
                    'Ship' => trim(($s->shipping_line ?: '').($s->vessel ? ' · '.$s->vessel : '')) ?: '—', 'Arrives' => $eta ?? '—',
                    'Now' => $stop?->arrived_at ? 'At your hub since '.$stop->arrived_at->format('g:i A') : Shipments::label($s)],
                'steps' => ['Loaded', 'On the ship', 'Off the ship', 'At your hub', 'Received'],
                'at' => $received ? 5 : ($stop?->arrived_at ? 3 : match ($s->status) { 'arrived' => 2, 'sailed' => 1, default => 0 }),
                'todo' => $received ? 'Received.' : ($stop?->arrived_at ? 'The truck is at your door: scan your '.$mine.' boxes in (Scan app → Receive container). The rest stay on the truck.'
                    : 'Have people ready when the truck comes. Receive only your '.$mine.' boxes from it.'),
                'actions' => $received ? [] : [['label' => 'Receive from truck', 'url' => static::scanUrl(), 'primary' => (bool) $stop?->arrived_at]],
            ],
            'lcl' => [
                'kind' => 'lcl', 'tag' => 'LCL',
                'sub' => 'Sent with a forwarder: you pick them up',
                'facts' => ['Forwarder' => $s->forwarder ?: '—', 'Waybill' => $s->waybill_no ?: '—', 'Pick up at' => $s->pick_up_at ?: '—',
                    'Ready since' => $date('arrived') ?? ($eta ? 'ETA '.$eta : '—')],
                'steps' => ['Handed to forwarder', 'Shipped', 'Ready to pick up', 'Picked up', 'Received'],
                'at' => $received ? 5 : match ($s->status) { 'picked_up' => 3, 'arrived' => 2, 'sailed' => 1, default => 0 },
                'todo' => $received ? 'Received.' : match ($s->status) {
                    'arrived' => 'Bring the waybill no. '.($s->waybill_no ?: '').' and an ID to '.($s->pick_up_at ?: 'the forwarder').'. Count '.$mine.' boxes there.',
                    'picked_up' => 'Scan the '.$mine.' boxes in at your hub (Scan app → Receive container).',
                    'sailed' => 'On the way. Press Ready when the forwarder says you can pick them up.',
                    default => 'Not shipped yet.',
                },
                'actions' => $received ? [] : match ($s->status) {
                    'sailed' => [['label' => 'Ready to pick up', 'press' => 'arrived', 'primary' => false]],
                    'arrived' => [['label' => 'I picked them up', 'press' => 'picked_up', 'primary' => true]],
                    'picked_up' => [['label' => 'Scan them in', 'url' => static::scanUrl(), 'primary' => true]],
                    default => [],
                },
            ],
            default => [
                'kind' => 'container', 'tag' => 'Container',
                'facts' => ['Van · seal' => trim(($s->van_no ?: '—').($s->seal_no ? ' · '.$s->seal_no : '')), 'Vessel · BL' => trim(($s->vessel ?: '—').($s->bl_no ? ' · '.$s->bl_no : '')),
                    'ETA '.($s->port_to ?: 'port') => $eta ?? '—', 'From warehouse' => trim(($date('sealed') ?? '—').($truckTrip?->truck?->plate_no ? ' · truck '.$truckTrip->truck->plate_no : ''))],
                'steps' => ['Loaded', 'At port', 'Shipped', 'Arrived', 'Received'],
                'at' => $received ? 5 : match ($s->status) { 'arrived', 'picked_up' => 3, 'sailed' => 2, 'at_port' => 1, default => 0 },
                'todo' => $received ? 'Received.' : match ($s->status) {
                    'arrived' => 'The van is at '.($s->port_to ?: 'the port').'. Pull it to your hub, check seal '.($s->seal_no ?: '').' before opening, then scan your boxes in.',
                    'picked_up' => 'Scan your '.$mine.' boxes in (Scan app → Receive container).',
                    default => 'Book a truck to pull the van from '.($s->port_to ?: 'the port').' when it arrives'.($eta ? ' ('.$eta.')' : '').'.',
                },
                'actions' => $received ? [] : match ($s->status) {
                    'arrived' => [['label' => 'Picked up the van', 'press' => 'picked_up', 'primary' => true]],
                    'picked_up' => [['label' => 'Receive container', 'url' => static::scanUrl(), 'primary' => true]],
                    default => [],
                },
            ],
        };
    }

    protected static function scanUrl(): string
    {
        try {
            return \App\Filament\Scan\Pages\ScanApp::getUrl(panel: 'scan');
        } catch (\Throwable) {
            return '/scan';
        }
    }
}
