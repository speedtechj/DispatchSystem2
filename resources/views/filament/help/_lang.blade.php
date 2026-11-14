<span class="ds-help__lang" role="group" aria-label="Language">
    <button type="button" wire:click="setLang('en')" @class(['is-on' => $lang === 'en']) aria-pressed="{{ $lang === 'en' ? 'true' : 'false' }}">English</button>
    <button type="button" wire:click="setLang('tl')" @class(['is-on' => $lang === 'tl']) aria-pressed="{{ $lang === 'tl' ? 'true' : 'false' }}">Tagalog</button>
</span>
