<?php

use App\Models\PrivateKey;
use App\Models\Server;
use App\Models\User;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Illuminate\Support\Facades\Process;
use Symfony\Component\Yaml\Yaml;

uses(RefreshDatabase::class);

function traefikPortsOfNewServer(): array
{
    // generateDefaultProxyConfiguration() saves the configuration on the server over SSH.
    Process::fake();

    $team = User::factory()->create()->teams()->first();
    $server = Server::factory()->create([
        'team_id' => $team->id,
        'private_key_id' => PrivateKey::factory()->create(['team_id' => $team->id])->id,
    ]);
    $server->proxy->set('type', 'TRAEFIK');
    $server->save();

    return Yaml::parse(generateDefaultProxyConfiguration($server->fresh()))['services']['traefik']['ports'];
}

it('leaves port 8080 free for Wings in production', function () {
    expect(traefikPortsOfNewServer())->toBe(['80:80', '443:443', '443:443/udp']);
});

it('publishes the dashboard port only in development', function () {
    config(['app.env' => 'local']);

    expect(traefikPortsOfNewServer())->toContain('8080:8080');
});
