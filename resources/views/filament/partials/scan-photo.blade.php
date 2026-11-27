{{-- Optional box photos on a scan station. Photos are made smaller in the browser before upload. --}}
@if ($this->photosEnabled() && ($this->canPhotoBox() || $this->batchDue()))
    @php($photoBox = $this->canPhotoBox())
    <div class="ds-ph" wire:key="ph-{{ $lastInvoiceId }}-{{ $lastStatus }}"
         x-data="{
            busy: false, failed: false, pct: 0, batch: false,
            take(batch) { this.batch = batch; this.failed = false; this.$refs.file.value = ''; this.$refs.file.click() },
            async send(event) {
                const file = event.target.files[0];
                if (! file) return;
                this.busy = true; this.pct = 0;
                let out = file;
                out = window.dsShrinkPhoto ? await window.dsShrinkPhoto(file) : file;
                $wire.upload('boxPhoto', out,
                    () => $wire.saveBoxPhoto(this.batch).then(() => { this.busy = false }),
                    () => { this.busy = false; this.failed = true },
                    (e) => { this.pct = e.detail.progress });
            },
         }">
        <input type="file" accept="image/*" capture="environment" x-ref="file" class="hidden" x-on:change="send($event)">

        @if ($photoBox)
            <div class="ds-ph__cond" role="group" aria-label="How does the box look?">
                <span>How does the box look?</span>
                <div>
                    @foreach (\App\Models\BoxPhoto::CONDITIONS as $key => $label)
                        <button type="button" wire:click="setPhotoCondition('{{ $photoCondition === $key ? '' : $key }}')"
                                aria-pressed="{{ $photoCondition === $key ? 'true' : 'false' }}"
                                @class(['ds-ph__chip', 'is-'.$key, 'is-on' => $photoCondition === $key])>{{ $label }}</button>
                    @endforeach
                </div>
            </div>

            @if (in_array($photoCondition, ['damaged', 'wet', 'open'], true))
                <p class="ds-ph__tip">Tip: add a photo of this {{ \App\Models\BoxPhoto::CONDITIONS[$photoCondition] }} box. It is optional.</p>
                <input type="text" class="ds-ph__note" wire:model.blur="photoNote" maxlength="250" placeholder="What is wrong? (optional)" aria-label="What is wrong?">
            @endif

            @php($shots = $this->lastBoxPhotos())
            @if ($shots->isNotEmpty())
                <div class="ds-ph__shots">
                    @foreach ($shots as $shot)
                        <a data-ds-photo href="{{ $shot->url() }}" target="_blank" title="{{ $shot->fileName() }}"><img src="{{ $shot->url() }}" alt="Photo {{ $loop->iteration }} of {{ $shot->invoice }}" loading="lazy"></a>
                    @endforeach
                    <span>{{ $shots->count() }} {{ str('photo')->plural($shots->count()) }} saved</span>
                </div>
            @endif

            <button type="button" class="ds-ph__add" x-on:click="take(false)" x-bind:disabled="busy">
                <x-filament::icon icon="heroicon-o-camera" class="h-5 w-5" />
                <span x-show="! busy">{{ $shots->isEmpty() ? 'Add photo (optional)' : 'Add another photo' }}</span>
                <span x-show="busy" x-cloak>Saving photo… <span x-text="pct + '%'"></span></span>
            </button>
        @endif

        @if ($this->batchDue())
            <div class="ds-ph__batch">
                <span><strong>Batch photo?</strong> {{ $sinceBatch }} boxes since the last one.</span>
                <button type="button" x-on:click="take(true)" x-bind:disabled="busy">Take</button>
                <button type="button" class="is-skip" wire:click="skipBatch">Skip</button>
            </div>
        @endif

        <p class="ds-ph__err" x-show="failed" x-cloak>The photo did not upload. Check the signal and try again.</p>
    </div>
@endif
