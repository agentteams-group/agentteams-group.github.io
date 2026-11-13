import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import { spawnSync } from 'node:child_process';
import { sha256 } from '../scripts/update-installer.mjs';
const source = fs.readFileSync(new URL('../public/agentteams-install.ps1', import.meta.url), 'utf8');
const metadata = JSON.parse(fs.readFileSync(new URL('../installer-release.json', import.meta.url)));
const hasPowerShell = spawnSync('pwsh', ['-NoProfile', '-Command', 'exit 0']).status === 0;

test('Windows installer is pinned, independently downloadable and checksum protected', () => {
  assert.equal(sha256(source), metadata.powershell.sha256);
  assert.match(source, /else \{ "v1\.2\.7" \}/);
  assert.doesNotMatch(source, /DownloadString|raw\.githubusercontent\.com/);
});

test('PowerShell parses and refuses fallback when a pinned image pull fails', { skip: !hasPowerShell }, () => {
  const result = spawnSync('pwsh', ['-NoProfile', '-NonInteractive', '-Command', `
    $tokens=$null; $errors=$null
    $ast=[System.Management.Automation.Language.Parser]::ParseInput([Console]::In.ReadToEnd(),[ref]$tokens,[ref]$errors)
    if($errors.Count){throw 'Invalid PowerShell syntax'}
    $fn=$ast.Find({param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Resolve-EmbeddedImage'},$true)
    Invoke-Expression $fn.Extent.Text
    $script:AGENTTEAMS_VERSION='v1.2.7'; $script:AGENTTEAMS_REGISTRY='example.invalid'
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
