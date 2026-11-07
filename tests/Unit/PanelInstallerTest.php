<?php

use Symfony\Component\Process\Process;

/**
 * @param  array<string, string>  $environment
 */
function runPanelBash(string $script, array $environment = []): Process
{
    $process = new Process(['bash', '-c', $script], dirname(__DIR__, 2), $environment);
    $process->run();

    return $process;
}

function panelInstallerFunction(string $call): Process
{
    return runPanelBash('source ./install.sh; '.$call);
}

it('has valid bash syntax', function () {
    expect(runPanelBash('bash -n ./install.sh')->getExitCode())->toBe(0);
});

it('stops with a clear message while the repository is not set', function () {
    $process = runPanelBash('bash ./install.sh </dev/null', ['PANEL_REPO' => '__GITHUB_REPO__']);

    expect($process->getExitCode())->toBe(1)
        ->and($process->getErrorOutput())->toContain('PANEL_REPO is not set');
});

it('accepts only real domain names', function (string $domain, bool $isValid) {
    expect(panelInstallerFunction('is_valid_domain '.escapeshellarg($domain))->getExitCode() === 0)->toBe($isValid);
})->with([
    'subdomain' => ['panel.example.com', true],
    'apex' => ['example.co.in', true],
    'no dot' => ['localhost', false],
    'ip address' => ['192.168.1.1', false],
    'shell characters' => ['a.com;reboot', false],
    'command substitution' => ['$(reboot).example.com', false],
    'leading dash' => ['-a.example.com', false],
]);

it('accepts only passwords that the root user seeder accepts', function (string $password, bool $isValid) {
    expect(panelInstallerFunction('is_strong_password '.escapeshellarg($password))->getExitCode() === 0)->toBe($isValid);
})->with([
    'all character types' => ['Abcdef1!', true],
    'too short' => ['Abcde1!', false],
    'no symbol' => ['Abcdefg1', false],
    'no number' => ['Abcdefg!', false],
    'no uppercase' => ['abcdef1!', false],
    'no lowercase' => ['ABCDEF1!', false],
]);

it('generates a strong password', function () {
    $process = panelInstallerFunction('password=$(generate_password); is_strong_password "$password" && printf "%s" "${#password}"');

    expect($process->getExitCode())->toBe(0)
        ->and($process->getOutput())->toBe('28');
});

it('finds only the ports that the panel needs among the listening ports', function (string $listening, string $expected) {
    $stub = 'ss() { printf "%b" '.escapeshellarg($listening).'; }; ';

    expect(trim(panelInstallerFunction($stub.'busy_ports')->getOutput()))->toBe($expected);
})->with([
    'a Wings node' => ['LISTEN 0 4096 *:8080 *:*\nLISTEN 0 128 0.0.0.0:2022 0.0.0.0:*\nLISTEN 0 128 0.0.0.0:25565 0.0.0.0:*\n', ''],
    'a web server' => ['LISTEN 0 511 0.0.0.0:80 0.0.0.0:*\nLISTEN 0 511 [::]:443 [::]:*\n', '80 443'],
    'a game server on a panel port' => ['LISTEN 0 128 0.0.0.0:8000 0.0.0.0:*\n', '8000'],
    'a port that only starts with a panel port' => ['LISTEN 0 128 0.0.0.0:8000080 0.0.0.0:*\nLISTEN 0 128 0.0.0.0:4430 0.0.0.0:*\n', ''],
]);

it('stops before the install when a game server uses a port the panel cannot move', function () {
    $process = panelInstallerFunction('ss() { :; }; busy_ports() { printf "6001 "; }; check_ports');

    expect($process->getExitCode())->toBe(1)
        ->and($process->getErrorOutput())->toContain('Move any game server off these ports');
});

it('adds certbot hooks only for certificates that renew on port 80', function (string $authenticator, bool $usesPort80) {
    $directory = str_replace('\\', '/', sys_get_temp_dir().'/panel-certbot-'.bin2hex(random_bytes(4)));
    mkdir("{$directory}/renewal", recursive: true);
    file_put_contents("{$directory}/renewal/node.example.com.conf", "[renewalparams]\nauthenticator = {$authenticator}\n");

    $process = panelInstallerFunction('export LETSENCRYPT_DIR='.escapeshellarg($directory).'; source ./install.sh; if uses_certbot_standalone; then install_certbot_hooks; fi');
    $preHook = is_file("{$directory}/renewal-hooks/pre/panel-proxy.sh") ? file_get_contents("{$directory}/renewal-hooks/pre/panel-proxy.sh") : null;
    $postHook = is_file("{$directory}/renewal-hooks/post/panel-proxy.sh") ? file_get_contents("{$directory}/renewal-hooks/post/panel-proxy.sh") : null;

    runPanelBash('rm -rf '.escapeshellarg($directory));

    expect($process->getExitCode())->toBe(0);
    if ($usesPort80) {
        expect($preHook)->toContain('docker stop coolify-proxy')
            ->and($postHook)->toContain('docker start coolify-proxy');
    } else {
        expect($preHook)->toBeNull()
            ->and($postHook)->toBeNull();
    }
})->with([
    'standalone' => ['standalone', true],
    'dns' => ['dns-cloudflare', false],
]);

it('uses the repository of a fork for the files of the base installer', function (array $environment, string $expected) {
    preg_match('/^CDN=.*?^DATE=/ms', file_get_contents(dirname(__DIR__, 2).'/scripts/install.sh'), $sourceSelection);
    $script = preg_replace('/^DATE=$/m', '', $sourceSelection[0]).'echo "$CDN $CONFIG_CDN $VERSIONS_SOURCE"';

    expect(trim(runPanelBash($script, $environment)->getOutput()))->toBe($expected);
})->with([
    'without a fork' => [[], 'https://cdn.coollabs.io/coolify https://cdn.coollabs.io/coolify https://cdn.coollabs.io/coolify/versions.json'],
    'with a fork' => [
        ['PANEL_SOURCE_URL' => 'https://raw.example.com/me/panel/main'],
        'https://raw.example.com/me/panel/main/scripts https://raw.example.com/me/panel/main https://raw.example.com/me/panel/main/versions.json',
    ],
]);

it('keeps upgrading from the repository of a fork', function (string $envFile, string $expected) {
    $directory = sys_get_temp_dir().'/panel-installer-'.bin2hex(random_bytes(4));
    mkdir($directory);
    $path = str_replace('\\', '/', "{$directory}/.env");
    file_put_contents($path, $envFile);

    preg_match('/^CONFIG_CDN=.*?^fi$/ms', file_get_contents(dirname(__DIR__, 2).'/scripts/upgrade.sh'), $sourceSelection);
    $script = 'CDN=https://cdn.example.com/coolify; ENV_FILE='.escapeshellarg($path)."\n".$sourceSelection[0]."\necho \"\$CDN \$CONFIG_CDN\"";
    $output = trim(runPanelBash($script)->getOutput());

    unlink($path);
    rmdir($directory);

    expect($output)->toBe($expected);
})->with([
    'without a fork' => ["APP_ID=1\n", 'https://cdn.example.com/coolify https://cdn.example.com/coolify'],
    'with a fork' => ["PANEL_SOURCE_URL=https://raw.example.com/me/panel/main\n", 'https://raw.example.com/me/panel/main/scripts https://raw.example.com/me/panel/main'],
]);

it('publishes a versions.json that the base installer can read', function () {
    $root = dirname(__DIR__, 2);
    $parse = implode("\n", preg_grep('/^(CHANNEL_VERSIONS|LATEST_(HELPER_)?VERSION)=\$\(echo "\$(VERSIONS_JSON|CHANNEL_VERSIONS)"/', file("{$root}/scripts/install.sh")));
    $process = runPanelBash($parse."\necho \"\$LATEST_VERSION \$LATEST_HELPER_VERSION\"", [
        'CHANNEL' => 'stable',
        'VERSIONS_JSON' => file_get_contents("{$root}/versions.json"),
    ]);

    $release = json_decode(file_get_contents("{$root}/release.json"), true);
    $upstream = json_decode(file_get_contents("{$root}/upstream.json"), true);

    expect(trim($process->getOutput()))->toBe("{$release['stable']['coolify']} {$upstream['helper']['version']}");
});
