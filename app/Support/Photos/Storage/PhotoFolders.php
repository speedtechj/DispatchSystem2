<?php

namespace App\Support\Photos\Storage;

use App\Models\AppSetting;
use Illuminate\Support\Carbon;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Schema;
use Illuminate\Support\Str;

/**
 * One tidy folder structure (board 67): kind / year / month / invoice. The same on this server,
 * in R2 or in S3. New photos are saved here; old photos can be put here while they are copied
 * or moved to the bucket (the path in the database is changed after the copy is checked).
 */
class PhotoFolders
{
    /** Folders for each kind of photo (shown on the Photo storage page). */
    public const MAP = [
        ['Delivered (POD)', 'delivery/2026/11/0144033/…'],
        ['Not delivered', 'not-delivered/2026/11/0144033/…'],
        ['Box photos (scan app)', 'scan/unload/2026/11/0144033/…'],
        ['Damage (box issue)', 'damage/2026/11/…'],
        ['Unmanifested box', 'unmanifested/2026/11/…'],
        ['Sea shipment, at port, LCL pick-up', 'shipments/2026/11/SS-0042/…'],
        ['Fuel receipt, odometer', 'fuel/2026/11/ABC1234/…'],
        ['Truck pictures', 'trucks/ABC1234/…'],
        ['People (users, crew)', 'people/…'],
        ['Company and agent papers', 'papers/companies/… · papers/containers/…'],
    ];

    /** The folder for a new photo: kind / year / month / ref (invoice, plate, shipment). */
    public static function dir(string $kind, ?string $ref = null, mixed $at = null): string
    {
        $at = $at ? Carbon::parse($at) : now();
        $dated = in_array($kind, ['trucks', 'people', 'papers/companies', 'papers/containers', 'papers/consolidators'], true)
            ? $kind : $kind.'/'.$at->format('Y/m');

        return $dated.(filled($ref) ? '/'.static::clean((string) $ref) : '');
    }

    public static function clean(string $ref): string
    {
        return trim(preg_replace('/[^A-Za-z0-9._-]+/', '-', $ref), '-.') ?: 'x';
    }

    /** New photos at most this many KB (0 = no limit). */
    public static function maxKb(): int
    {
        return (int) AppSetting::get('photos.max_kb', 200);
    }

    /**
     * Columns that hold photo paths, and how to find each photo's kind, date and invoice.
     * [table.column => [kind, date column, ref: callable(row) => ?string]]
     */
    public static function known(): array
    {
        $inv = fn ($id) => $id ? DB::table('invoices')->where('id', $id)->value('invoice') : null;
        $plate = fn ($id) => $id ? DB::table('trucks')->where('id', $id)->value('plate_no') : null;

        return [
            'tripinvoices.delivery_picture' => ['delivery', ['delivered_at', 'updated_at'], fn ($r) => $r->invoice ?? $inv($r->invoice_id ?? null)],
            'delivery_attempts.photos' => ['not-delivered', ['created_at'], fn ($r) => $inv($r->invoice_id ?? null)],
            'invoiceissues.attachment_pic' => ['damage', ['created_at'], fn ($r) => $r->invoice ?? null],
            'unmanifesteds.attachment_pic' => ['unmanifested', ['created_at'], fn ($r) => $r->invoice ?? null],
            'fuel_fills.receipt_path' => ['fuel', ['filled_at', 'created_at'], fn ($r) => $plate($r->truck_id ?? null)],
            'fuel_fills.odometer_path' => ['fuel', ['filled_at', 'created_at'], fn ($r) => $plate($r->truck_id ?? null)],
            'sea_shipments.seal_photo' => ['shipments', ['created_at'], fn ($r) => $r->code ?? null],
            'sea_shipments.port_receipt' => ['shipments', ['created_at'], fn ($r) => $r->code ?? null],
            'sea_shipments.pickup_photo' => ['shipments', ['pickup_at', 'created_at'], fn ($r) => $r->code ?? null],
            'trucks.truck_picture' => ['trucks', [], fn ($r) => $r->plate_no ?? null],
            'users.profile_picture' => ['people', [], fn ($r) => null],
            'containers.container_picture' => ['papers/containers', [], fn ($r) => $r->container_no ?? null],
            'companies.company_picture' => ['papers/companies', [], fn ($r) => null],
            'companies.company_document' => ['papers/companies', [], fn ($r) => null],
            'consolidators.company_document' => ['papers/consolidators', [], fn ($r) => null],
            'box_photos.path' => ['scan', ['taken_at', 'created_at'], fn ($r) => $r->invoice ?? 'batch'],
        ];
    }

    /** Where an old photo goes in the new folders, from its record (null: not a known column). */
    public static function newPath(string $table, string $column, object $row, string $old): ?string
    {
        $k = static::known()[$table.'.'.$column] ?? null;
        if (! $k) {
            return null;
        }
        [$kind, $dates, $ref] = $k;
        if ($table === 'box_photos') {
            $kind = 'scan/'.static::clean((string) ($row->step ?? 'photo'));
        }
        $at = collect($dates)->map(fn ($c) => $row->{$c} ?? null)->first(fn ($v) => filled($v));
        $new = static::dir($kind, rescue(fn () => $ref($row), null, false), $at).'/'.basename($old);

        return $new === $old ? null : $new;
    }

    /**
     * Change one path to another in a column: plain text, or a JSON list of paths.
     * Only the rows that hold the old path; returns how many rows changed.
     */
    public static function rewrite(string $table, string $column, string $old, string $new): int
    {
        if (! Schema::hasColumn($table, $column)) {
            return 0;
        }
        $n = DB::table($table)->where($column, $old)->update([$column => $new]);
        $base = basename($old);
        $q = DB::table($table)->where($column, 'like', '%'.str_replace(['%', '_'], ['\%', '\_'], $base).'%')->where($column, 'like', '[%');
        foreach ($q->get(array_filter([Schema::hasColumn($table, 'id') ? 'id' : null, $column])) as $r) {
            $list = json_decode((string) $r->{$column}, true);
            if (! is_array($list)) {
                continue;
            }
            $changed = false;
            $list = array_map(function ($p) use ($old, $new, &$changed) {
                if (is_string($p) && ltrim(Str::after($p, '/storage/') === $p ? $p : Str::after($p, '/storage/'), '/') === $old) {
                    $changed = true;

                    return $new;
                }

                return $p;
            }, $list);
            if ($changed && isset($r->id)) {
                DB::table($table)->where('id', $r->id)->update([$column => json_encode(array_values($list))]);
                $n++;
            }
        }

        return $n;
    }

    /**
     * Every photo path in the known columns of this system: 'disk|path' => [table, column, new path].
     * Used by Move (photos of wmsv2 on this server) to put them in the new folders.
     */
    public static function refs(): array
    {
        $out = [];
        foreach (static::known() as $tc => $k) {
            [$table, $column] = explode('.', $tc);
            if (! Schema::hasTable($table) || ! Schema::hasColumn($table, $column)) {
                continue;
            }
            $q = DB::table($table)->whereNotNull($column);
            Schema::hasColumn($table, 'id') ? $q->orderBy('id') : $q->orderBy($column);
            foreach ($q->cursor() as $row) {
                foreach (OldSystem::paths($row->{$column}) as $p) {
                    $k = ($table === 'box_photos' ? 'box|' : 'public|').$p;
                    if (! isset($out[$k]) && ($new = static::newPath($table, $column, $row, $p))) {
                        $out[$k] = [$table, $column, $new];
                    }
                }
            }
        }

        return $out;
    }
}
