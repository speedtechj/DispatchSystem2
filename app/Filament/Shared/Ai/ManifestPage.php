<?php

namespace App\Filament\Shared\Ai;

use App\Models\Container;
use App\Support\Ai\AiScope;
use App\Support\Ai\AiUnavailable;
use App\Support\Ai\ManifestReader;
use BackedEnum;
use Filament\Notifications\Notification;
use Filament\Support\Icons\Heroicon;
use Illuminate\Support\Facades\Auth;
use Livewire\Attributes\Url;
use Livewire\WithFileUploads;

/** Read a manifest: upload the consolidator's file, check what the AI read, save it into the container. */
abstract class ManifestPage extends AiPage
{
    use WithFileUploads;

    protected string $view = 'filament.ai.manifest';

    protected static string $feature = 'manifest';

    protected static string|BackedEnum|null $navigationIcon = Heroicon::OutlinedDocumentMagnifyingGlass;

    protected static ?string $navigationLabel = 'Read a manifest';

    protected static ?string $title = 'Read a manifest';

    protected static ?string $slug = 'ai-manifest';

    protected static ?int $navigationSort = 3;

    #[Url]
    public ?int $container = null;

    public $file = null;

    public array $rows = [];

    public ?string $consolidator = null;

    public ?string $fileName = null;

    public string $tab = 'all';

    public ?string $error = null;

    public ?int $saved = null;

    public static function canAccess(): bool
    {
        return parent::canAccess() && AiScope::hubId(Auth::user()) === null;
    }

    protected function containers()
    {
        $user = Auth::user();

        return Container::where('is_unloaded', false)->where(fn ($q) => $q->where('is_active', true)->orWhereNull('is_active'))
            ->when(! $user->hasRole('super_admin') && $user->warehouse_id, fn ($q) => $q->where('warehouse_id', $user->warehouse_id))
            ->with('consolidator')->latest('id')->limit(100)->get();
    }

    public function read(): void
    {
        $this->error = null;
        $this->saved = null;
        $this->validate([
            'container' => 'required|integer',
            'file' => 'required|file|max:20480|mimes:pdf,xlsx,csv,txt,jpg,jpeg,png,webp',
        ], ['file.mimes' => 'Use a PDF, Excel (.xlsx), CSV or a photo.', 'container.required' => 'Pick the container first.']);

        $container = $this->containers()->firstWhere('id', $this->container);
        if (! $container) {
            $this->error = 'That container is already unloaded or not yours.';

            return;
        }
        try {
            $out = (new ManifestReader)->read($this->file->getRealPath(), $this->file->getClientOriginalName(), $container);
            $this->rows = $out['rows'];
            $this->consolidator = $out['consolidator'];
            $this->fileName = $this->file->getClientOriginalName();
            $this->tab = 'all';
            if (! $this->rows) {
                $this->error = 'No boxes were found in this file.';
            }
        } catch (AiUnavailable $e) {
            $this->error = $e->getMessage();
        }
    }

    public function toggle(int $i): void
    {
        if (isset($this->rows[$i]) && empty($this->rows[$i]['blocking'])) {
            $this->rows[$i]['save'] = ! $this->rows[$i]['save'];
        }
    }

    public function startOver(): void
    {
        $this->reset(['rows', 'file', 'consolidator', 'fileName', 'error', 'saved']);
    }

    public function save(): void
    {
        $container = $this->containers()->firstWhere('id', $this->container);
        if (! $container || ! $this->rows) {
            return;
        }
        $this->saved = (new ManifestReader)->save($this->rows, $container, Auth::id());
        $this->rows = [];
        Notification::make()->title("{$this->saved} boxes added to container {$container->container_no}")->success()->send();
    }

    protected function getViewData(): array
    {
        $rows = collect($this->rows);
        $shown = $rows->filter(fn ($r) => match ($this->tab) {
            'fixed' => $r['fixed'] !== '',
            'check' => $r['notes'] !== '',
            default => true,
        });

        return [
            'paused' => $this->pausedReason(),
            'containers' => $this->containers(),
            'shown' => $shown,
            'counts' => [
                'all' => $rows->count(), 'fixed' => $rows->where('fixed', '!=', '')->count(),
                'check' => $rows->where('notes', '!=', '')->count(), 'save' => $rows->where('save', true)->count(),
            ],
        ];
    }
}
