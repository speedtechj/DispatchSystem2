@props(['size' => 'md', 'tone' => 'light'])
@php($logo = \App\Support\Branding::logoUrl())

<span {{ $attributes->class(["ds-company ds-company--{$size} ds-company--{$tone}"]) }}>
    @if ($logo)
        <img src="{{ $logo }}" alt="" class="ds-company__logo">
    @else
        <span class="ds-company__logo ds-company__logo--initials" aria-hidden="true">{{ \App\Support\Branding::initials() }}</span>
    @endif
    <span class="ds-company__text">
        <span class="ds-company__name">{{ \App\Support\Branding::companyName() }}</span>
        {{ $slot }}
    </span>
</span>
