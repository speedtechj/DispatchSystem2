<?php

namespace Database\Seeders;

use Illuminate\Database\Seeder;

class DatabaseSeeder extends Seeder
{
    /**
     * Local development only: `php artisan migrate:fresh --seed` gives you
     * one demo login per panel (see DemoSeeder). Never run this in production.
     */
    public function run(): void
    {
        if (app()->isProduction()) {
            $this->command?->warn('Skipping demo data in production.');

            return;
        }

        $this->call(DemoSeeder::class);
    }
}
