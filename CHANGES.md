# Dispatch System — changes in this update

## After you unzip

```bash
composer install
npm install && npm run build          # the new theme is now used by all 4 panels
php artisan migrate                   # adds lookup indexes (safe, no data changes)
php artisan optimize:clear
php artisan filament:assets
```

Want to try it locally with sample data? On a **fresh local database only**:

```bash
php artisan migrate:fresh --seed      # never run this on production
```

You get one login per panel (password `password`): `admin@example.com` (/),
`company@example.com` (/company), `warehouse@example.com` (/warehouse),
`driver@example.com` (/delivery).

Run the tests with `php artisan test` (51 tests).

---

## Box aging (switch on in Admin → Settings → AI)

- New page **Box aging** (Admin, Warehouse, Partner hub; each sees its own boxes). Every box that is not delivered has an age at its current stage (in container, waiting in the warehouse, on a warehouse transfer, at the partner hub, on a truck, after a failed try) and a total age since unload.
- Top: not delivered, late now, late tomorrow, % delivered on time (30 days). "Why boxes are late" with the next step: written by the AI when the key is set, plain reasons otherwise.
- Table by stage × 0–3 / 4–7 / 8–14 / 15+ days (green, amber, red); click a number to see the boxes. By hub/warehouse or consolidator.
- **Settings → Aging limits**: warning and late days per stage, and a total per region (Metro Manila, Luzon, Visayas, Mindanao). **Suggest from my history** works them out from your deliveries of the last 6 months (warning = slower than 3 of 4 boxes, late = slower than 9 of 10). Change with − / +, then **Use these limits**.
- **Morning summary** at the hour you choose: in the bell for Admin (all), Warehouse (their warehouse), Partner hub (their hub); email optional per group. "Send a summary now" to try it. Once a month Admin is told if the limits would change.
- Needs the scheduler: `php artisan schedule:work`.

## AI trip helper (Admin, Warehouse, Partner hub)

- New page **AI trip helper** (switch it on in Admin → Settings → AI). Press **Suggest trips**: boxes waiting for a trip are grouped by province → city → barangay and fitted to your free trucks (by truck capacity). Only trucks are picked, not drivers.
- Rules kept by the system, whatever the AI says: all boxes of the same receiver (same name and address, or same phone) stay on one trip; priority and tried-before boxes go first; a truck is never filled over its capacity; only free trucks of your hub and boxes not on a trip yet.
- It's a draft: change the truck, the destination ("Going to" hub, or the warehouse for transfers), click a barangay to move it to the next trip, add places that were left for later, remove a trip. Nothing is created until you press **Create**.
- Create makes the trip records exactly like the normal forms, so the trip numbers come from the system as always (hub code + next number, e.g. MNL13; warehouse transfers: warehouse number + next number).
- Admin: delivery trips. Warehouse: delivery trips and warehouse-to-warehouse transfers. Partner hub: its own trips for the boxes at its hub.
- Works without the AI key too (groups the places in order); with the key, the AI decides which places go together.
- Tip: set each truck's **capacity** (number of boxes) in Trucks. Trucks without it count as 50 boxes.

## AI helpers (switch on in Admin → Settings → AI)

- **Settings → AI**: paste the Anthropic API key (saved encrypted, never shown again), Test it, pick the models, set a monthly spending limit (the AI pauses when it is reached), switch each helper on or off, and see what each one cost this month.
- **AI photo check** (Admin, Warehouse, Partner hub): every scan photo and proof-of-delivery photo is checked by the AI after it is taken (scanning never waits). Photos that look damaged, wet, opened or blurry are listed; staff click "Damaged · open issue" (creates an Invoice Issue with the photo) or "Looks fine". In the Scan app the worker is asked "looks damaged?" a few seconds after the scan.
- **Ask the system** (Admin, Warehouse, Partner hub): questions in plain words, answered from your data with read-only look-ups. Partner hubs only get their own hub's data.
- **Read a manifest** (Admin, Warehouse): upload a PDF, Excel (.xlsx), CSV or photo; the AI reads every box, splits and fixes addresses, picks the route area. You check the list (duplicates and missing receivers are left out) and press Save.
- **Risky deliveries** (Admin, Partner hub): boxes on active trips likely to fail (tried before, wrong or missing phone, unclear address, refused before). The AI writes a text for the receiver in English, Tagalog or Bisaya; open it in Messages or copy it. The driver sees a "Heads up" on the box.
- **Alerts** (Admin, Warehouse, Partner hub, works without a key): every 15 minutes: too-fast deliveries, a box on two trips, boxes not moving after unload, boxes on a truck for days, many failures in one barangay, receivers who asked for a call.
- **Issue helper** (Invoice Issue list → "AI helper"): summary, next step and an email to the consolidator with the box photos. You edit and send.
- **Insights**: boxes expected in the next 8 weeks (from last year and this year's trend) with advice, and a weekly report for each partner hub.
- **Driver voice note**: in "Can't deliver" the driver taps the mic and says what happened; the reason and note are filled in.
- **Customer chat**: public page `/ask-box`. The receiver types the box number and the last 4 digits of the phone, then asks; answers come from tracking, complaints become an alert for staff.
- Keep the scheduler running (`php artisan schedule:work`) for alerts and photos that could not be checked right away.

## Driver app works without signal

- While there is signal, the Driver app keeps today's trip on the phone (boxes, names, addresses, reasons).
- No signal: a red bar says "No signal" and the app switches to its own screens. The driver can find a box (type it, pick from the list, or scan with the camera on phones that support it), deliver it with photos, or mark it "Can't deliver" with the reason's rules.
- Each one is kept on the phone, photos included, and listed under "Waiting to send" (can be removed before it sends).
- Opening or reloading the app with no signal opens the saved trip instead of the browser error.
- When the signal is back it sends by itself (also every 30 seconds while the app is open), oldest first, with the time it really happened. Sending twice never saves twice.
- If the office changed the box meanwhile (taken off the trip, delivered by someone else) it is not forced through: it shows under "Needs attention" with the reason.
- New table `offline_submissions` keeps a record of everything sent from a phone.
- After updating, run `php artisan filament:assets`.

## Security fixes

| Problem | Fix |
|---|---|
| The PDF receipt `/tripinv/{id}/printpdf` was public. Anyone could read any customer's name, address and phone by counting up the id. | Now requires sign-in. |
| Drivers could open `/delivery/invoices/{id}/edit` and edit or delete **any** invoice, and the scan dialog there could mark **any** invoice delivered. | Driver invoice list is read-only; create/edit pages removed; scanning only finds boxes on the driver's own trip. |
| Changing the number in `/deliverylogs/{id}/edit` opened another hub's trips. | Trip resources (admin, company, warehouse) only return your own hub's trips. |
| The "assign invoices" screens took the trip id from the browser and never checked it again, so invoices could be added to any trip. | The trip is checked on page load and then locked (`#[Locked]`); a wrong or missing trip gives a 404. |
| Deactivated users (`is_active = 0`) could still sign in. | Blocked in `User::canAccessPanel()`. A user without a panel category no longer causes an error. |
| Debug `dd()` calls left in the code (Unmanifested "Send Email", Container "Assign Invoice", `EmailService`). | Removed. The two unfinished buttons are hidden and marked TODO. |

## Logic fixes

- **Duplicate trip numbers:** two people creating trips at the same time could get the same number. The hub/warehouse counter is now locked while it increments.
- **Editing a trip without changing the truck set that truck to "free".** It now only swaps trucks when the truck actually changed.
- **Driver list showed already-delivered hub boxes** (missing brackets in the `where … or …` query).
- **Delivered boxes never showed as delivered on the invoice** (container screens etc.). Delivering now also sets `invoices.is_delivered`.
- **Delivery photos could fail to save** (an array written with a query-builder update). They now save through the model.
- **Unload Truck (warehouse) moved a box to your warehouse even when it belonged to a different trip.** It now checks first.
- **Company Load Truck** checked the wrong column (`is_loaded` instead of `is_loaded_hub`), so a hub trip never showed as fully loaded.
- **Load Truck "Invoice not found" showed as a green success message.** It is now red and says which trip the box is actually on.
- **Scanning before choosing a trip/container crashed the page.** It now asks you to choose first.
- **Scan fields only accepted numbers** (`->numeric()`). Alphanumeric invoice numbers now work, and spaces or lowercase from scanners are cleaned up.
- **Hub Route (warehouse)** had two `->query()` calls, so already-assigned invoices showed and could be added twice.
- **Profile photos were saved as `{last_name}.jpg`**, so two people with the same last name overwrote each other's photo.
- **Receipt PDF:** driver and assistant were always blank (it read columns that don't exist on `truckcrews`). It now uses the truck's crew, and doesn't crash when an invoice has no consolidator.
- **Deleting something still in use** (e.g. a trip with invoices) showed an error page. It now shows a clear message.
- Broken hidden page `Delivery/Pages/ScanBox` (missing view, missing class) removed; *My deliveries* already does the same job.
- Model class names with the wrong case (`DeliveryLog`, `TripInvoice`, `logistichub`) fixed. These break on Linux servers.
- Added boolean/date casts to the main models.
- `UserFactory` and `DatabaseSeeder` used columns that don't exist; both fixed.

## Code improvements

- **`App\Services\TripAssignment`:** one place for all trip bookkeeping (add, remove, return, load, deliver, release truck, swap truck), with each change in a database transaction and locked trips respected. The four panels used to have their own drifting copies.
- **Scan stations share code:** `Shared/LoadTripPage` (admin, warehouse hub, partner hub), `Shared/WarehouseTripScanPage` (warehouse load/unload) and `Shared/UnloadContainerPage` (admin and warehouse). About 900 duplicated lines removed.
- **`Tables/InvoicePickerTable`:** the "assign invoices" table, written once instead of three times.
- **Panel setup:** `ConfiguresDispatchPanel` holds the colours, theme, font, middleware and so on; each provider only lists what is specific to it.
- **Performance:**
  - Company names were looked up with one query per table row in about 20 places; now one query per page (`Consolidator::nameForCode()`).
  - Problem and company columns are eager-loaded.
  - New indexes on `invoices.invoice`, `(container_id, invoice)`, `location_code`, assignment flags, `tripinvoices.invoice` and `consolidators.code`. Every scan used to read the whole invoices table.
- Code style: Laravel Pint on every file that changed.
- **Tests:** smoke tests open every page of all 4 panels as the right user; workflow tests cover scanning, assigning, removing, delivering, trip numbering, truck swap and access rules.

## UI redesign

- **One look across all four panels** (Company and Delivery previously had no theme at all, so their custom pages were unstyled): navy sidebar, your signal-yellow brand colour, a container-door logo mark, the Archivo typeface, and a branded sign-in page.
- **Dashboards:**
  - Admin: waiting for a trip, on trucks now, delivered this week (with a chart), open box problems, and a "Trips on the road" table with loaded/delivered progress bars.
  - Warehouse: containers to unload, boxes to load, boxes arriving.
  - Partner hub: boxes waiting, out for delivery, delivered this week.
- **Scan stations rebuilt** (Load Truck, Unload Container, Unload Truck, Hub Load Truck):
  - Camera scanning on every station, not just the driver page.
  - A large result card: green, amber or red, with the invoice number big enough to read from arm's length.
  - A live "x of y loaded" progress bar.
  - A list of the other boxes for the same household, so nobody leaves one behind.
  - "Report a problem" and "Record as unmanifested box" buttons right on the result.
- **Assign invoices** screens:
  - The trip number is shown in the header.
  - "Back to trip" button.
  - Clear Add buttons.
  - One status badge (Priority / Returned / Resolved) instead of three icon columns.
  - Helpful empty states.
- **Driver (phone) view:**
  - "Trip MNL1 — 6 boxes left to deliver".
  - Address on one line.
  - Tap-to-call phone numbers.
  - Opens straight on the deliveries page.

## Sign-in pages (one design per panel)

| Panel | Address | Design |
|---|---|---|
| Admin | `/login` | Navy panel with company logo and name, form on the right |
| Company / partner hub | `/company/login` | Form on the left, yellow panel with the hub's four steps |
| Warehouse | `/warehouse/login` | Container-side background with one sign-in card |
| Delivery | `/delivery/login` | Built for drivers' phones: yellow top, large fields and button |

- The **company name and logo come from Admin → Company Info** (`companyprofiles`).
  - Change them there and all four pages update.
  - With no logo uploaded, the company's initials are shown.
  - With no profile at all, the `APP_NAME` from `.env` is used.
- Filament's own sign-in still runs underneath: validation, "remember me", rate limiting and (admin) forgot password.
- Every page works on phones.
- Files:
  - `app/Filament/Auth/*Login.php`
  - `app/Support/Branding.php`
  - `resources/views/filament/auth/`
  - `resources/views/components/auth/company.blade.php`
  - the "Sign-in pages" section at the end of `resources/css/filament/admin/theme.css`

## Company Info (logo, favicon, company details)

**Admin → Settings → Company Info** has three sections:
- **Branding:** logo and a new **favicon** (browser tab icon).
- **Company:** name, email, website, mobile and office numbers.
- **Address:** street, barangay, city, province and ZIP code.

What's new:
- The logo and company name show in the header of all 4 panels and on all 4 sign-in pages. The favicon shows in the browser tab everywhere.
- **Logo** accepts PNG, JPG, SVG or WebP up to 2 MB. **Favicon** accepts PNG, ICO or SVG up to 512 KB.
- New uploads get a unique filename, so they no longer overwrite each other. Replaced files are deleted from the server.
- Email and website are checked for a valid format. Website and office number are now optional.
- Fixed the page heading, which said "Scan Invoice".
- Migration `2026_11_11_000001_add_favicon_to_companyprofiles_table` adds the `favicon` column.

## "Can't deliver" with a reason (Delivery panel)

**For drivers:**
- Every box has a **Can't deliver** button. The scan window has one too.
- The driver picks a reason from 9 options (no one home, address not found, phone not answering, refused, asked for another day, can't reach the area, box damaged, ran out of time, other). Each has a one-line explanation.
- A **photo** is required for no one home, address not found, can't reach the area and box damaged. A **note** is required for refused, asked for another day and other.
- The box stays on the truck and shows **"Not delivered · reason"**. The page header shows how many boxes are left and how many weren't delivered yet.

**For the office:**
- The dispatcher who created the trip gets a **notification** (the bell icon) with the reason, the driver, the note and the attempt number.
- The trip's invoice list has a **Delivery** column with the latest reason. Hover over it to see the note.
- The **Delivery attempts** menu item shows the full history with photos.

**Under the hood:**
- New `delivery_attempts` table (migration `2026_11_11_000002`), one row per attempt, so the history is kept.
- Reasons are defined in `app/Enums/FailedDeliveryReason.php`. Add or rename reasons there.

## Driver dashboard (Delivery panel home page)

Drivers now land on **Today** after signing in. It refreshes by itself every minute.
- **Trip card:** trip number, truck and plate, crewmates, and "X of Y delivered" with a progress bar and how many are left.
- **Scan a box** and **All boxes** buttons.
- **Priority boxes** at the top, with tap-to-call.
- **Where to go next:** remaining boxes grouped by city and barangay, then by household ("3 boxes — same household"). Tap an area to open it.
- **Check before handing over:** boxes with a problem reported at unloading.
- **Delivered today:** the latest deliveries with the proof photo.
- Two other states: **All boxes delivered** and **Not on a trip right now**.
- Code: `app/Filament/Delivery/Pages/Dashboard.php`, `app/Support/DriverTrip.php`, `resources/views/filament/delivery/pages/dashboard.blade.php`.

## Return undelivered boxes to inventory (scan back in)

When a truck comes back, staff open **Return Boxes** and scan every box that wasn't delivered:
- **Admin:** Scanning → Return Boxes
- **Warehouse:** Hub → Hub Return Boxes
- **Partner hub:** Return Boxes

What happens to each scanned box:
- It's **taken off the trip** and goes back to **Assign invoices**, marked **Returned**, ready for the next trip. For partner hubs it goes back to the hub's own list.
- The scan card shows **what the driver said** (reason and note). **Assign invoices** has a new **Last delivery attempt** column with the same reason, so dispatchers can see why a box is back.
- Delivered boxes, boxes from another trip and boxes already returned are refused, with a clear message.
- The driver's reasons and photos are **kept** after the box leaves the trip (migration `2026_11_11_000003`).

## Behaviour changes to know about

- On **Scan Invoice / Unload Container**, an unmanifested box no longer pops a form up automatically, because that blocked continuous camera scanning. A **"Record as unmanifested box"** button appears instead.
- **Hub Route** now only lists invoices not yet assigned (`is_assigned = 0`), the same as the admin screen.
- **Admin panel email verification** was switched on, but the `users` table has no `email_verified_at` column, so it never did anything. It has been removed.

## Undo a delivery marked by mistake

- **Right after delivering**: a 15-second toast with an **Undo** button (driver).
- **Delivered today** on the driver dashboard: **Undo** with a reason for 30 minutes on the driver's own deliveries; after that it shows "Office only".
- **Office** (Admin, Warehouse, Partner hub trip lists): **Mark as not delivered** any time, with a required reason. The driver is notified.
- Every undo keeps the delivery photo and is saved in the box's **Delivery history**, alongside failed attempts.
- New columns `tripinvoices.delivered_at` / `delivered_by` and table `delivery_reversals` (run `php artisan migrate`).

## Inventory counts fixed

- **Boxes with no trip now count.** Before, a box only showed in Inventory if it had a trip row, so boxes waiting for a trip (and boxes returned to inventory) were missing.
- **Trip rows whose trip was deleted are ignored**, and they no longer stop the box from going on a new trip. Clean them up once with `php artisan inventory:clean` (report) then `php artisan inventory:clean --fix`.
- **Warehouse to warehouse (e.g. to Tarlac):** the box stays in the sending warehouse until it is loaded on the truck, counts nowhere while on the truck, and joins the receiving warehouse only when it is unloaded there. The receiving warehouse sees an "On the way here" card.
- One rule for "on the floor" (`Inventory::onFloor()`), used by the Admin and Warehouse inventory lists and counters.

## Delivery Log widgets

On top of **Delivery Log** (Admin), **Hub Deliverylog** (Warehouse), the partner hub's **Delivery Log** (Company) and **WH Delivery Logs** (Warehouse):

- **Today at a glance:** On the road, Being loaded, Delivered/Received today, Problems today (Late for warehouse trips). Click a card to filter the list.
- **Needs attention:** late trips, trips with boxes not delivered today, loaded but not locked (Lock trip), truck still in use after every box is delivered (Release truck), trips still empty.
- **Trends:** boxes delivered/received per day (14 days), and why boxes were not delivered (or where warehouse boxes were sent) in the last 7 days.
- New **Status** and **Progress** columns and a **Status** filter in each list.
- Code: `App\Support\TripBoard` (numbers and status), `App\Filament\Shared\Widgets\TripBoard` (widget), `App\Filament\Tables\TripBoardColumns` (columns and filter).

## Driver app (install the Delivery panel as an app)

Only the **Delivery** panel is installable; Admin, Warehouse and Partner hub stay normal websites.

- **Speedtech Driver** app: opens full screen at the driver's trip. The icon is drawn from the Company Info logo with a green "DRV" strip, and updates when the logo changes.
- Home-screen shortcuts: **Scan a box** (opens the camera scanner), **My deliveries**, **Today's trip**.
- **Install app** in the user menu (Android and desktop Chrome). On iPhone, a one-time tip shows Share → Add to Home Screen.
- **No signal:** a clear screen instead of the browser error; the page comes back by itself when the phone is online.
- The service worker only looks after `/delivery` pages, keeps CSS/JS/fonts/logo for fast start, and never stores signed-in pages or form posts.
- Needs HTTPS on the live site (localhost works for testing). The PHP GD extension draws the icon; without it the logo is used as is.
- Files: `app/Support/Pwa.php`, `app/Http/Controllers/PwaController.php`, `resources/views/pwa/*`, routes in `routes/web.php`, hooks in `DeliveryPanelProvider`.

## App icon & favicon upload

**Admin → Settings → App icon & favicon** (super admins only):

- **Favicon:** the browser tab icon of all four panels and their sign-in pages. Applies on the next page load.
- **Driver app icon:** the Speedtech Driver app icon. Leave empty to keep the icon drawn from the company logo. Android gets a round-safe version automatically. Android drivers are offered the new icon the next time they open the app; iPhone keeps the old icon until the app is removed and added again.
- New table `brand_assets` (run `php artisan migrate`). Files are stored on the public disk under `brand/`.
- Does not depend on the Company Info page; if no favicon is uploaded here, the Company Info favicon (if any) or the built-in one is used.

## Widgets: Containers, Vehicles, Invoice Issue, scan progress

- **Containers** (Admin, Warehouse): Waiting to unload, Unloading now, Unloaded this week, Boxes missing (on the manifest, never scanned, for containers marked unloaded in the last 30 days). Needs attention: missing boxes, unmanifested boxes, containers waiting 2+ days. Charts: boxes unloaded per day, boxes this month by consolidator.
- **Vehicles** (Admin, Warehouse, Partner hub; each hub's own vehicles): Active, On a trip now, Free, Registration expired/expiring within 30 days. Needs attention: expired, expiring, no crew. Charts: registrations due, vehicles by type.
- **Invoice Issue** (Admin; Warehouse = own warehouse): issues this week vs last week, unmanifested boxes, containers with issues, issues per 1,000 boxes scanned. Charts: by type, by container. Latest 5 issues with photos.
- **Scan screens** (Unload Container, Load Truck): the progress strip shows boxes left and the time of the last scan; Unload Container also shows boxes with a problem and unmanifested boxes for that container.
- New columns `invoices.verified_at` (set when a box is scanned off its container) and `containers.unloaded_at` (set when a container is marked unloaded). Older rows stay empty, so "per day" and "per 1,000 boxes" start counting from this update. Run `php artisan migrate`.
- Code: `App\Support\Boards\*`, `App\Filament\Shared\Widgets\ModuleBoard`, `App\Support\AppHooks`.

## Invoice Issue: open issues slider

- "Latest issues" is now **Open issues**: a slider that moves by itself every 4 seconds (pauses while the mouse is over it or it has keyboard focus; does not move if the device asks for reduced motion), with arrows and dots. 4 cards on wide screens, fewer on phones.
- **Every** issue whose box is **not resolved** is shown, newest first (more than 10 positions: a "5 / 40" counter replaces the dots). Each slide has **Mark resolved**; switching **Resolved** on in the list also removes it from the slider straight away, and switching it off brings it back.
- "Issues per 1,000 boxes" waits until 100 boxes are scanned in the week, so small numbers do not give a misleading rate.

## Boxes per hub

- **Admin dashboard → Boxes by hub:** cards (boxes at hubs now, waiting at hubs, delivered today, not delivered today) and one row per active hub with a bar and columns: waiting at hub, loading, out for delivery, delivered today, this month, failed today. Sort by most boxes now / delivered today / A–Z. Click a hub to open its trips in Delivery Log.
- **Logistic Hubs list:** sortable Waiting (red above 250), On trucks, Delivered today and This month columns.
- **Partner hub dashboard:** the hub's own boxes as steps (handed to you → loading → out for delivery → delivered today), and a warning with **Plan a trip** when boxes wait more than 2 days after their main trip's ETA.
- Main hubs have no "waiting" count: their boxes stay in warehouse inventory until they go on a trip.
- One query for all hubs: `App\Support\HubBoxes`.

## Partner hub (Company) panel

- **Dashboard:** greeting with trucks out/free, **Track a box** search and **Plan a trip**; your boxes as steps; **Drivers today** (each open trip: driver, truck, areas, delivered progress, status); **Needs attention** (boxes waiting 2+ days, failed today, registrations, drivers without a truck); **Delivered this week**; **Your hub score** (first-try success vs the whole network, delivered within 2 days of arrival, average wait before a trip).
- **Incoming boxes** (new): boxes waiting at the hub grouped by city and barangays with the oldest wait; tap areas, see boxes and trucks needed, then **Create trip with these boxes** (creates the hub trip and puts the boxes on it). Also an "Oldest first" list. Menu badge shows how many are waiting.
- **Drivers** (new, `/company/driver-leaderboard`): delivered, first-try success, failed, most common reason, truck; this week / 30 days / this year.
- **Not delivered** (new): boxes with a failed attempt, grouped by reason with a tip; **Put on a trip** (one box or all of a reason) or **Return**. Menu badge shows the count.
- **Track a box** (new): scan or type a number; timeline (unloaded, handed to the hub, out for delivery, failed attempts with photos, undone, delivered with photo) and the receiver's details with a **Call** link. Only the hub's own boxes.
- Trucks have a **Capacity (boxes)** field (empty = 60), used to say how many trucks a planned trip needs. Run `php artisan migrate`.
- Code: `App\Support\HubDesk`, `App\Filament\Company\Pages\*`, `App\Filament\Company\Widgets\*`.


## Box photos (optional, every box)

- **Where:** Unload Container, Load Truck / Scan Load, partner hub Load Truck, warehouse-to-warehouse load and unload, and Return Boxes. After a box is scanned: tap how it looks (Good, Damaged, Wet, Open) and press **Add photo (optional)**, as many times as needed. Scanning never waits for a photo.
- **Each photo is its own file**, made smaller on the phone (max 1600 px, about 200 KB) and stamped with the invoice, step, condition, date and who took it. File names: `INV004521_unload_1.jpg`, `INV004521_unload_2.jpg`.
- **Box Photos** (Admin, Warehouse, Partner hub): search by invoice, container or trip; filter by place and condition; view, download one, or download selected as one ZIP; **Email to consolidator** (To is filled from the consolidator's email; every email is logged under "Sent emails").
- **Search Invoice → Photos** and **Track a box** (partner hub) show all photos of the box in order.
- **Admin → Settings → Box photos:** switch each place on or off, optional batch photo reminder, keep time (default 6 months; boxes with an open Invoice Issue are kept). `php artisan photos:prune` runs daily from the scheduler.
- Photos are private: served only to signed-in users; partner hubs see only their own boxes.
- Email needs the `MAIL_` settings in `.env`.

### Box Photos: new design

- The page is empty until you search an invoice, container or trip number; your last 5 searches show as **Recent**.
- Results are grouped by box: invoice, worst condition, the journey (Unload → WH transfer → Load …) as coloured dots, then its scan photos.
- **Delivered** card (green) with every proof-of-delivery photo from the driver, and **Not delivered** cards (amber) with the reason and photos.
- Viewer on the right with arrows (or ← → keys), photo strip, note, who and when, file name, Download and Select.
- Select photos with ✓; a bar at the bottom offers **Download ZIP** and **Email to consolidator** (delivery photos included).
- Works in light and dark mode. Search Invoice → Photos and Track a box now include the delivery photos too.


## Scan app (`/scan`, installs on the phone)

- One phone app for loading and unloading crews, at `/scan`. Install it from the browser (Android: Install app; iPhone: Share → Add to Home Screen) like the Driver app.
- Sign in with the same account. The app shows only the scans for that account type:
  - **Warehouse:** Unload container, Load truck, Warehouse load, Warehouse unload, Return boxes (own warehouse only)
  - **Company / partner hub:** Hub load, Return boxes (own hub only)
  - **Office (admin):** Unload container, Load truck, Return boxes
  - Drivers can't open it (they use the Driver app).
- Steps: Start → pick the container or trip (with progress) → scan with the camera or a handheld scanner → result slides up (condition + optional photos) → Done.
- Scanning uses the same rules as the existing scan pages, so inventory, unmanifested boxes and Box Photos stay correct. Wrong boxes are refused with a clear message; on Unload container they can be recorded as unmanifested.
- The existing scan pages in the panels are unchanged.

### Scan app: only what still needs scanning

- The pick list hides containers and trips that are closed (inactive, or container marked unloaded) or 100% scanned. Started ones come first.
- "Show finished (n)" at the bottom shows them greyed out, so a supervisor can still re-check one.
- The start screen shows how many are waiting for each scan ("2 waiting" / "All done").
- Return boxes lists every trip that still has boxes to return, even closed trips.

### App names and icons per app

- Admin → Settings → App icon & favicon now has a **Driver app** and a **Scan app** section, each with **Name on the phone** and its own **Icon**.
- Empty name → "Speedtech Driver" / "Speedtech Scan"; empty icon → the icon drawn from the company logo (Driver has a green DRV strip, Scan a yellow SCN strip).
- Android offers the new name and icon the next time the app is opened. iPhone keeps the old ones until the app is removed and added to the Home Screen again.
- Run `php artisan migrate` (adds 3 columns to brand_assets).

## Driver app: new design (same style as the Scan app)

- `/delivery` is now one phone app with three screens:
  - **Today:** progress ring, Scan a box to deliver, priority boxes, boxes to check before handing over, where to go next (tap an area to see its boxes), delivered today with Undo (30 minutes), your crew.
  - **Boxes:** search; To deliver / Delivered / Not delivered; call the receiver.
  - **Scan:** full-screen camera (or type the number). The box slides up with the receiver, Call and Directions, then Deliver (take as many proof photos as needed; at least one) or Can't deliver (reason, note and up to 3 photos, same rules as before).
- After delivering, a green bar offers **Undo** for 15 seconds.
- Same rules as before (TripAssignment): photos are saved on the box, the office is told about not-delivered boxes, undo keeps the history.
- App shortcuts now open the camera (`/delivery?view=scan`) and the boxes list (`/delivery?view=list`). The old "My deliveries" table is still at `/delivery/deliveryinv`.

