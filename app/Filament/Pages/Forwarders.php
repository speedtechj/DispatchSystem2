<?php

namespace App\Filament\Pages;

use App\Models\Shipping\Forwarder;
use App\Models\Shipping\ForwarderBranch;
use App\Support\Shipping\Shipments;
use BackedEnum;
use Filament\Actions\Action;
use Filament\Forms\Components\Repeater;
use Filament\Forms\Components\Select;
use Filament\Forms\Components\TextInput;
use Filament\Forms\Components\Toggle;
use Filament\Notifications\Notification;
use Filament\Pages\Page;
use Filament\Schemas\Components\Grid;
use Filament\Support\Icons\Heroicon;
use Illuminate\Support\Facades\Auth;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Schema;

/** Settings → Forwarders (board 64): companies that carry LCL boxes, and their branches. */
class Forwarders extends Page
{
    protected string $view = 'filament.shipping.forwarders';

    protected static string|BackedEnum|null $navigationIcon = Heroicon::OutlinedTruck;

    protected static ?string $title = 'Forwarders';

    protected static ?string $slug = 'forwarders';

    public static function canAccess(): bool
    {
        return Schema::hasTable('forwarders') && (bool) Auth::user()?->is_admin;
    }

    public static function schemaFor(): array
    {
        return [
            Grid::make(3)->schema([
                TextInput::make('name')->label('Name')->required()->maxLength(80)->columnSpan(1),
                Select::make('charge_basis')->label('Charges by')->options(Shipments::CHARGES),
                TextInput::make('charge_rate')->label('Usual rate ₱')->numeric()->minValue(0),
            ]),
            Toggle::make('is_active')->label('Active')->helperText('Off: not offered for new shipments; kept for old ones')->default(true),
            Repeater::make('branches')->label('Branches')->addActionLabel('＋ Add branch')->defaultItems(1)->reorderable(false)->collapsible()
                ->itemLabel(fn (array $state) => $state['name'] ?? null)
                ->schema([
                    Grid::make(2)->schema([
                        TextInput::make('name')->label('Branch')->required()->maxLength(80)->placeholder('Cebu · Pier 3'),
                        TextInput::make('hours')->label('Hours')->maxLength(60)->placeholder('8 AM–5 PM'),
                    ]),
                    TextInput::make('address')->label('Address')->maxLength(200)->placeholder('Pier 3, Cebu City'),
                    Grid::make(3)->schema([
                        TextInput::make('phone')->label('Contact no.')->maxLength(40),
                        TextInput::make('lat')->label('Map pin · lat')->numeric(),
                        TextInput::make('lng')->label('lng')->numeric(),
                    ]),
                ]),
        ];
    }

    /** Save a forwarder with its branches (a branch used by a shipment is kept when removed here: it is only hidden). */
    public static function store(array $data, ?Forwarder $f = null): Forwarder
    {
        return DB::transaction(function () use ($data, $f) {
            $f ??= new Forwarder(['user_id' => Auth::id()]);
            $f->fill(['name' => trim($data['name']), 'charge_basis' => $data['charge_basis'] ?? null, 'charge_rate' => filled($data['charge_rate'] ?? null) ? $data['charge_rate'] : null,
                'is_active' => (bool) ($data['is_active'] ?? true)])->save();
            $keep = [];
            foreach ($data['branches'] ?? [] as $b) {
                $row = ! empty($b['id']) ? ForwarderBranch::where('forwarder_id', $f->id)->find($b['id']) : null;
                $row ??= new ForwarderBranch(['forwarder_id' => $f->id]);
                $row->fill(collect($b)->only(['name', 'address', 'hours', 'phone', 'lat', 'lng'])->map(fn ($v) => $v === '' ? null : $v)->all())->save();
                $keep[] = $row->id;
            }
            $used = Schema::hasColumn('sea_shipments', 'hand_over_branch_id')
                ? DB::table('sea_shipments')->whereNotNull('hand_over_branch_id')->pluck('hand_over_branch_id')->merge(DB::table('sea_shipments')->whereNotNull('pick_up_branch_id')->pluck('pick_up_branch_id'))->all() : [];
            ForwarderBranch::where('forwarder_id', $f->id)->whereNotIn('id', $keep)->whereNotIn('id', $used)->delete();

            return $f;
        });
    }

    public function newAction(): Action
    {
        return Action::make('new')->label('New forwarder')->icon('heroicon-m-plus')
            ->slideOver()->modalWidth('2xl')->modalHeading('New forwarder')->modalSubmitActionLabel('Save forwarder')
            ->schema(static::schemaFor())
            ->action(function (array $data) {
                $f = static::store($data);
                Notification::make()->title($f->name.' added')->success()->send();
            });
    }

    public function editAction(): Action
    {
        return Action::make('edit')->slideOver()->modalWidth('2xl')->modalSubmitActionLabel('Save changes')
            ->modalHeading(fn (array $arguments) => Forwarder::find($arguments['id'] ?? 0)?->name ?? 'Forwarder')
            ->fillForm(function (array $arguments) {
                $f = Forwarder::with('branches')->find($arguments['id'] ?? 0);

                return $f ? ['name' => $f->name, 'charge_basis' => $f->charge_basis, 'charge_rate' => $f->charge_rate, 'is_active' => $f->is_active,
                    'branches' => $f->branches->map(fn ($b) => $b->only(['id', 'name', 'address', 'hours', 'phone', 'lat', 'lng']))->all()] : [];
            })
            ->schema(array_merge(static::schemaFor(), [\Filament\Forms\Components\Hidden::make('id')]))
            ->action(function (array $data, array $arguments) {
                if ($f = Forwarder::find($arguments['id'] ?? 0)) {
                    static::store($data, $f);
                    Notification::make()->title('Saved')->success()->send();
                }
            });
    }

    protected function getViewData(): array
    {
        $used = Schema::hasColumn('sea_shipments', 'forwarder_id')
            ? DB::table('sea_shipments')->whereNotNull('forwarder_id')->selectRaw('forwarder_id, count(*) n')->groupBy('forwarder_id')->pluck('n', 'forwarder_id') : collect();

        return [
            'forwarders' => Forwarder::with('branches')->orderByDesc('is_active')->orderBy('name')->get(),
            'used' => $used,
            'charges' => Shipments::CHARGES,
        ];
    }
}
