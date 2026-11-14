<?php

namespace App\Console\Commands;

use App\Models\Invoice;
use App\Models\Tripinvoice;
use App\Models\Whtripinvoice;
use Illuminate\Console\Command;
use Illuminate\Support\Facades\DB;

/**
 * One-time cleanup of trip rows whose trip was deleted.
 *
 *   php artisan inventory:clean          # show what would change
 *   php artisan inventory:clean --fix    # remove the rows and free the boxes
 */
class CleanInventory extends Command
{
    protected $signature = 'inventory:clean {--fix : Remove the leftover rows (otherwise only report)}';

    protected $description = 'Find and remove trip rows whose trip no longer exists, so those boxes count as inventory again';

    public function handle(): int
    {
        $tripRows = Tripinvoice::whereDoesntHave('deliverylog');
        $moveRows = Whtripinvoice::whereDoesntHave('whdeliverylog');

        $this->table(['Leftover rows', 'Count'], [
            ['Delivery trip rows with no trip', (clone $tripRows)->count()],
            ['Warehouse trip rows with no trip', (clone $moveRows)->count()],
        ]);

        $examples = (clone $tripRows)->limit(10)->pluck('invoice');
        if ($examples->isNotEmpty()) {
            $this->line('Examples: '.$examples->join(', '));
        }

        if (! $this->option('fix')) {
            $this->info('Nothing changed. Run again with --fix to clean up.');

            return self::SUCCESS;
        }

        DB::transaction(function () use ($tripRows, $moveRows): void {
            $tripInvoiceIds = (clone $tripRows)->pluck('invoice_id')->unique();
            $moveInvoiceIds = (clone $moveRows)->pluck('invoice_id')->unique();

            (clone $tripRows)->delete();
            (clone $moveRows)->delete();

            // Free the boxes that are no longer on any real trip.
            Invoice::whereIn('id', $tripInvoiceIds)->whereDoesntHave('tripInvoices')->update(['is_assigned' => false]);
            Invoice::whereIn('id', $moveInvoiceIds)
                ->whereNotIn('id', Whtripinvoice::select('invoice_id'))
                ->update(['wh_is_assigned' => false]);
        });

        $this->info('Done. Those boxes now count as inventory and can be put on a new trip.');

        return self::SUCCESS;
    }
}
