<?php

use App\Models\InstanceSettings;
use App\Models\Server;
use App\Models\Team;
use Illuminate\Foundation\Testing\RefreshDatabase;

uses(RefreshDatabase::class);

beforeEach(function () {
    InstanceSettings::forceCreate(['id' => 0, 'fqdn' => 'https://old.example.com']);
});

function createLocalhostServerWithoutProxy(): void
{
    $server = Server::factory()->create(['id' => 0, 'team_id' => Team::factory()->create()->id]);
    $server->proxy->type = 'NONE';
    $server->save();
}

it('saves the panel url without a trailing slash', function () {
    createLocalhostServerWithoutProxy();

    $this->artisan('panel:set-domain', ['url' => 'https://panel.example.com/'])->assertSuccessful();

    expect(InstanceSettings::find(0)->fqdn)->toBe('https://panel.example.com');
});

it('rejects an invalid url and keeps the current one', function (string $url) {
    createLocalhostServerWithoutProxy();

    $this->artisan('panel:set-domain', ['url' => $url])->assertFailed();

    expect(InstanceSettings::find(0)->fqdn)->toBe('https://old.example.com');
})->with([
    'no scheme' => 'panel.example.com',
    'other scheme' => 'ftp://panel.example.com',
    'path' => 'https://panel.example.com/admin',
    'query' => 'https://panel.example.com?a=1',
    'credentials' => 'https://user:secret@panel.example.com',
    'shell characters' => 'https://panel.example.com;reboot',
]);

it('keeps the current url when the localhost server does not exist', function () {
    $this->artisan('panel:set-domain', ['url' => 'https://panel.example.com'])->assertFailed();

    expect(InstanceSettings::find(0)->fqdn)->toBe('https://old.example.com');
});
