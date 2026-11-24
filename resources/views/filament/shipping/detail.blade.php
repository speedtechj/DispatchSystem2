@php
    $peso = fn ($n) => '₱'.number_format((float) $n, 2);
@endphp
<x-filament-panels::page>
<div class="ds-sp">
    <section class="ds-board__panel ds-sp__steps">
        @foreach ($steps as $k => $label)
            @php
                $i = array_search($k, $stepKeys);
                $now = array_search($s->status, $stepKeys);
            @endphp
            <span @class(['ds-sp__step', 'is-done' => $i < $now, 'is-now' => $i === $now])><i></i><b>{{ $label }}</b><small>{{ $whenOf($k) ?? '' }}</small></span>
        @endforeach
    </section>

    <div class="ds-sp__head">
        <span class="ds-sp__track"><span aria-hidden="true">{{ $s->mode === 'roro' ? '⛴️' : ($s->mode === 'lcl' ? '📦' : '🚢') }}</span><span><b>{{ $track }}</b><small>What the receiver sees on tracking</small></span></span>
        <span class="ds-sp__acts">
            @if ($canPress)
                <x-filament::button wire:click="advance" :color="$blockers ? 'gray' : 'primary'">Mark: {{ $nextLabel }}</x-filament::button>
            @endif
            @if ($canReceive)
                <x-filament::button color="success" wire:click="finishReceiving" wire:confirm="Finish receiving{{ $stops->count() > 1 ? ' at '.$receiveStop?->hub?->hub_name : '' }}? Boxes not scanned in get an Invoice Issue each.">Finish receiving{{ $stops->count() > 1 ? ' · '.$receiveStop?->hub?->hub_name : '' }}{{ $nextAfter ? ' · pass on to '.$nextAfter : '' }}</x-filament::button>
            @endif
        </span>
    </div>
    @if ($stops->count() > 1 || ($s->status === 'preparing' && ! $hubSide))
        <section class="ds-board__panel ds-sp__box">
            <h3>{{ $stops->count() > 1 ? 'One container, '.$stops->count().' hubs' : 'Hubs in this container' }}</h3>
            @foreach ($stops as $st)
                <span class="ds-sp__stop" wire:key="st-{{ $st->deliverylog_id }}">
                    <b class="ds-sp__stopn">{{ $st->stop }}</b>
                    <span><span><b>{{ $st->hub?->hub_name }}</b> · trip {{ $st->trip?->trip_number }}</span>
                        <small>{{ $st->received_at ? 'Received '.$st->received_at->format('M j g:i A').($st->missing ? ' · '.$st->missing.' missing' : '') : ($st->arrived_at ? 'Our truck arrived '.$st->arrived_at->format('M j g:i A') : ($stops->count() > 1 ? ($st->stop === 1 ? 'Unloads first · load near the door' : ($st->stop === $stops->count() ? 'Unloads last · load deep inside' : 'Load in the middle')) : 'Waiting')) }}</small>
                        @if ($stops->count() > 1 && $carrierPlate($st))
                            <em @class(['ds-sp__goes', 'is-own' => ! $rides($st)])>{{ $rides($st) ? 'Goes with '.$carrierPlate($st) : 'Truck '.$carrierPlate($st) }}</em>
                        @endif
                    </span>
                    @if ($canTruck && $st->exists && $st->deliverylog_id != $s->deliverylog_id)
                        @if ($rides($st))
                            <button type="button" class="ds-fu__link" wire:click="ownTruck({{ $st->deliverylog_id }})">Use its own truck</button>
                        @else
                            <button type="button" class="ds-fu__link" wire:click="goWithMain({{ $st->deliverylog_id }})">Go with the main truck</button>
                        @endif
                    @endif
                    @if ($s->status === 'preparing' && ! $hubSide && $st->stop > 1)
                        <button type="button" class="ds-fu__link" wire:click="removeStop({{ $st->deliverylog_id }})" wire:confirm="Take trip {{ $st->trip?->trip_number }} out of this container? The trip and its boxes stay as they are.">Take out</button>
                    @endif
                </span>
            @endforeach
            @if ($s->status === 'preparing' && ! $hubSide)
                <x-filament::button color="gray" size="sm" wire:click="openAdd({{ $adding ? 'false' : 'true' }})" icon="heroicon-o-plus">Add another hub's trip</x-filament::button>
                @if ($adding)
                    @forelse ($addTrips as $at)
                        <button type="button" class="ds-sp__pick" wire:click="addStop({{ $at->id }})" wire:key="at-{{ $at->id }}"><i aria-hidden="true"></i><span><b>Trip {{ $at->trip_number }} → {{ $at->destination?->hub_name }}</b><small>{{ $at->truck?->plate_no ?? 'no truck yet' }} · same port</small></span><em>{{ $at->tripinvoices_count }} boxes</em></button>
                    @empty
                        <p class="ds-sp__none">No other open trip to a hub at the same port.</p>
                    @endforelse
                @endif
            @endif
        </section>
    @endif
    @if ($trucks->isNotEmpty())
        <section class="ds-board__panel ds-sp__box">
            <h3>{{ $trucks->count() > 1 ? $trucks->count().' trucks to '.($s->mode === 'lcl' ? 'the forwarder' : ($s->mode === 'roro' ? 'the ship' : 'the port')) : 'Truck to '.($s->mode === 'lcl' ? 'the forwarder' : ($s->mode === 'roro' ? 'the ship' : 'the port')) }}</h3>
            <div class="ds-sp__trucks">
                @foreach ($trucks as $tk)
                    <div class="ds-sp__truck" wire:key="tk-{{ $tk['tripId'] }}">
                        <span class="ds-sp__truckhead"><b>{{ $tk['plate'] ?? 'No truck yet' }}</b><small>Trip {{ $tk['trip']?->trip_number }}{{ $tk['main'] ? ' · main truck' : ' · second truck' }}{{ $tk['crew'] ? ' · '.implode(', ', $tk['crew']) : '' }}</small></span>
                        <span class="ds-sp__truckline"><span>Carries {{ $tk['stops']->map(fn ($x) => $x->hub?->hub_name)->filter()->join(', ') }}</span><b class="num">{{ $tk['loaded'] }} / {{ $tk['total'] }} loaded</b></span>
                        <span class="ds-sp__bar"><i style="width: {{ $tk['total'] ? round($tk['loaded'] * 100 / $tk['total']) : 0 }}%"></i></span>
                        @if (! $hubSide)
                            <label class="ds-sp__truckcost"><span>Trucking ₱</span><input type="text" inputmode="decimal" wire:model="truckCost.{{ $tk['tripId'] }}" placeholder="0"><button type="button" class="ds-fu__link" wire:click="saveTruckCost({{ $tk['tripId'] }})">Save</button></label>
                        @endif
                    </div>
                @endforeach
            </div>
            <p class="ds-board__muted">{{ $stops->count() > 1 ? 'Trips that go with a truck have no truck of their own: load them all on that truck\'s trip (Scan app → Load truck). ' : '' }}The trucking is shared by the hubs by their number of boxes (Cost per box).</p>
        </section>
    @endif
    @if ($s->status === 'preparing' && ! $hubSide)
        <section class="ds-board__panel ds-sp__box">
            <h3>Picked the wrong trip, or made it by mistake?</h3>
            <p class="ds-board__muted">Nothing is sealed yet, so you can still change it.</p>
            <div class="ds-sp__acts">
                <x-filament::button color="gray" wire:click="openChange({{ $changing ? 'false' : 'true' }})" icon="heroicon-o-arrows-right-left">Change trip</x-filament::button>
                <x-filament::button color="danger" outlined wire:click="removeShipment" wire:confirm="Remove {{ $s->code }}? Only the shipment is removed. Trip {{ $s->trip?->trip_number }} and its boxes stay as they are.">Remove shipment</x-filament::button>
            </div>
            @if ($changing)
                <label class="ds-sp__search"><span aria-hidden="true">🔍</span><input type="text" wire:model.live.debounce.300ms="changeSearch" placeholder="Search trip no., hub or truck" aria-label="Search trips"></label>
                @forelse ($changeTrips as $ct)
                    <button type="button" class="ds-sp__pick" wire:click="changeTrip({{ $ct->id }})" wire:key="ct-{{ $ct->id }}"><i aria-hidden="true"></i><span><b>Trip {{ $ct->trip_number }} → {{ $ct->destination?->hub_name }}</b><small>{{ $ct->truck?->plate_no ?? 'no truck yet' }}</small></span><em>{{ $ct->tripinvoices_count }} boxes</em></button>
                @empty
                    <p class="ds-sp__none">No other open trip to a hub reached by sea.</p>
                @endforelse
            @endif
        </section>
    @endif
    @if ($blockers && $canPress)
        <div class="ds-sp__block">@foreach ($blockers as $b)<span>⚠ {{ $b }}</span>@endforeach</div>
    @endif

    <div class="ds-sp__grid">
        <section class="ds-board__panel ds-sp__box">
            <h3>Boxes</h3>
            <div class="ds-sp__nums4">
                <span><small>On trip {{ $s->trip?->trip_number }}</small><b class="num">{{ $counts['onTrip'] }}</b></span>
                <span><small>Left the warehouse</small><b class="num">{{ $counts['loaded'] }}</b></span>
                <span @class(['is-bad' => $counts['port'] !== null && $counts['port'] < $counts['loaded']])><small>At the port</small><b class="num">{{ $counts['port'] ?? '—' }}</b></span>
                <span @class(['is-bad' => $counts['missingHub']->isNotEmpty()])><small>Received at the hub</small><b class="num">{{ $counts['received'] }}</b></span>
            </div>
            @if ($counts['port'] !== null && $counts['port'] < $counts['loaded'])
                <p class="ds-sp__warn">⚠ {{ $counts['loaded'] - $counts['port'] }} {{ $counts['loaded'] - $counts['port'] === 1 ? 'box' : 'boxes' }} left the warehouse but {{ $counts['loaded'] - $counts['port'] === 1 ? 'was' : 'were' }} not handed over at the port{{ $counts['missingPort']->isNotEmpty() ? ': '.$counts['missingPort']->take(8)->join(', ') : '. Which ones is not known: only a full scan tells.' }}</p>
            @endif
            @if ($counts['missingHub']->isNotEmpty())
                <p class="ds-sp__warn">Not scanned in at the hub yet: {{ $counts['missingHub']->take(10)->join(', ') }}{{ $counts['missingHub']->count() > 10 ? '…' : '' }}</p>
            @endif
            @if ($openSets)
                <div class="ds-sp__sets">
                    <b>Customers with boxes left behind</b>
                    @foreach ($openSets as $o)
                        <span>{{ $o['name'] }} · {{ $o['have'] }} of {{ $o['of'] }} · @foreach ($o['missing'] as $m){{ $m['invoice'] }} ({{ $m['reason'] ? \App\Models\Boxes\SetSplit::REASONS[$m['reason']] ?? $m['reason'] : 'no reason yet' }}) @endforeach</span>
                    @endforeach
                </div>
            @endif
            @if ($wrong->isNotEmpty())
                <div class="ds-sp__sets">
                    <b>Not for {{ $s->hub?->hub_name }}</b>
                    @foreach ($wrong as $w)<span>{{ $w->invoice?->invoice }} → {{ $w->correctHub?->hub_name ?? '?' }} · {{ \App\Models\Shipping\WrongHubBox::STATUS[$w->status] ?? $w->status }}</span>@endforeach
                </div>
            @endif
            @if (! $hubSide)
                <p class="ds-board__muted">Load the boxes with Scan app → Load truck (trip {{ $s->trip?->trip_number }}). Sets and wrong hub are checked there.</p>
            @else
                <p class="ds-board__muted">Scan the boxes in with Scan app → Receive container, then press Finish receiving.</p>
            @endif
        </section>

        <section class="ds-board__panel ds-sp__box">
            <h3>Cost</h3>
            <dl class="ds-sp__dl">
                <dt>Freight</dt><dd>{{ $s->cost_freight !== null ? $peso($s->cost_freight) : '—' }}</dd>
                <dt>Trucking to {{ $s->mode === 'lcl' ? 'the forwarder' : 'port' }}{{ $trucks->count() > 1 ? ' ('.$trucks->count().' trucks)' : '' }}</dt><dd>{{ ($tc = $trucks->sum(fn ($t) => (float) $t['cost'])) > 0 ? $peso($tc) : ($s->cost_trucking !== null ? $peso($s->cost_trucking) : '—') }}</dd>
                @if ($s->mode === 'lcl' && $s->charge_rate)<dt>Forwarder rate</dt><dd>{{ $peso($s->charge_rate) }} {{ strtolower($charges[$s->charge_basis] ?? '') }}</dd>@endif
                <dt>Port fees (wharfage, arrastre)</dt><dd>{{ $s->cost_port !== null ? $peso($s->cost_port) : '—' }}</dd>
                <dt>Other</dt><dd>{{ $s->cost_other !== null ? $peso($s->cost_other) : '—' }}</dd>
            </dl>
            <p class="ds-sp__perbox"><span>Per box</span><b class="num">{{ $counts['perBox'] ? $peso($counts['perBox']) : '—' }}</b></p>
            @if ($s->seal_photo || $s->port_receipt)
                <span class="ds-sp__pics">
                    @if ($s->seal_photo)<a href="{{ $s->fileUrl($s->seal_photo) }}" target="_blank" rel="noopener"><img src="{{ $s->fileUrl($s->seal_photo) }}" alt="Seal"><small>Seal</small></a>@endif
                    @if ($s->port_receipt)<a href="{{ $s->fileUrl($s->port_receipt) }}" target="_blank" rel="noopener"><img src="{{ $s->fileUrl($s->port_receipt) }}" alt="Port receipt"><small>Port receipt</small></a>@endif
                </span>
            @endif
        </section>
    </div>

    @if (! $hubSide)
        <form wire:submit="save" class="ds-board__panel ds-sp__form">
            <h3>Details</h3>
            <div class="ds-sp__fields">
                <label><span>How it's shipped</span><select wire:model.live="f.mode">@foreach ($modes as $k => $l)<option value="{{ $k }}">{{ $l }}</option>@endforeach</select></label>
                @if ($f['mode'] === 'lcl')
                    <label><span>Forwarder</span><input type="text" wire:model="f.forwarder" placeholder="2GO Logistics"></label>
                    <label><span>Waybill / booking no.</span><input type="text" wire:model="f.waybill_no"></label>
                    <label><span>Charged by</span><select wire:model="f.charge_basis"><option value="">—</option>@foreach ($charges as $k => $l)<option value="{{ $k }}">{{ $l }}</option>@endforeach</select></label>
                    <label><span>Rate ₱</span><input type="text" inputmode="decimal" wire:model="f.charge_rate"></label>
                    <label class="is-wide"><span>Hand over at (our truck goes here)</span><input type="text" wire:model="f.hand_over_at" placeholder="2GO warehouse, Pier 4, North Harbor"></label>
                    <label class="is-wide"><span>Pick up at (the partner hub goes here)</span><input type="text" wire:model="f.pick_up_at" placeholder="2GO Cebu, Pier 3"></label>
                @else
                <label><span>{{ $f['mode'] === 'roro' ? 'Truck door seal no.' : 'Seal no.' }}</span><input type="text" wire:model="f.seal_no"></label>
                @endif
                @if ($f['mode'] === 'container')
                    <label><span>Container van no.</span><input type="text" wire:model="f.van_no" placeholder="MSKU 220871"></label>
                    <label><span>Size</span><input type="text" wire:model="f.van_size" placeholder="20 ft"></label>
                @endif
                @if ($f['mode'] !== 'lcl')
                <label><span>{{ $f['mode'] === 'roro' ? 'Ferry company' : 'Shipping line' }}</span><input type="text" wire:model="f.shipping_line" placeholder="2GO"></label>
                <label><span>Vessel</span><input type="text" wire:model="f.vessel"></label>
                <label><span>Voyage</span><input type="text" wire:model="f.voyage"></label>
                <label><span>{{ $f['mode'] === 'roro' ? 'Ticket no.' : 'BL no.' }}</span><input type="text" wire:model="f.bl_no"></label>
                @endif
                <label><span>From port</span><input type="text" wire:model="f.port_from" placeholder="Manila North Harbor"></label>
                <label><span>To port</span><input type="text" wire:model="f.port_to" placeholder="Cebu Port"></label>
                <label><span>Leaves (ETD)</span><input type="date" wire:model="f.etd"></label>
                <label><span>Arrives (ETA)</span><input type="date" wire:model="f.eta"></label>
                @if ($f['mode'] !== 'lcl')
                <label class="is-file"><span>Seal photo</span><input type="file" wire:model="sealPhoto" accept="image/*"></label>
                @endif
            </div>
            <h3>Port check</h3>
            <div class="ds-sp__fields">
                <label><span>Port check</span><select wire:model.live="f.port_check">@foreach ($checks as $k => $l)<option value="{{ $k }}">{{ $l }}</option>@endforeach</select></label>
                @if ($f['port_check'] === 'count')
                    <label><span>Boxes handed over (count)</span><input type="number" min="0" wire:model="f.port_count"></label>
                    <label class="is-file"><span>Photo of the forwarder receipt</span><input type="file" wire:model="receipt" accept="image/*"></label>
                @elseif ($f['port_check'] === 'off')
                    <label class="is-wide"><span>Why is it off? (required)</span><input type="text" wire:model="f.port_reason" placeholder="Container sealed at our warehouse"></label>
                @else
                    <p class="ds-board__muted is-wide">The crew scans every box at the port: Scan app → Port check.</p>
                @endif
            </div>
            <h3>Cost</h3>
            <div class="ds-sp__fields">
                <label><span>Freight ₱</span><input type="text" inputmode="decimal" wire:model="f.cost_freight"></label>
                <label><span>Trucking to port ₱</span><input type="text" inputmode="decimal" wire:model="f.cost_trucking"></label>
                <label><span>Port fees ₱</span><input type="text" inputmode="decimal" wire:model="f.cost_port"></label>
                <label><span>Other ₱</span><input type="text" inputmode="decimal" wire:model="f.cost_other"></label>
                <label class="is-wide"><span>Note</span><input type="text" wire:model="f.note" maxlength="500"></label>
            </div>
            @if ($errors->any())<p class="ds-sp__err">{{ $errors->first() }}</p>@endif
            <div><x-filament::button type="submit" wire:loading.attr="disabled" wire:target="save,sealPhoto,receipt">Save details</x-filament::button></div>
        </form>
    @endif
</div>
</x-filament-panels::page>
