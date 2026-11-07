<?php

namespace App\Console\Commands;

use App\Models\Server;
use Illuminate\Console\Command;
use Illuminate\Support\Facades\Validator;

class PanelSetDomain extends Command
{
    protected $signature = 'panel:set-domain {url : The URL of the panel, for example https://panel.example.com}';

    protected $description = 'Set the panel URL and update the proxy route, which also requests the SSL certificate of an https URL';

    public function handle(): int
    {
        $url = rtrim(trim((string) $this->argument('url')), '/');

        if (! $this->isInstanceUrl($url)) {
            $this->error('Invalid URL. Use a URL with only a scheme and a host, for example https://panel.example.com');

            return self::FAILURE;
        }

        $server = Server::find(0);
        if (! $server) {
            $this->error('The localhost server does not exist yet. Try again when the panel has finished starting.');

            return self::FAILURE;
        }

        $settings = instanceSettings();
        $settings->fqdn = $url;
        $settings->save();

        $server->setupDynamicProxyConfiguration();

        $this->info("The panel URL is now {$url}");

        return self::SUCCESS;
    }

    private function isInstanceUrl(string $url): bool
    {
        if (Validator::make(['url' => $url], ['url' => 'required|url:http,https|max:255'])->fails()) {
            return false;
        }

        return array_diff(array_keys(parse_url($url)), ['scheme', 'host', 'port']) === [];
    }
}
