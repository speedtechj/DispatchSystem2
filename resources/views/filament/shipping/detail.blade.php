@php
    $peso = fn ($n) => '₱'.number_format((float) $n, 2);
@endphp
<x-filament-panels::page>
<div class="ds-sp">
    @php
        $unit = $s->mode === 'lcl' ? 'LCL lot' : ($s->mode === 'roro' ? 'RoRo truck' : 'container');
        $to = $s->mode === 'lcl' ? 'the forwarder' : ($s->mode === 'roro' ? 'the ship' : 'the port');
        $allBoxes = (int) $stopBoxes->sum();
        $canMode = ! $hubSide && in_array($s->status, ['preparing', 'sealed'], true);
    @endphp
    {{-- board 62: what it is, and how it goes --}}
    <div class="ds-sv__head">
        <span><small>Sea shipment · {{ $s->port_from ?: 'Manila' }} → {{ $s->port_to ?: $s->hub?->hub_name }}</small>
            <b>{{ $stops->count() }} {{ \Illuminate\Support\Str::plural('trip', $stops->count()) }} · {{ $allBoxes }} boxes · {{ $trucks->count() ?: 1 }} {{ \Illuminate\Support\Str::plural('truck', $trucks->count() ?: 1) }} · {{ \App\Support\Shipping\Shipments::label($s) }}</b></span>
        <span class="ds-sv__modes" role="group" aria-label="How it is shipped">
            @foreach (['container' => 'Container', 'roro' => 'RoRo', 'lcl' => 'LCL'] as $mk => $ml)
                <button type="button" @class(['is-on' => $s->mode === $mk]) @if ($canMode) wire:click="setMode('{{ $mk }}')" @else disabled @endif>{{ $ml }}</button>
            @endforeach
        </span>
    </div>

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

    @if ($canMode && $s->mode === 'container' && $allBoxes > 0 && $allBoxes < \App\Support\Shipping\Shipments::LCL_HINT)
        <div class="ds-sv__hint"><span>Few boxes ({{ $allBoxes }}): LCL with a forwarder may cost less than a whole container.</span><button type="button" class="ds-fu__link" wire:click="setMode('lcl')">Send as LCL</button></div>
    @endif

    {{-- the key details of this kind --}}
    @if ($s->mode === 'lcl' && ! $hubSide)
        <section class="ds-board__panel ds-sp__box ds-sv__lcl">
            <h3>LCL · with a forwarder (no van, no seal)</h3>
            <span class="ds-sv__lbl">Forwarder</span>
            <span class="ds-sv__chips">
                @foreach ($forwarders as $fw)
                    <button type="button" @class(['is-on' => (string) $fw->id === (string) ($f['forwarder_id'] ?? '')]) wire:click="pickForwarder({{ $fw->id }})" wire:key="fw-{{ $fw->id }}">{{ $fw->name }}</button>
                @endforeach
                <a class="ds-sv__chipadd" href="{{ \App\Filament\Pages\Forwarders::getUrl() }}" target="_blank">＋ New forwarder</a>
            </span>
            @php($fwSel = $forwarders->firstWhere('id', (int) ($f['forwarder_id'] ?? 0)))
            <div class="ds-sp__fields">
                <label><span>Hand over at (our truck goes here)</span><select wire:model="f.hand_over_branch_id" @disabled(! $fwSel)><option value="">{{ $fwSel ? 'Choose a branch' : 'Pick the forwarder first' }}</option>@foreach ($fwSel?->branches ?? [] as $b)<option value="{{ $b->id }}">{{ $b->name }}</option>@endforeach</select></label>
                <label><span>Pick up at (the hub goes here)</span><select wire:model="f.pick_up_branch_id" @disabled(! $fwSel)><option value="">{{ $fwSel ? 'Choose a branch' : 'Pick the forwarder first' }}</option>@foreach ($fwSel?->branches ?? [] as $b)<option value="{{ $b->id }}">{{ $b->name }}</option>@endforeach</select></label>
                <label><span>Waybill / booking no.</span><input type="text" wire:model="f.waybill_no"></label>
                <label><span>Charged by</span><select wire:model="f.charge_basis"><option value="">—</option>@foreach ($charges as $k => $l)<option value="{{ $k }}">{{ $l }}</option>@endforeach</select></label>
                <label><span>Rate ₱</span><input type="text" inputmode="decimal" wire:model="f.charge_rate"></label>
            </div>
            <span class="ds-sv__row">
                @if ($fwSel)<button type="button" class="ds-fu__link" wire:click="mountAction('newBranch')">＋ New branch for {{ $fwSel->name }}</button>@endif
                <x-filament::button size="sm" wire:click="save">Save</x-filament::button>
            </span>
            @if ($s->pick_up_at)
                <p class="ds-sv__sees">The partner hub sees: pick up at {{ $s->pick_up_at }}.</p>
            @endif
        </section>
    @else
        @php($facts = match ($s->mode) {
            'lcl' => ['Forwarder' => $s->forwarder, 'Waybill / booking no.' => $s->waybill_no, 'Charged by' => $s->charge_rate ? '₱'.number_format($s->charge_rate, 2).' '.strtolower($charges[$s->charge_basis] ?? '') : null, 'Pick up at' => $s->pick_up_at],
            'roro' => ['Shipping line' => $s->shipping_line, 'Vessel · voyage' => trim($s->vessel.($s->voyage ? ' · '.$s->voyage : '')), 'Booking / ticket no.' => $s->bl_no, 'ETD → ETA' => trim(($s->etd?->format('M j') ?? '').' → '.($s->eta?->format('M j') ?? ''), ' →')],
            default => ['Van no. · size' => trim($s->van_no.($s->van_size ? ' · '.$s->van_size : '')), 'Seal no.' => $s->seal_no, 'Vessel · BL' => trim($s->vessel.($s->bl_no ? ' · '.$s->bl_no : '')), 'ETD → ETA' => trim(($s->etd?->format('M j') ?? '').' → '.($s->eta?->format('M j') ?? ''), ' →')],
        })
        <section class="ds-board__panel ds-sp__box">
            <h3>{{ ['container' => 'Container', 'roro' => 'RoRo · the truck rides the ship', 'lcl' => 'LCL · with a forwarder'][$s->mode] ?? 'Container' }} @if (! $hubSide)<a class="ds-fu__link" href="#details">Edit</a>@endif</h3>
            <div class="ds-sv__facts">@foreach ($facts as $l => $v)<span><small>{{ $l }}</small><b>{{ $v ?: '—' }}</b></span>@endforeach</div>
        </section>
    @endif

    <div class="ds-sv__grid">
        {{-- trips (one per partner hub) --}}
        <section class="ds-board__panel ds-sp__box">
            <h3>Trips in this {{ $unit }} <small>one per partner hub</small></h3>
            @foreach ($stops as $st)
                <div class="ds-sv__trip" wire:key="st-{{ $st->deliverylog_id }}">
                    <b>{{ $st->hub?->hub_name }}</b><b class="num">{{ (int) ($stopBoxes[$st->deliverylog_id] ?? 0) }} boxes</b>
                    <small>Trip {{ $st->trip?->trip_number }} · stop {{ $st->stop }}{{ $st->received_at ? ' · received '.$st->received_at->format('M j g:i A').($st->missing ? ' · '.$st->missing.' missing' : '') : ($st->arrived_at ? ' · truck arrived '.$st->arrived_at->format('M j g:i A') : '') }}</small>
                    <small @class(['ds-sv__goes', 'is-own' => ! $rides($st)])>{{ $carrierPlate($st) ? ($rides($st) ? 'Goes with '.$carrierPlate($st) : 'Truck '.$carrierPlate($st)) : 'No truck yet' }}</small>
                    @if (! $hubSide && ($canTruck || $s->status === 'preparing') && $st->deliverylog_id != $s->deliverylog_id)
                        <span class="ds-sv__tripacts">
                            @if ($canTruck && ! $rides($st))<button type="button" class="ds-fu__link" wire:click="goWithMain({{ $st->deliverylog_id }})">Go with the main truck</button>@endif
                            @if ($s->status === 'preparing')<button type="button" class="ds-fu__link" wire:click="removeStop({{ $st->deliverylog_id }})" wire:confirm="Take trip {{ $st->trip?->trip_number }} out of this {{ $unit }}? The trip and its boxes stay as they are.">Take out</button>@endif
                        </span>
                    @endif
                </div>
            @endforeach
            <small class="ds-board__muted">The hub trips do not pick a truck: they go with the truck of this {{ $unit }}.</small>
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

        {{-- trucks to the port / ship / forwarder --}}
        <section class="ds-board__panel ds-sp__box">
            <h3>{{ $trucks->count() > 1 ? $trucks->count().' trucks to '.$to : 'Truck to '.$to }}
                @if ($canTruck && $stops->count() > 1 && $trucks->count() < $stops->count())
                    <button type="button" class="ds-sv__add2" wire:click="$toggle('second')">{{ $second ? 'Close' : '+ Add a second truck' }}</button>
                @endif
            </h3>
            @if ($second)
                <div class="ds-sv__second">
                    <small>Which trip goes on the second truck?</small>
                    @foreach ($stops->filter(fn ($st) => $rides($st)) as $st)
                        <span class="ds-sv__secrow" wire:key="sec-{{ $st->deliverylog_id }}">
                            <b>{{ $st->hub?->hub_name }} · {{ (int) ($stopBoxes[$st->deliverylog_id] ?? 0) }} boxes</b>
                            <select wire:model="secondTruck.{{ $st->deliverylog_id }}"><option value="">{{ $st->own_truck_id ? 'Its own truck ('.\App\Models\Truck::whereKey($st->own_truck_id)->value('plate_no').')' : 'Choose a truck' }}</option>@foreach ($hubTrucks as $tid => $plate)<option value="{{ $tid }}">{{ $plate }}</option>@endforeach</select>
                            <x-filament::button size="xs" wire:click="useSecondTruck({{ $st->deliverylog_id }})">Use</x-filament::button>
                        </span>
                    @endforeach
                </div>
            @endif
            @foreach ($trucks as $tk)
                <div class="ds-sp__truck" wire:key="tk-{{ $tk['tripId'] }}">
                    <span class="ds-sp__truckhead"><b>{{ $tk['plate'] ?? 'No truck yet' }}</b><small>{{ $tk['crew'] ? implode(' · ', $tk['crew']) : 'No crew yet' }}</small>
                        <i @class(['ds-sv__tstate', 'is-ok' => $tk['total'] && $tk['loaded'] >= $tk['total']])>{{ $tk['total'] && $tk['loaded'] >= $tk['total'] ? 'Loaded' : 'Loading' }}</i></span>
                    <span class="ds-sp__truckline"><span>Loaded {{ $tk['loaded'] }} / {{ $tk['total'] }}</span><span>{{ $tk['stops']->count() > 1 ? 'All '.$tk['stops']->count().' trips' : $tk['stops']->first()?->hub?->hub_name }} · {{ $tk['total'] }} boxes</span></span>
                    <span class="ds-sv__tbar"><i style="width: {{ $tk['total'] ? round($tk['loaded'] * 100 / $tk['total']) : 0 }}%"></i></span>
                    @if (! $hubSide)
                        <label class="ds-sp__truckcost"><span>Trucking ₱</span><input type="text" inputmode="decimal" wire:model="truckCost.{{ $tk['tripId'] }}" placeholder="0"><button type="button" class="ds-fu__link" wire:click="saveTruckCost({{ $tk['tripId'] }})">Save</button></label>
                    @else
                        <span class="ds-sp__truckline"><span>Trucking</span><b>{{ $tk['cost'] ? '₱'.number_format($tk['cost'], 2) : '—' }}</b></span>
                    @endif
                </div>
            @endforeach
        </section>
    </div>

    @if ($trucks->sum(fn ($t) => (float) $t['cost']) > 0)
        <section class="ds-board__panel ds-sp__box">
            <h3>Trucking split by boxes <small>goes into each hub's Cost per box</small></h3>
            <div class="ds-sv__split">
                @foreach ($trucks as $tk)
                    @foreach ($tk['stops'] as $st)
                        @php($n = (int) ($stopBoxes[$st->deliverylog_id] ?? 0))
                        <span><span>{{ $st->hub?->hub_name }} · {{ $tk['stops']->count() > 1 ? $n.'/'.$tk['total'].' boxes' : 'its own truck' }}</span><b>₱{{ number_format($tk['total'] ? (float) $tk['cost'] * $n / $tk['total'] : (float) $tk['cost'], 0) }}</b></span>
                    @endforeach
                @endforeach
            </div>
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
            @if (($s->pickup_count ?? null) !== null)
                <p class="ds-board__muted">Picked up at the forwarder: {{ $s->pickup_count }} boxes{{ $s->pickup_at ? ' · '.$s->pickup_at->format('M j g:i A') : '' }}</p>
            @endif
            @if ($s->seal_photo || $s->port_receipt || ($s->pickup_photo ?? null))
                <span class="ds-sp__pics">
                    @if ($s->seal_photo)<a href="{{ $s->fileUrl($s->seal_photo) }}" target="_blank" rel="noopener"><img src="{{ $s->fileUrl($s->seal_photo) }}" alt="Seal"><small>Seal</small></a>@endif
                    @if ($s->port_receipt)<a href="{{ $s->fileUrl($s->port_receipt) }}" target="_blank" rel="noopener"><img src="{{ $s->fileUrl($s->port_receipt) }}" alt="Port receipt"><small>{{ $s->mode === 'lcl' ? 'Forwarder receipt' : 'Port receipt' }}</small></a>@endif
                    @if ($s->pickup_photo ?? null)<a href="{{ $s->fileUrl($s->pickup_photo) }}" target="_blank" rel="noopener"><img src="{{ $s->fileUrl($s->pickup_photo) }}" alt="Release at pick-up"><small>Release at pick-up</small></a>@endif
                </span>
            @endif
        </section>
    </div>

    @if (! $hubSide)
        <form wire:submit="save" class="ds-board__panel ds-sp__form" id="details">
            <h3>Details</h3>
            <div class="ds-sp__fields">
                @if ($f['mode'] !== 'lcl')
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
                @if ($f['mode'] !== 'lcl')
                <label><span>From port</span><input type="text" list="ds-ports" wire:model="f.port_from" placeholder="Manila North Harbor"></label>
                <label><span>To port</span><input type="text" list="ds-ports" wire:model="f.port_to" placeholder="Cebu Port"></label>
                <datalist id="ds-ports">@foreach ($ports as $pn)<option value="{{ $pn }}"></option>@endforeach</datalist>
                @endif
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
