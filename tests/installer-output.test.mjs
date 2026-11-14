import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';

const bashSource = fs.readFileSync(new URL('../public/install.sh', import.meta.url), 'utf8');
const psSource = fs.readFileSync(new URL('../public/install.ps1', import.meta.url), 'utf8');
function fn(name) {
  const found = bashSource.match(new RegExp(`^${name}\\(\\) \\{\\n[\\s\\S]*?^\\}`, 'm'));
  assert.ok(found, `Missing Bash function: ${name}`);
  return found[0];
}
const plain = (text) => text.replace(/\x1b\[[0-?]*[ -/]*[@-~]/g, '');

for (const language of ['zh', 'en']) {
  for (const status of ['unknown', 'unavailable', 'ready']) {
    test(`Bash ${language} summary identifies Dashboard once and describes ${status} model status`, () => {
      const result = spawnSync('bash', ['-c', `set -e
        ${fn('msg')}
        ${fn('log')}
        ${fn('print_install_summary')}
        AGENTTEAMS_LANGUAGE=${language}
        AGENTTEAMS_DASHBOARD_READY=1
        AGENTTEAMS_PORT_DASHBOARD=33000
        AGENTTEAMS_ADMIN_USER=admin
        AGENTTEAMS_ADMIN_PASSWORD=test-password
        AGENTTEAMS_LOCAL_ONLY=1
        MODEL_CONNECTION_STATUS=${status}
        print_install_summary
      `], { encoding: 'utf8' });
      assert.equal(result.status, 0, result.stderr);
      const output = plain(result.stdout);
      assert.match(output, /Dashboard[^\n]*http:\/\/127\.0\.0\.1:33000\//);
      assert.equal(output.match(/http:\/\/127\.0\.0\.1:33000\//g)?.length, 1);
      assert.doesNotMatch(output, /FluffyChat|Element Mobile|homeserver|alice|创建.*Worker|create.*Worker|192\.168\./);
      assert.match(output, language === 'zh' ? /仅本机/ : /localhost only/);
      if (status !== 'ready') assert.match(output, language === 'zh' ? /检查模型配置/ : /check.*model settings/);
    });
  }
}

test('Bash LAN hints appear only when external access is enabled', () => {
  const result = spawnSync('bash', ['-c', `set -e
    ${fn('msg')}
    ${fn('log')}
    ${fn('print_install_summary')}
    detect_lan_ip() { echo 192.0.2.10; }
    AGENTTEAMS_LANGUAGE=zh
    AGENTTEAMS_DASHBOARD_READY=1
    AGENTTEAMS_LOCAL_ONLY=0
    AGENTTEAMS_PORT_DASHBOARD=33000
    AGENTTEAMS_PORT_GATEWAY=38080
    print_install_summary
  `], { encoding: 'utf8' });
  assert.equal(result.status, 0, result.stderr);
  assert.match(plain(result.stdout), /局域网 Dashboard[^\n]*http:\/\/192\.0\.2\.10:33000\//);
  assert.match(plain(result.stdout), /Matrix[^\n]*http:\/\/192\.0\.2\.10:38080/);
});

test('Docker details are logged silently and command failures keep their exit status', (t) => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'installer-output-'));
  t.after(() => fs.rmSync(directory, { recursive: true, force: true }));
  const log = path.join(directory, 'install.log');
  const result = spawnSync('bash', ['-c', `
    ${fn('run_logged')}
    run_logged printf 'container-id\n'
    run_logged bash -c 'echo registry-error >&2; exit 24'
    exit $?
  `], { encoding: 'utf8', env: { ...process.env, AGENTTEAMS_LOG_FILE: log } });
  assert.equal(result.status, 24);
  assert.doesNotMatch(result.stdout, /container-id/);
  assert.match(fs.readFileSync(log, 'utf8'), /container-id/);
  assert.match(result.stderr, /registry-error/);
});

for (const language of ['zh', 'en']) {
  test(`PowerShell ${language} summary prefers Dashboard and hides invalid mobile and model hints`, () => {
    const result = spawnSync('pwsh', ['-NoProfile', '-NonInteractive', '-Command', `
      $ErrorActionPreference='Stop'
      $source=[Console]::In.ReadToEnd(); $tokens=$null; $errors=$null
      $ast=[System.Management.Automation.Language.Parser]::ParseInput($source,[ref]$tokens,[ref]$errors)
      $start=$source.IndexOf('$script:Messages =')
      $end=$source.IndexOf('function Get-Msg', $start)
      if($start -lt 0 -or $end -lt 0){throw 'Missing translations'}
      Invoke-Expression $source.Substring($start,$end-$start)
      foreach($name in @('Get-Msg','Write-Log','Show-InstallSummary')) {
        $fn=$ast.Find({param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true)
        if(-not $fn){throw "Missing function: $name"}
        Invoke-Expression $fn.Extent.Text
      }
      $script:AGENTTEAMS_LANGUAGE='${language}'
      $script:AGENTTEAMS_DASHBOARD_READY=$true
      $script:ModelConnectionStatus='unavailable'
      $script:config=@{PORT_DASHBOARD='33000';ADMIN_USER='admin';ADMIN_PASSWORD='test-password';LOCAL_ONLY='1'}
      Show-InstallSummary
      Get-Msg 'output.manager_detected' -f 0
    `], { input: psSource, encoding: 'utf8' });
    assert.equal(result.status, 0, result.stderr);
    const output = plain(result.stdout);
    assert.match(output, /Dashboard[^\n]*http:\/\/127\.0\.0\.1:33000\//);
    assert.equal(output.match(/http:\/\/127\.0\.0\.1:33000\//g)?.length, 1);
    assert.doesNotMatch(output, /FluffyChat|Element Mobile|homeserver|alice|创建.*Worker|create.*Worker/);
    assert.match(output, language === 'zh' ? /检查模型配置/ : /check.*model settings/);
    assert.match(output, /0s/);
    assert.doesNotMatch(output, /\{0\}/);
  });
}

test('Bash readiness progress ends its line before reporting success', () => {
  const result = spawnSync('bash', ['-c', `
    ${fn('wait_manager_ready')}
    log() { printf '%s\\n' "$1"; }
    msg() { printf '%s' "$1"; }
    sleep() { :; }
    mock_docker() { if [ "$elapsed" -ge 5 ]; then echo '{"agents":[]}'; else return 1; fi; }
    DOCKER_CMD=mock_docker
    AGENTTEAMS_MANAGER_RUNTIME=qwenpaw
    AGENTTEAMS_READY_TIMEOUT=10
    wait_manager_ready smoke-manager
  `], { encoding: 'utf8' });
  assert.equal(result.status, 0, result.stderr);
  assert.match(plain(result.stdout), /install\.wait_ready\.waiting\ninstall\.wait_ready\.ok/);
});

test('PowerShell embedded startup leaves model gateway configuration to the Controller', () => {
  const result = spawnSync('pwsh', ['-NoProfile', '-NonInteractive', '-Command', `
    $ErrorActionPreference='Stop'
    $tokens=$null; $errors=$null
    $ast=[System.Management.Automation.Language.Parser]::ParseInput([Console]::In.ReadToEnd(),[ref]$tokens,[ref]$errors)
    $fn=$ast.Find({param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Install-Manager'},$true)
    $guard=$fn.FindAll({param($n) $n -is [System.Management.Automation.Language.IfStatementAst] -and $n.Extent.Text.Contains('New-OpenAICompatProvider -BaseUrl')},$true) | Sort-Object { $_.Extent.Text.Length } | Select-Object -First 1
    if(-not $guard){throw 'Missing legacy provider guard'}
    $script:AGENTTEAMS_USE_EMBEDDED='1'
    $config=@{LLM_PROVIDER='openai-compat'}
    function New-OpenAICompatProvider { throw 'Installer must not overwrite the embedded gateway' }
    Invoke-Expression $guard.Extent.Text
    'PASS'
  `], { input: psSource, encoding: 'utf8' });
  assert.equal(result.status, 0, result.stderr);
  assert.match(result.stdout, /PASS/);
});

test('Bash upgrade updates the selected Manager image without rewriting model or runtime settings', (t) => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'installer-upgrade-'));
  t.after(() => fs.rmSync(directory, { recursive: true, force: true }));
  const trace = path.join(directory, 'commands.log');
  const result = spawnSync('bash', ['-c', `set -e
    ${fn('update_installed_manager_image')}
    log() { :; }; msg() { printf '%s' "$1"; }; sleep() { :; }; die() { exit 70; }
    attempts=0
    mock_docker() { printf '%s\\n' "$*" >> "$TRACE_FILE"; attempts=$((attempts+1)); [ "$attempts" -gt 1 ]; }
    DOCKER_CMD=mock_docker
    CONTROLLER_CONTAINER=smoke-controller
    update_installed_manager_image example.invalid/harness-openclaw:v1.2.7
    echo UPDATED
  `], { encoding: 'utf8', env: { ...process.env, AGENTTEAMS_LOG_FILE: path.join(directory, 'install.log'), TRACE_FILE: trace } });
  assert.equal(result.status, 0, result.stderr);
  assert.match(result.stdout, /UPDATED/);
  const calls = fs.readFileSync(trace, 'utf8');
  assert.equal(calls.trim().split('\n').length, 2);
  assert.match(calls, /agt update manager --name default --image example\.invalid\/harness-openclaw:v1\.2\.7/);
  assert.doesNotMatch(calls, /--model|--runtime/);
});

test('PowerShell upgrade retries token initialization and updates only the Manager image', (t) => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'installer-ps-upgrade-'));
  t.after(() => fs.rmSync(directory, { recursive: true, force: true }));
  const trace = path.join(directory, 'commands.log');
  const result = spawnSync('pwsh', ['-NoProfile', '-NonInteractive', '-Command', `
    $ErrorActionPreference='Stop'
    $tokens=$null; $errors=$null
    $ast=[System.Management.Automation.Language.Parser]::ParseInput([Console]::In.ReadToEnd(),[ref]$tokens,[ref]$errors)
    $fn=$ast.Find({param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Update-InstalledManagerImage'},$true)
    Invoke-Expression $fn.Extent.Text
    function Write-Log { param($Message) }
    function Get-Msg { param($Key) return $Key }
    function Start-Sleep { param($Seconds) }
    $script:attempts=0
    function docker { Add-Content -LiteralPath $env:TRACE_FILE -Value ($args -join ' '); $script:attempts++; $global:LASTEXITCODE=if($script:attempts -gt 1){0}else{1} }
    $script:AGENTTEAMS_LOG_FILE=$env:TRACE_FILE+'.details'
    $script:CONTROLLER_CONTAINER='smoke-controller'
    Update-InstalledManagerImage -Image example.invalid/harness-openclaw:v1.2.7
    'UPDATED'
  `], { input: psSource, encoding: 'utf8', env: { ...process.env, TRACE_FILE: trace } });
  assert.equal(result.status, 0, result.stderr);
  assert.match(result.stdout, /UPDATED/);
  const calls = fs.readFileSync(trace, 'utf8');
  assert.equal(calls.trim().split('\n').length, 2);
  assert.match(calls, /agt update manager --name default --image example\.invalid\/harness-openclaw:v1\.2\.7/);
  assert.doesNotMatch(calls, /--model|--runtime/);
});
