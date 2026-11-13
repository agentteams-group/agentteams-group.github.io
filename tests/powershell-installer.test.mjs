import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import { spawnSync } from 'node:child_process';
import { prepareCoreInstaller, sha256 } from '../scripts/update-installer.mjs';
const source = fs.readFileSync(new URL('../public/agentteams-install.ps1', import.meta.url), 'utf8');
const metadata = JSON.parse(fs.readFileSync(new URL('../installer-release.json', import.meta.url)));
const hasPowerShell = spawnSync('pwsh', ['-NoProfile', '-Command', 'exit 0']).status === 0;

test('Windows installer is pinned, independently downloadable and checksum protected', () => {
  assert.equal(sha256(source), metadata.powershell.sha256);
  assert.ok(source.includes(`$script:AGENTTEAMS_KNOWN_STABLE_VERSION = "${metadata.version}"`));
  assert.match(source, /^\$script:AGENTTEAMS_VERSION = if \(\$env:AGENTTEAMS_VERSION\) \{ \$env:AGENTTEAMS_VERSION \} else \{ \$script:AGENTTEAMS_KNOWN_STABLE_VERSION \}$/m);
  assert.doesNotMatch(source, /DownloadString|raw\.githubusercontent\.com/);
});

function resolvedImages(installer, overrides = {}) {
  const env = Object.fromEntries(Object.entries(process.env).filter(([name]) => !name.startsWith('AGENTTEAMS_')));
  const result = spawnSync('pwsh', ['-NoProfile', '-NonInteractive', '-Command', `
    $ErrorActionPreference='Stop'
    $source=[Console]::In.ReadToEnd(); $tokens=$null; $errors=$null
    $ast=[System.Management.Automation.Language.Parser]::ParseInput($source,[ref]$tokens,[ref]$errors)
    if($errors.Count){throw ($errors | Out-String)}
    $start=$source.IndexOf('$script:InstallEnvKeys =')
    $end=$source.IndexOf('# ANSI escape character')
    if($start -lt 0 -or $end -le $start){throw 'Missing configuration block'}
    Invoke-Expression $source.Substring($start,$end-$start)
    $fn=$ast.Find({param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Test-DeepSeekHarnessAvailable'},$true)
    Invoke-Expression $fn.Extent.Text
    $start=$source.IndexOf('    # Set image names')
    $end=$source.IndexOf('    # Resolve embedded controller image', $start)
    if($start -lt 0 -or $end -le $start){throw 'Missing image resolution block'}
    $script:AGENTTEAMS_REGISTRY='example.invalid'
    Invoke-Expression $source.Substring($start,$end-$start)
    $values=@{version=$script:AGENTTEAMS_VERSION}
    foreach($name in @('WORKER_IMAGE','QWENPAW_WORKER_IMAGE','HERMES_WORKER_IMAGE','DEEPSEEK_HARNESS_WORKER_IMAGE','OPENHUMAN_WORKER_IMAGE','CODEX_WORKER_IMAGE','MANAGER_IMAGE','MANAGER_QWENPAW_IMAGE')) {
      $values[$name]=(Get-Variable -Scope Script -Name $name).Value
    }
    $values | ConvertTo-Json -Compress
  `], { input: installer, encoding: 'utf8', env: { ...env, ...overrides } });
  assert.equal(result.status, 0, result.stderr);
  return JSON.parse(result.stdout);
}

test('PowerShell resolves six Harness defaults after promotion or an explicit Core selection', { skip: !hasPowerShell }, () => {
  const promoted = prepareCoreInstaller(source, 'ps1', metadata.version, 'v9.8.7');
  const names = { WORKER_IMAGE: 'openclaw', QWENPAW_WORKER_IMAGE: 'qwenpaw', HERMES_WORKER_IMAGE: 'hermes', DEEPSEEK_HARNESS_WORKER_IMAGE: 'deepseek', OPENHUMAN_WORKER_IMAGE: 'openhuman', CODEX_WORKER_IMAGE: 'codex' };
  for (const [installer, overrides, version] of [[source, {}, metadata.version], [promoted, {}, 'v9.8.7'], [source, { AGENTTEAMS_VERSION: 'v9.8.7' }, 'v9.8.7']]) {
    const images = resolvedImages(installer, overrides);
    assert.equal(images.version, version);
    for (const [name, runtime] of Object.entries(names)) assert.equal(images[name], `example.invalid/agentteams/agentteams-harness-${runtime}:${version}`);
    assert.equal(images.MANAGER_IMAGE, images.WORKER_IMAGE);
    assert.equal(images.MANAGER_QWENPAW_IMAGE, images.QWENPAW_WORKER_IMAGE);
  }
});

test('PowerShell promotion preserves historical defaults and explicit runtime or image overrides', { skip: !hasPowerShell }, () => {
  const promoted = prepareCoreInstaller(source, 'ps1', metadata.version, 'v9.8.7');
  const legacy = resolvedImages(promoted, { AGENTTEAMS_VERSION: 'v1.2.6' });
  assert.equal(legacy.WORKER_IMAGE, 'example.invalid/agentteams/agentteams-worker:v1.2.6');
  assert.equal(legacy.DEEPSEEK_HARNESS_WORKER_IMAGE, 'example.invalid/agentteams/agentteams-deepseek-harness-worker:v0.1.1');
  assert.equal(legacy.CODEX_WORKER_IMAGE, 'example.invalid/agentteams/agentteams-harness-codex:v0.1.0');
  const versions = resolvedImages(promoted, { AGENTTEAMS_DEEPSEEK_HARNESS_WORKER_VERSION: 'v1.2.4', AGENTTEAMS_CODEX_WORKER_VERSION: 'v1.2.5' });
  assert.equal(versions.DEEPSEEK_HARNESS_WORKER_IMAGE, 'example.invalid/agentteams/agentteams-harness-deepseek:v1.2.4');
  assert.equal(versions.CODEX_WORKER_IMAGE, 'example.invalid/agentteams/agentteams-harness-codex:v1.2.5');
  const names = ['WORKER_IMAGE', 'QWENPAW_WORKER_IMAGE', 'HERMES_WORKER_IMAGE', 'DEEPSEEK_HARNESS_WORKER_IMAGE', 'OPENHUMAN_WORKER_IMAGE', 'CODEX_WORKER_IMAGE', 'MANAGER_IMAGE', 'MANAGER_QWENPAW_IMAGE'];
  const overrides = Object.fromEntries(names.map((name) => [`AGENTTEAMS_INSTALL_${name}`, `custom.invalid/${name}:pinned`]));
  const images = resolvedImages(promoted, overrides);
  for (const name of names) assert.equal(images[name], overrides[`AGENTTEAMS_INSTALL_${name}`]);
});

test('PowerShell parses and refuses fallback when a pinned image pull fails', { skip: !hasPowerShell }, () => {
  const result = spawnSync('pwsh', ['-NoProfile', '-NonInteractive', '-Command', `
    $tokens=$null; $errors=$null
    $ast=[System.Management.Automation.Language.Parser]::ParseInput([Console]::In.ReadToEnd(),[ref]$tokens,[ref]$errors)
    if($errors.Count){throw 'Invalid PowerShell syntax'}
    $fn=$ast.Find({param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Resolve-EmbeddedImage'},$true)
    Invoke-Expression $fn.Extent.Text
    $script:AGENTTEAMS_VERSION='${metadata.version}'; $script:AGENTTEAMS_REGISTRY='example.invalid'
    $env:AGENTTEAMS_INSTALL_EMBEDDED_IMAGE=''
    function Write-Log { param($message) }
    function Get-Msg { param($key) return '{0}' }
    function docker { if($args -contains 'example.invalid/agentteams/agentteams-embedded:latest'){throw 'Unexpected latest pull'}; $global:LASTEXITCODE=1 }
    try { Resolve-EmbeddedImage; throw 'Expected failure' } catch {
      if($_.Exception.Message -notlike '*Refusing fallback to latest*'){throw}
    }
    'PASS'
  `], { input: source, encoding: 'utf8' });
  assert.equal(result.status, 0, result.stderr);
  assert.match(result.stdout, /PASS/);
});

test('missing engine prints actionable hints and wait progress before becoming ready', { skip: !hasPowerShell }, () => {
  const result = spawnSync('pwsh', ['-NoProfile', '-NonInteractive', '-Command', `
    $tokens=$null; $errors=$null
    $ast=[System.Management.Automation.Language.Parser]::ParseInput([Console]::In.ReadToEnd(),[ref]$tokens,[ref]$errors)
    $fn=$ast.Find({param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Ensure-ContainerRuntime'},$true)
    Invoke-Expression $fn.Extent.Text
    $script:AGENTTEAMS_NON_INTERACTIVE=$false; $script:AGENTTEAMS_LANGUAGE='zh'; $script:checks=0
    function Test-DockerRunning { $script:checks++; return $script:checks -ge 3 }
    function Get-Command { param($Name,$ErrorAction) return $null }
    function Test-Path { param($Path) return $false }
    function Start-Process { param($FilePath) }
    function Start-Sleep { param($Seconds) }
    function Write-Log { param($Message) Write-Output $Message }
    Ensure-ContainerRuntime
  `], { input: source, encoding: 'utf8' });
  assert.equal(result.status, 0, result.stderr);
  assert.match(result.stdout, /Install Docker Desktop/);
  assert.match(result.stdout, /WSL 2 or a restart/);
  assert.match(result.stdout, /Ctrl\+C to cancel/);
  assert.match(result.stdout, /Still waiting for Docker\/Podman/);
});
