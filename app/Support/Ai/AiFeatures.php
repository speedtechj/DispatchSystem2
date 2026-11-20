<?php

namespace App\Support\Ai;

/** The AI helpers that can be switched on in Admin → Settings → AI. */
class AiFeatures
{
    /** key => [title, what it does, who uses it, needs the API key] */
    public const ALL = [
        'trips' => ['Trip helper', 'The AI inside Plan trips: type what matters today ("Rizal first, keep one truck free") and it orders the provinces and keeps trucks free. When this is off, Plan trips still makes trips with the system rules; only the type box is grey.', 'Admin · Warehouse · Partner hub · Plan trips', true],
        'aging' => ['Box aging', 'How long each box has waited since unload, at each stage. Late boxes in the bell, a morning summary, limits suggested from your history, and why boxes are late (AI).', 'Admin · Warehouse · Partner hub', false],
        'photo_check' => ['AI photo check', 'Looks at every box photo (scan and proof of delivery) and lists the ones that look damaged, wet, opened or blurry.', 'Admin · Warehouse · Partner hub', true],
        'ask' => ['Ask the system', 'Staff ask about boxes, containers, trips and drivers in plain words. It can only read.', 'Admin · Warehouse · Partner hub', true],
        'manifest' => ['Read a manifest', 'Reads a consolidator manifest (PDF, Excel, CSV or a photo) into a container\'s invoices, and fixes messy addresses.', 'Admin · Warehouse', true],
        'risky' => ['Risky deliveries', 'Lists boxes on trips that will likely fail, writes a text for the receiver, and warns the driver.', 'Admin · Partner hub · Driver app', true],
        'alerts' => ['Alerts', 'Checks every 15 minutes for unusual things: too-fast deliveries, boxes on two trips, boxes stuck, many failures in one barangay.', 'Admin · Warehouse · Partner hub', false],
        'issues' => ['Issue helper', 'On an Invoice Issue: sums it up, suggests the next step and writes the email to the consolidator with the photos.', 'Admin', true],
        'insights' => ['Insights', 'Forecast of boxes for the next 8 weeks and a weekly report for each partner hub.', 'Admin · Warehouse · Partner hub', true],
        'voice' => ['Driver voice note', 'In the Driver app, "Can\'t deliver": the driver says what happened and the reason and note are filled in.', 'Driver app', true],
        'sms_writer' => ['SMS writer', 'In Settings → SMS: make a text fit in 1 SMS, friendlier, or translate it to Tagalog or Bisaya. Also turns the driver\'s note ("wala tao, balik bukas") into a clear "not delivered" text.', 'Admin', true],
        'alert_explain' => ['Truck alerts explained', 'Each truck alert gets a short note: what probably happened (lunch, no signal, wrong turn), how worried to be, and what to do.', 'Admin · Warehouse · Partner hub', true],
        'day_summary' => ['End-of-day truck summary', 'After work: the day in short, and for each truck what went well and what to look at. Optional daily email.', 'Admin · Warehouse · Partner hub', true],
        'addresses' => ['AI address cleaning', 'Fixes messy addresses ("purok 3 near chapel, Lapu2" → "Purok 3, Pusok, Lapu-Lapu City, Cebu") so the map finds more stops, fills in a missing barangay from clues in the address, and so finds the right hub for a box in a city shared by two hubs. Unsure ones go to Addresses to check.', 'Admin · Warehouse · Partner hub', true],
        'fuel_receipts' => ['Read fuel receipts', 'In the Driver app, reads the fuel receipt photo (station, diesel or gasoline, liters, price, total, VAT, TIN) and the odometer photo, so the driver does not type them.', 'Driver app · Fuel', true],
        'box_sizes' => ['Box sizes: same box, different spelling', 'In Settings → Box sizes, finds box types on the manifests that are the same box written differently ("Bulilit" and "Small", "X-LARGE" and "XL") so you can join them.', 'Admin', true],
        'help_ask' => ['Help answers', 'In the Help guide, staff and drivers ask in their own words (English, Tagalog or Taglish) and get a short answer taken only from the guides, with the right guide to open.', 'Admin · Warehouse · Partner hub · Scan app · Driver app', true],
        'customer_chat' => ['Customer chat', 'A public page where receivers type their box number and ask questions. Answers come from tracking; anything else goes to staff.', 'Receivers · Admin · Partner hub', true],
    ];

    public static function title(string $key): string
    {
        return self::ALL[$key][0] ?? $key;
    }
}
