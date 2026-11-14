<?php

namespace Database\Seeders;

use App\Models\Boxissue;
use App\Models\Company;
use App\Models\Companyprofile;
use App\Models\Consolidator;
use App\Models\Container;
use App\Models\Deliverylog;
use App\Models\Invoice;
use App\Models\Invoiceissue;
use App\Models\Logistichub;
use App\Models\Panelcategory;
use App\Models\Routearea;
use App\Models\Tripinvoice;
use App\Models\Truck;
use App\Models\Truckcrew;
use App\Models\User;
use App\Models\Warehouse;
use App\Models\Whdeliverylog;
use App\Models\Whtripinvoice;
use App\Models\Workposition;
use BezhanSalleh\FilamentShield\Facades\FilamentShield;
use Filament\Facades\Filament;
use Illuminate\Database\Seeder;
use Illuminate\Support\Facades\Auth;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\File;
use Spatie\Permission\Models\Permission;
use Spatie\Permission\Models\Role;

/**
 * Demo data for local development and automated tests.
 *
 * Creates one login per panel (password: "password"):
 *   admin@example.com      → /            (Admin panel, super_admin role)
 *   company@example.com    → /company     (Company / partner hub)
 *   warehouse@example.com  → /warehouse   (Warehouse)
 *   driver@example.com     → /delivery    (Driver / crew)
 *
 * Run with: php artisan db:seed --class=DemoSeeder
 */
class DemoSeeder extends Seeder
{
    /**
     * Every permission the policies and shielded pages check, so the demo
     * super_admin can open everything (same result as `shield:generate --all`).
     */
    protected function allShieldPermissions(): array
    {
        $fromPolicies = collect(File::files(app_path('Policies')))
            ->flatMap(fn ($file) => preg_match_all("/can\\('([^']+)'\\)/", $file->getContents(), $m) ? $m[1] : []);

        Filament::setCurrentPanel(Filament::getPanel('admin'));
        $fromPages = collect(FilamentShield::getPages())->flatMap(fn (array $page) => array_keys($page['permissions']));

        return $fromPolicies->merge($fromPages)->unique()
            ->map(fn (string $name) => Permission::findOrCreate($name, 'web'))
            ->all();
    }

    public function run(): void
    {
        DB::transaction(function (): void {
            // Bootstrap user so foreign keys on lookup tables (user_id) can be satisfied.
            $bootstrapId = DB::table('users')->insertGetId([
                'first_name' => 'System',
                'last_name' => 'Admin',
                'address' => 'Head Office',
                'email' => 'admin@example.com',
                'password' => bcrypt('password'),
                'is_admin' => true,
                'company_id' => 0,
                'panelcategory_id' => 0,
                'logistichub_id' => 0,
                'workposition_id' => 0,
                'created_at' => now(),
                'updated_at' => now(),
            ]);

            $panels = collect([
                'adm' => 'Administrator',
                'co' => 'Company',
                'whse' => 'Warehouse',
                'drv' => 'Delivery',
            ])->map(fn (string $description, string $code) => Panelcategory::create([
                'code' => $code,
                'description' => $description,
                'user_id' => $bootstrapId,
            ]));

            $mainHub = Logistichub::create([
                'hub_code' => 'MNL', 'hub_name' => 'Manila Main Hub',
                'is_company' => false, 'user_id' => $bootstrapId,
            ]);
            $partnerHub = Logistichub::create([
                'hub_code' => 'CEB', 'hub_name' => 'Cebu Partner Hub',
                'is_company' => true, 'user_id' => $bootstrapId,
            ]);

            $driverPosition = Workposition::create([
                'code' => 'DRV', 'position_description' => 'Driver', 'is_crew' => true,
                'panelcategory_id' => $panels['drv']->id, 'user_id' => $bootstrapId,
            ]);
            $staffPosition = Workposition::create([
                'code' => 'STF', 'position_description' => 'Staff', 'is_crew' => false,
                'panelcategory_id' => $panels['adm']->id, 'user_id' => $bootstrapId,
            ]);

            $company = Company::create([
                'company_name' => 'Cebu Partner Logistics', 'company_mobileno' => '09170000000',
                'company_phone' => '0320000000', 'company_address' => 'Cebu City',
                'user_id' => $bootstrapId, 'logistichub_id' => $partnerHub->id,
            ]);

            $warehouse = Warehouse::create([
                'name' => 'Calgary Warehouse', 'address' => '100 Industrial Way',
                'city' => 'Calgary', 'province' => 'Alberta', 'user_id' => $bootstrapId,
            ]);

            DB::table('users')->where('id', $bootstrapId)->update([
                'company_id' => $company->id,
                'panelcategory_id' => $panels['adm']->id,
                'logistichub_id' => $mainHub->id,
                'workposition_id' => $staffPosition->id,
                'warehouse_id' => $warehouse->id,
            ]);
            $admin = User::find($bootstrapId);

            $makeUser = fn (string $email, string $first, string $panel, int $hubId, int $positionId, bool $isCrew = false) => User::create([
                'first_name' => $first, 'last_name' => 'Demo', 'address' => 'Demo address',
                'email' => $email, 'password' => 'password',
                'is_admin' => false, 'is_crew' => $isCrew,
                'company_id' => $company->id, 'panelcategory_id' => $panels[$panel]->id,
                'logistichub_id' => $hubId, 'workposition_id' => $positionId,
                'warehouse_id' => $warehouse->id,
            ]);

            $companyUser = $makeUser('company@example.com', 'Carla', 'co', $partnerHub->id, $staffPosition->id);
            $warehouseUser = $makeUser('warehouse@example.com', 'Wade', 'whse', $mainHub->id, $staffPosition->id);
            $driver = $makeUser('driver@example.com', 'Dan', 'drv', $mainHub->id, $driverPosition->id, true);

            $role = Role::findOrCreate('super_admin', 'web');
            $role->syncPermissions($this->allShieldPermissions());
            foreach ([$admin, $companyUser, $warehouseUser, $driver] as $user) {
                $user->assignRole($role);
            }

            Companyprofile::create([
                'company_name' => 'Dispatch System Inc.', 'company_address' => '1 Main St',
                'company_barangay' => 'Poblacion', 'company_city' => 'Makati', 'company_province' => 'Metro Manila',
                'company_zipcode' => '1200', 'company_email' => 'info@example.com',
                'company_mobile_no' => '09171112222', 'company_office_no' => '0281112222',
            ]);

            $consolidator = Consolidator::create([
                'company_name' => 'Forex Cargo', 'code' => 'FX', 'address' => 'Calgary, AB',
                'mobile_no' => '4030000000', 'email' => 'ops@forex.example', 'user_id' => $bootstrapId,
            ]);

            $routes = collect(['NCR' => 'Metro Manila', 'VIS' => 'Visayas', 'MIN' => 'Mindanao'])
                ->map(fn ($description, $code) => Routearea::create([
                    'code' => $code, 'description' => $description, 'user_id' => $bootstrapId,
                ]))->values();

            $container = Container::create([
                'consolidator_id' => $consolidator->id, 'user_id' => $bootstrapId,
                'container_no' => 'MSCU1234567', 'booking_no' => 'BK-001', 'batch_no' => '12',
                'batch_year' => now()->year, 'seal_number' => 'SEAL-01', 'size' => '40',
                'type' => 'HC', 'total_boxes' => 12, 'warehouse_id' => $warehouse->id,
            ]);

            $invoices = collect(range(1, 12))->map(fn (int $n) => Invoice::create([
                'container_id' => $container->id, 'invoice' => 'INV'.str_pad((string) $n, 5, '0', STR_PAD_LEFT),
                'batchno' => '12', 'sender_name' => "Sender {$n}", 'receiver_name' => "Receiver {$n}",
                'receiver_address' => "{$n} Rizal St", 'receiver_province' => $n % 2 ? 'Cebu' : 'Metro Manila',
                'receiver_city' => $n % 2 ? 'Cebu City' : 'Quezon City', 'receiver_barangay' => 'Brgy '.$n,
                'receiver_mobile_no' => '0917'.str_pad((string) $n, 7, '0', STR_PAD_LEFT),
                'boxtype' => $n % 3 ? 'Regular' : 'Jumbo', 'routearea_id' => $routes[$n % 3]->id,
                'location_code' => 'FX', 'warehouse_id' => $warehouse->id, 'is_verified' => $n <= 8,
                'is_assigned' => $n <= 6,
            ]));

            Boxissue::create(['issue_type' => 'Damaged box']);
            Boxissue::create(['issue_type' => 'Missing item']);

            $truck = Truck::create([
                'category' => '10-wheeler', 'description' => 'Isuzu Forward', 'registration_no' => 'REG-1',
                'plate_no' => 'ABC 1234', 'user_id' => $bootstrapId, 'date_registered' => now()->subYear(),
                'date_expired' => now()->addYear(), 'logistichub_id' => $mainHub->id,
            ]);
            Truckcrew::create(['truck_id' => $truck->id, 'crew' => $driver->id, 'user_id' => $bootstrapId]);

            // Trip numbers are generated from the logged-in user's hub.
            Auth::login($admin);
            $trip = Deliverylog::create([
                'truck_id' => $truck->id, 'trip_day' => 1, 'logistichub_id' => $mainHub->id,
                'eta' => now()->addDay(), 'departure_date' => now(), 'assigned_to' => $mainHub->id,
                'user_id' => $bootstrapId, 'is_active' => true,
            ]);

            foreach ($invoices->take(6) as $i => $invoice) {
                Tripinvoice::create([
                    'invoice' => $invoice->invoice, 'deliverylog_id' => $trip->id, 'invoice_id' => $invoice->id,
                    'is_loaded' => $i < 3, 'logistichub_id' => $mainHub->id,
                ]);
            }

            Auth::login($warehouseUser);
            $whTrip = Whdeliverylog::create([
                'truck_id' => $truck->id, 'warehouse_id' => $warehouse->id, 'departure_date' => now(),
                'delivery_date' => now()->addDays(2), 'user_id' => $warehouseUser->id,
                'user_whid' => $warehouse->id,
            ]);
            foreach ($invoices->slice(6, 3) as $invoice) {
                Whtripinvoice::create([
                    'whdeliverylog_id' => $whTrip->id, 'user_id' => $warehouseUser->id, 'truck_id' => $truck->id,
                    'warehouse_id' => $warehouse->id, 'invoice_id' => $invoice->id,
                ]);
            }
            Auth::logout();

            Invoiceissue::create([
                'invoice' => $invoices[0]->invoice, 'invoice_id' => $invoices[0]->id,
                'container_id' => $container->id, 'remarks' => 'Corner crushed',
                'user_id' => $warehouseUser->id, 'boxissue_id' => 1,
            ]);
        });
    }
}
