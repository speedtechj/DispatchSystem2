<?php

it('sends guests to the sign-in page', function () {
    $this->get('/')->assertRedirect('/login');
    $this->get('/login')->assertOk()->assertSee('Sign in');
});
