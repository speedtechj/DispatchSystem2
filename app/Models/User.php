<?php

namespace App\Models;

// use Illuminate\Contracts\Auth\MustVerifyEmail;
use Database\Factories\UserFactory;
use Filament\Models\Contracts\FilamentUser;
use Filament\Models\Contracts\HasAvatar;
use Filament\Models\Contracts\HasName;
use Filament\Panel;
use Illuminate\Database\Eloquent\Factories\HasFactory;
use Illuminate\Foundation\Auth\User as Authenticatable;
use Illuminate\Notifications\Notifiable;
use Illuminate\Support\Facades\Storage;
use Spatie\Permission\Traits\HasRoles;

class User extends Authenticatable implements FilamentUser, HasAvatar, HasName
{
    /** @use HasFactory<UserFactory> */
    use HasFactory, Notifiable;

    use HasRoles;
    /**
     * The attributes that are mass assignable.
     *
     * @var list<string>
     */
    // protected $fillable = [
    //     'name',
    //     'email',
    //     'password',
    // ];

    /**
     * The attributes that should be hidden for serialization.
     *
     * @var list<string>
     */
    protected $hidden = [
        'password',
        'remember_token',
    ];

    protected $appends = ['full_name'];

    /**
     * Get the attributes that should be cast.
     *
     * @return array<string, string>
     */
    protected function casts(): array
    {
        return [
            'email_verified_at' => 'datetime',
            'password' => 'hashed',
            'is_admin' => 'boolean',
            'is_active' => 'boolean',
            //    'profile_picture' => 'array'
        ];
    }

    /**
     * Each panel belongs to one panel category (adm, co, whse, drv).
     * Deactivated users cannot sign in to any panel.
     */
    public function canAccessPanel(Panel $panel): bool
    {
        if (! $this->is_active) {
            return false;
        }

        $code = $this->panelcategory?->code;

        return match ($panel->getId()) {
            'admin' => $this->is_admin && $code === 'adm',
            'company' => $code === 'co',
            'warehouse' => $code === 'whse',
            'delivery' => ! $this->is_admin && $code === 'drv',
            // Scan app: loading and unloading crews of warehouses, partner hubs and the office.
            'scan' => in_array($code, ['adm', 'whse', 'co'], true),
            default => false,
        };
    }

    public function getFilamentName(): string
    {
        return trim("{$this->first_name} {$this->last_name}");
    }

    public function getFullNameAttribute(): string
    {
        return trim("{$this->first_name} {$this->last_name}");
    }

    public function getFilamentAvatarUrl(): ?string
    {
        if (blank($this->profile_picture)) {
            return null;
        }

        if (str_starts_with($this->profile_picture, 'http')) {
            return $this->profile_picture;
        }

        return Storage::disk('public')->url($this->profile_picture);
    }

    public function panelcategory()
    {
        return $this->belongsTo(Panelcategory::class);
    }

    public function company()
    {
        return $this->belongsTo(Company::class);
    }

    public function workposition()
    {
        return $this->belongsTo(Workposition::class);
    }

    public function logistichub()
    {
        return $this->belongsTo(Logistichub::class);
    }

    public function warehouse()
    {
        return $this->belongsTo(Warehouse::class);
    }
}
