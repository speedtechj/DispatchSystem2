<?php

namespace App\Support\Ai;

use App\Models\Container;
use App\Models\Invoice;
use App\Models\Routearea;
use Illuminate\Support\Str;
use OpenSpout\Reader\CSV\Reader as CsvReader;
use OpenSpout\Reader\XLSX\Reader as XlsxReader;

/**
 * Reads a consolidator's manifest (PDF, Excel .xlsx, CSV or a photo) into rows of boxes.
 * The AI also cleans up addresses and picks the route area. Nothing is saved here.
 */
class ManifestReader
{
    public const COLUMNS = ['invoice', 'sender_name', 'receiver_name', 'receiver_address', 'receiver_barangay', 'receiver_city', 'receiver_province', 'receiver_mobile_no', 'receiver_home_no', 'boxtype', 'route_code'];

    public const ROWS_PER_CALL = 120;

    /**
     * @return array{rows: list<array<string, mixed>>, consolidator: ?string}
     */
    public function read(string $file, string $name, Container $container): array
    {
        @set_time_limit(0);
        config(['ai.timeout' => 600]);
        $ext = Str::lower(pathinfo($name, PATHINFO_EXTENSION));

        if (in_array($ext, ['xlsx', 'csv', 'txt'], true)) {
            $lines = $this->sheetLines($file, $ext);
            if (count($lines) < 2) {
                throw new AiUnavailable('The file looks empty.');
            }
            $header = array_shift($lines);
            $rows = [];
            $consolidator = null;
            foreach (array_chunk($lines, self::ROWS_PER_CALL) as $chunk) {
                $out = $this->ask([['type' => 'text', 'text' => "Manifest rows (first line is the header):\n".$header."\n".implode("\n", $chunk)]], 8000);
                $rows = array_merge($rows, $out['rows']);
                $consolidator ??= $out['consolidator'];
            }
        } elseif ($ext === 'pdf') {
            $block = ['type' => 'document', 'source' => ['type' => 'base64', 'media_type' => 'application/pdf', 'data' => base64_encode((string) file_get_contents($file))]];
            ['rows' => $rows, 'consolidator' => $consolidator] = $this->ask([$block, ['type' => 'text', 'text' => 'Read every box in this manifest.']], 32000);
        } elseif (in_array($ext, ['jpg', 'jpeg', 'png', 'webp'], true)) {
            $type = ['jpg' => 'image/jpeg', 'jpeg' => 'image/jpeg', 'png' => 'image/png', 'webp' => 'image/webp'][$ext];
            $block = ['type' => 'image', 'source' => ['type' => 'base64', 'media_type' => $type, 'data' => base64_encode((string) file_get_contents($file))]];
            ['rows' => $rows, 'consolidator' => $consolidator] = $this->ask([$block, ['type' => 'text', 'text' => 'Read every box in this manifest photo.']], 8000);
        } else {
            throw new AiUnavailable('Use a PDF, Excel (.xlsx), CSV or a photo (JPG/PNG). For old .xls files, open them in Excel and save as .xlsx.');
        }

        return ['rows' => $this->check($rows, $container), 'consolidator' => $consolidator];
    }

    /** @return list<string> one line per spreadsheet row, cells separated by " | " */
    protected function sheetLines(string $file, string $ext): array
    {
        $reader = $ext === 'xlsx' ? new XlsxReader : new CsvReader;
        $reader->open($file);
        $lines = [];
        foreach ($reader->getSheetIterator() as $sheet) {
            foreach ($sheet->getRowIterator() as $row) {
                $cells = array_map(fn ($v) => $v instanceof \DateTimeInterface ? $v->format('Y-m-d') : trim((string) $v), $row->toArray());
                if (implode('', $cells) !== '') {
                    $lines[] = implode(' | ', $cells);
                }
                if (count($lines) > 3000) {
                    break 2;
                }
            }
            break; // first sheet only
        }
        $reader->close();

        return $lines;
    }

    /** @return array{rows: list<array<string, mixed>>, consolidator: ?string} */
    protected function ask(array $content, int $maxTokens): array
    {
        $routes = Routearea::orderBy('code')->get(['code', 'description'])
            ->map(fn ($r) => $r->code.' = '.$r->description)->join('; ');

        $system = 'You read shipping manifests of balikbayan boxes going to the Philippines and turn them into data. '
            .'Return {"consolidator": name or null, "rows": [[invoice, sender_name, receiver_name, receiver_address, receiver_barangay, receiver_city, receiver_province, receiver_mobile_no, receiver_home_no, boxtype, route_code, fixed, problem], ...]}. '
            .'One row per box, in the order of the manifest. Keep the invoice/box number exactly as written. '
            .'Split the address into street part, barangay, city/municipality and province. Correct obvious misspellings and short forms of Philippine places '
            .'(e.g. "Lapu2" = "Lapu-Lapu City", "Mandaue Cty" = "Mandaue City", "brgy" = barangay). Write names and places in normal capitalization. '
            .'Phone: digits only, keep a leading 0 (e.g. 09171234567). '
            .'route_code: pick the best matching code from this list, or "" if none fits: '.($routes ?: '(no list)').'. '
            .'fixed: short note of what you corrected in the address, or "". problem: short note of anything missing or doubtful (no phone, no address, unreadable), or "". '
            .'Use "" for anything not in the manifest. Never invent data.';

        $out = Ai::json('manifest', $system, $content, 'smart', $maxTokens);
        $rows = [];
        foreach ((array) ($out['rows'] ?? []) as $r) {
            if (! is_array($r) || count($r) < 3) {
                continue;
            }
            $r = array_values($r);
            $rows[] = [
                'invoice' => trim((string) ($r[0] ?? '')), 'sender_name' => trim((string) ($r[1] ?? '')),
                'receiver_name' => trim((string) ($r[2] ?? '')), 'receiver_address' => trim((string) ($r[3] ?? '')),
                'receiver_barangay' => trim((string) ($r[4] ?? '')), 'receiver_city' => trim((string) ($r[5] ?? '')),
                'receiver_province' => trim((string) ($r[6] ?? '')), 'receiver_mobile_no' => preg_replace('/[^\d+]/', '', (string) ($r[7] ?? '')),
                'receiver_home_no' => trim((string) ($r[8] ?? '')), 'boxtype' => trim((string) ($r[9] ?? '')),
                'route_code' => trim((string) ($r[10] ?? '')), 'fixed' => trim((string) ($r[11] ?? '')), 'problem' => trim((string) ($r[12] ?? '')),
            ];
        }

        return ['rows' => $rows, 'consolidator' => ($out['consolidator'] ?? null) ?: null];
    }

    /** Mark duplicates and rows that can't be saved; pick which ones are ticked to save. */
    public function check(array $rows, Container $container): array
    {
        // two sender companies can use one number (board 58): only the same box twice is blocked
        $existing = Invoice::whereIn('invoice', array_column($rows, 'invoice'))->get(['invoice', 'container_id', 'receiver_name'])->groupBy('invoice');
        $who = fn ($n) => mb_strtolower(preg_replace('/\s+/', ' ', trim((string) $n)));
        $seen = [];
        foreach ($rows as $i => &$r) {
            $notes = [];
            $blocking = false;
            if ($r['invoice'] === '') {
                $notes[] = 'No box number';
                $blocking = true;
            } elseif (in_array($who($r['receiver_name']), $seen[$r['invoice']] ?? [], true)) {
                $notes[] = 'Listed twice in this file (a copied row)';
                $blocking = true;
            } elseif (($here = ($existing[$r['invoice']] ?? collect())->where('container_id', $container->id))->contains(fn ($x) => $who($x->receiver_name) === $who($r['receiver_name']))) {
                $notes[] = 'Already in this container';
                $blocking = true;
            } elseif (! empty($seen[$r['invoice']]) || $here->isNotEmpty()) {
                $notes[] = '⚠ Same number as another box in this container (other receiver): saved as 2 boxes';
            } elseif (isset($existing[$r['invoice']])) {
                $notes[] = 'Same number as a box in another container (other sender)';
            }
            if ($r['receiver_name'] === '' || $r['receiver_address'].$r['receiver_city'] === '') {
                $notes[] = 'No receiver or address';
                $blocking = true;
            }
            if ($r['receiver_mobile_no'] === '') {
                $notes[] = 'No phone';
            }
            if ($r['problem'] !== '' && ! in_array($r['problem'], $notes, true)) {
                $notes[] = $r['problem'];
            }
            $seen[$r['invoice']][] = $who($r['receiver_name']);
            $r['notes'] = implode(' · ', array_unique($notes));
            $r['blocking'] = $blocking;
            $r['save'] = ! $blocking;
            $r['n'] = $i + 1;
        }

        return array_values($rows);
    }

    /** Save the ticked rows into the container. Returns how many were added. */
    public function save(array $rows, Container $container, int $userId): int
    {
        $routes = Routearea::pluck('id', 'code');
        $consolidatorCode = (string) ($container->consolidator?->code ?? '');
        $added = 0;
        foreach ($rows as $r) {
            if (empty($r['save']) || ! empty($r['blocking'])
                || Invoice::where('container_id', $container->id)->where('invoice', $r['invoice'])->where('receiver_name', $r['receiver_name'])->exists()) {
                continue;
            }
            Invoice::create([
                'container_id' => $container->id,
                'warehouse_id' => $container->warehouse_id,
                'invoice' => $r['invoice'],
                'batchno' => $container->batch_no,
                'sender_name' => $r['sender_name'],
                'receiver_name' => $r['receiver_name'],
                'receiver_address' => $r['receiver_address'],
                'receiver_barangay' => $r['receiver_barangay'],
                'receiver_city' => $r['receiver_city'],
                'receiver_province' => $r['receiver_province'],
                'receiver_mobile_no' => $r['receiver_mobile_no'],
                'receiver_home_no' => $r['receiver_home_no'] ?: null,
                'boxtype' => (string) $r['boxtype'],
                'routearea_id' => $routes[$r['route_code']] ?? null,
                'location_code' => $consolidatorCode, // the consolidator's code, like the Excel upload
                'user_id' => $userId,
            ]);
            $added++;
        }

        return $added;
    }
}
