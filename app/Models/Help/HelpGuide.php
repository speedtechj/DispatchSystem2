<?php

namespace App\Models\Help;

use App\Support\Help\Help;
use Illuminate\Database\Eloquent\Builder;
use Illuminate\Database\Eloquent\Model;
use Illuminate\Support\Facades\Storage;

/** One help guide: when to use it, the steps (with screenshots), the result and common problems. */
class HelpGuide extends Model
{
    protected $table = 'help_guides';

    protected $guarded = [];

    protected function casts(): array
    {
        return [
            'apps' => 'array', 'steps' => 'array', 'problems' => 'array', 'pages' => 'array',
            'links' => 'array', 'related' => 'array', 'is_published' => 'boolean',
        ];
    }

    protected static function booted(): void
    {
        static::saved(fn () => Help::forget());
        static::deleted(fn () => Help::forget());
    }

    public function scopeFor(Builder $q, string $app): Builder
    {
        return $q->where('is_published', true)->whereJsonContains('apps', $app);
    }

    /** A field in the chosen language, English when the Tagalog is empty. */
    public function t(string $field, string $lang = 'en'): string
    {
        $v = $lang === 'tl' ? ($this->{$field.'_tl'} ?: $this->{$field.'_en'}) : $this->{$field.'_en'};

        return (string) $v;
    }

    /** @return list<array{title: string, text: string, image: ?string}> */
    public function stepsIn(string $lang): array
    {
        return collect($this->steps ?? [])->map(fn ($s) => [
            'title' => (string) (($lang === 'tl' ? ($s['title_tl'] ?? null) : null) ?: ($s['title_en'] ?? '')),
            'text' => (string) (($lang === 'tl' ? ($s['text_tl'] ?? null) : null) ?: ($s['text_en'] ?? '')),
            'image' => static::imageUrl($s['image'] ?? null),
        ])->values()->all();
    }

    /** @return list<array{q: string, a: string}> */
    public function problemsIn(string $lang): array
    {
        return collect($this->problems ?? [])->map(fn ($p) => [
            'q' => (string) (($lang === 'tl' ? ($p['q_tl'] ?? null) : null) ?: ($p['q_en'] ?? '')),
            'a' => (string) (($lang === 'tl' ? ($p['a_tl'] ?? null) : null) ?: ($p['a_en'] ?? '')),
        ])->filter(fn ($p) => $p['q'] !== '')->values()->all();
    }

    /** Built-in screenshots live in public/images/help; uploaded ones on the public disk. */
    public static function imageUrl(mixed $path): ?string
    {
        if (is_array($path)) {
            $path = reset($path) ?: null;
        }
        if (! $path) {
            return null;
        }
        if (str_starts_with($path, 'images/')) {
            return is_file(public_path($path)) ? asset($path) : null;
        }

        return Storage::disk('public')->url($path);
    }
}
