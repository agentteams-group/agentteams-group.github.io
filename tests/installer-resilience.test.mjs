import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';

const source = fs.readFileSync(new URL('../public/install.sh', import.meta.url), 'utf8');
const powershell = fs.readFileSync(new URL('../public/install.ps1', import.meta.url), 'utf8');
function fn(name) {
  const match = source.match(new RegExp(`^${name}\\(\\) \\{\\n[\\s\\S]*?^\\}`, 'm'));
  assert.ok(match, `Missing function: ${name}`);
  return match[0];
}
function bash(code, env = {}) {
  return spawnSync('bash', ['-c', `set -e\n${code}`], { encoding: 'utf8', env: { PATH: '/usr/bin:/bin', HOME: '/nonexistent', ...env } });
}

for (const [status, exitCode] of [['401', 0], ['000', 28]]) {
  test(`Bash model probe continues without confirmation after HTTP ${status}`, () => {
    const result = bash(`
      log() { :; }; msg() { printf '%s' "$1"; }
      read() { exit 91; }
      curl() { printf '${status}'; return ${exitCode}; }
      AGENTTEAMS_NON_INTERACTIVE=0
      ${fn('test_llm_connectivity')}
      test_llm_connectivity https://unreachable.invalid/v1 invalid model
      echo START_SERVICES
    `);
    assert.equal(result.status, 0, result.stderr);
    assert.match(result.stdout, /START_SERVICES/);
  });
}

test('resource names stay stable across repeat resolution and isolate every Docker resource', () => {
  const result = bash(`
    ${fn('resolve_resource_names')}
    resolve_resource_names
    resolve_resource_names
    printf '%s\\n' "$MANAGER_CONTAINER" "$CONTROLLER_CONTAINER" "$DASHBOARD_CONTAINER" "$WORKER_CONTAINER_PREFIX" "$DOCKER_NETWORK" "$DEFAULT_DATA_VOLUME" "$DASHBOARD_VOLUME" "$AGENTTEAMS_ENV_FILE"
  `, { AGENTTEAMS_RESOURCE_PREFIX: 'smoke-' });
  assert.equal(result.status, 0, result.stderr);
  assert.deepEqual(result.stdout.trim().split('\n'), ['smoke-manager', 'smoke-controller', 'smoke-dashboard', 'smoke-worker-', 'smoke-net', 'smoke-data', 'smoke-dashboard-data', '/nonexistent/smoke-manager.env']);
});

test('reruns recover the saved prefix and reject a conflicting instance before touching Docker', (t) => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'installer-prefix-'));
  t.after(() => fs.rmSync(directory, { recursive: true, force: true }));
  const envFile = path.join(directory, 'manager.env');
  fs.writeFileSync(envFile, 'AGENTTEAMS_RESOURCE_PREFIX=saved-\n');
  const code = `${fn('resolve_resource_names')}\nresolve_resource_names\necho "$CONTROLLER_CONTAINER"`;
  const restored = bash(code, { AGENTTEAMS_ENV_FILE: envFile });
  assert.equal(restored.status, 0, restored.stderr);
  assert.equal(restored.stdout.trim(), 'saved-controller');
  const conflict = bash(code, { AGENTTEAMS_ENV_FILE: envFile, AGENTTEAMS_RESOURCE_PREFIX: 'different-' });
  assert.notEqual(conflict.status, 0);
  assert.match(conflict.stderr, /Resource prefix does not match/);
  assert.equal(conflict.stdout, '');
});

test('Manager health must be true; an unhealthy process cannot pass startup verification', () => {
  const result = bash(`
    log() { :; }; msg() { printf '%s' "$1"; }; die() { exit 70; }; sleep() { :; }
    mock_docker() { echo '{"ok":false}'; }
    DOCKER_CMD=mock_docker
    AGENTTEAMS_MANAGER_RUNTIME=openclaw
    AGENTTEAMS_READY_TIMEOUT=1
    ${fn('wait_manager_ready')}
    wait_manager_ready smoke-manager
    echo SHOULD_NOT_SUCCEED
  `);
  assert.equal(result.status, 70, result.stderr);
  assert.doesNotMatch(result.stdout, /SHOULD_NOT_SUCCEED/);
});

test('Dashboard creates, mounts and initializes the same isolated volume', (t) => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'installer-volume-'));
  t.after(() => fs.rmSync(directory, { recursive: true, force: true }));
  const trace = path.join(directory, 'docker.log');
  const envFile = path.join(directory, 'manager.env');
  fs.writeFileSync(envFile, '');
  const result = bash(`
    ${fn('resolve_resource_names')}
    resolve_resource_names
    log() { :; }; msg() { :; }; curl() { return 0; }
    mock_docker() { printf 'DOCKER:%s\\n' "$*" >> "$TRACE_FILE"; }
    DOCKER_CMD=mock_docker
    AGENTTEAMS_USE_EMBEDDED=1
    AGENTTEAMS_DASHBOARD=1
    AGENTTEAMS_REGISTRY=example.invalid
    ${fn('run_logged')}
    ${fn('_start_dashboard')}
    _start_dashboard
  `, { AGENTTEAMS_RESOURCE_PREFIX: 'smoke-', TRACE_FILE: trace, AGENTTEAMS_ENV_FILE: envFile, AGENTTEAMS_LOG_FILE: path.join(directory, 'install.log'), AGENTTEAMS_AI_GATEWAY_ADMIN_ALLOWED_HOSTS: 'trusted.example' });
  assert.equal(result.status, 0, result.stderr);
  const operations = fs.readFileSync(trace, 'utf8');
  assert.match(operations, /volume create smoke-dashboard-data/);
  assert.match(operations, /smoke-dashboard-data:\/dest/);
  assert.match(operations, /smoke-dashboard-data:\/data\/agentteams-dashboard/);
  assert.match(operations, /--network smoke-net/);
  assert.match(operations, /AGENTTEAMS_AI_GATEWAY_ADMIN_ALLOWED_HOSTS=trusted\.example,smoke-controller/);
  assert.doesNotMatch(operations, /(?:volume create | -v )agentteams-dashboard-data/);
});

test('PowerShell model failures never prompt or abort startup', () => {
  const result = spawnSync('pwsh', ['-NoProfile', '-NonInteractive', '-Command', `
    $ErrorActionPreference='Stop'
    $tokens=$null; $errors=$null
    $ast=[System.Management.Automation.Language.Parser]::ParseInput([Console]::In.ReadToEnd(),[ref]$tokens,[ref]$errors)
    if($errors.Count){throw ($errors | Out-String)}
    $fn=$ast.Find({param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Test-LlmConnectivity'},$true)
    Invoke-Expression $fn.Extent.Text
    function Write-Log { param($Message) }
    function Get-Msg { param($Key) return $Key }
    function Invoke-WebRequest { throw 'Connection timed out' }
    function Read-Host { throw 'Unexpected confirmation' }
    function Exit-Script { throw 'Unexpected exit' }
    $script:AGENTTEAMS_NON_INTERACTIVE=$false
    Test-LlmConnectivity -BaseUrl https://unreachable.invalid/v1 -ApiKey invalid -Model model
    'START_SERVICES'
  `], { input: powershell, encoding: 'utf8' });
  assert.equal(result.status, 0, result.stderr);
  assert.match(result.stdout, /START_SERVICES/);
});

test('PowerShell resolves and reloads the same isolated resource names', (t) => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'installer-ps-prefix-'));
  t.after(() => fs.rmSync(directory, { recursive: true, force: true }));
  const envFile = path.join(directory, 'manager.env');
  fs.writeFileSync(envFile, 'AGENTTEAMS_RESOURCE_PREFIX=saved-\n');
  const result = spawnSync('pwsh', ['-NoProfile', '-NonInteractive', '-Command', `
    $ErrorActionPreference='Stop'
    $tokens=$null; $errors=$null
    $ast=[System.Management.Automation.Language.Parser]::ParseInput([Console]::In.ReadToEnd(),[ref]$tokens,[ref]$errors)
    $fn=$ast.Find({param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Initialize-ResourceNames'},$true)
    if(-not $fn){throw 'Missing resource resolver'}
    Invoke-Expression $fn.Extent.Text
    Initialize-ResourceNames
    Initialize-ResourceNames
    @($script:CONTROLLER_CONTAINER,$script:MANAGER_CONTAINER,$script:DASHBOARD_CONTAINER,$script:DOCKER_NETWORK,$script:DEFAULT_DATA_VOLUME,$script:DASHBOARD_VOLUME) | ConvertTo-Json -Compress
    $env:AGENTTEAMS_RESOURCE_PREFIX='different-'
    try { Initialize-ResourceNames; throw 'Expected prefix conflict' } catch {
      if($_.Exception.Message -notlike 'Resource prefix does not match*'){throw}
    }
    exit 0
  `], { input: powershell, encoding: 'utf8', env: { ...process.env, AGENTTEAMS_RESOURCE_PREFIX: '', AGENTTEAMS_ENV_FILE: envFile } });
  assert.equal(result.status, 0, result.stderr);
  assert.deepEqual(JSON.parse(result.stdout.trim()), ['saved-controller', 'saved-manager', 'saved-dashboard', 'saved-net', 'saved-data', 'saved-dashboard-data']);
});

test('PowerShell Dashboard passes resolved names and volume paths to Docker', (t) => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'installer-ps-dashboard-'));
  t.after(() => fs.rmSync(directory, { recursive: true, force: true }));
  const trace = path.join(directory, 'docker.log');
  const result = spawnSync('pwsh', ['-NoProfile', '-NonInteractive', '-Command', `
    $ErrorActionPreference='Stop'
    $tokens=$null; $errors=$null
    $ast=[System.Management.Automation.Language.Parser]::ParseInput([Console]::In.ReadToEnd(),[ref]$tokens,[ref]$errors)
    foreach($name in @('Initialize-ResourceNames','Start-AgentTeamsDashboard','Invoke-DockerLogged')) {
      $fn=$ast.Find({param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true)
      Invoke-Expression $fn.Extent.Text
    }
    Initialize-ResourceNames
    function docker { Add-Content -LiteralPath $env:TRACE_FILE -Value ($args -join ' '); $global:LASTEXITCODE=0 }
    function Invoke-WebRequest { return @{StatusCode=200} }
    function Write-Log { param($Message) }
    function Get-Msg { param($Key) return $Key }
    $script:AGENTTEAMS_USE_EMBEDDED='1'
    $script:AGENTTEAMS_NON_INTERACTIVE=$true
    $script:AGENTTEAMS_LOG_FILE=$env:TRACE_FILE+'.details'
    $script:config=@{ADMIN_USER='admin';MINIO_USER='test';MINIO_PASSWORD='test'}
    Start-AgentTeamsDashboard
  `], { input: powershell, encoding: 'utf8', env: { ...process.env, TRACE_FILE: trace, AGENTTEAMS_RESOURCE_PREFIX: 'smoke-', AGENTTEAMS_ENV_FILE: path.join(directory, 'manager.env'), AGENTTEAMS_AUTH_TOKEN: 'test' } });
  assert.equal(result.status, 0, result.stderr);
  const operations = fs.readFileSync(trace, 'utf8');
  assert.match(operations, /--name smoke-dashboard/);
  assert.match(operations, /--network smoke-net/);
  assert.match(operations, /smoke-dashboard-data:\/data\/agentteams-dashboard/);
  assert.match(operations, /AGENTTEAMS_CONTROLLER_URL=http:\/\/smoke-controller:8090/);
  assert.doesNotMatch(operations, /\$script:/);
});
