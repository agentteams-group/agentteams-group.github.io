import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import { spawnSync } from 'node:child_process';

const sh = fs.readFileSync(new URL('../public/install.sh', import.meta.url), 'utf8');
const ps = fs.readFileSync(new URL('../public/install.ps1', import.meta.url), 'utf8');
function fn(name) {
  const match = sh.match(new RegExp(`^${name}\\(\\) \\{\\n[\\s\\S]*?^\\}`, 'm'));
  assert.ok(match, name);
  return match[0];
}
function bash(code, env = {}) {
  return spawnSync('bash', ['-c', `set -e; log(){ :; }; msg(){ :; }; die(){ exit 70; }; ${code}`],
    { encoding: 'utf8', env: { PATH: '/usr/bin:/bin', ...env } });
}

test('Bash selects the shared image for every requested Manager runtime', () => {
  for (const [runtime, expected] of [['qwenpaw','qwen'],['openclaw','openclaw'],['hermes','hermes'],['deepseek-harness','dsh'],['codex','codex']]) {
    const result = bash(`${fn('manager_image_for_runtime')}; manager_image_for_runtime ${runtime}`, {
      MANAGER_IMAGE: 'openclaw', MANAGER_QWENPAW_IMAGE: 'qwen', HERMES_WORKER_IMAGE: 'hermes',
      DEEPSEEK_HARNESS_WORKER_IMAGE: 'dsh', CODEX_WORKER_IMAGE: 'codex',
    });
    assert.equal(result.status, 0, result.stderr);
    assert.equal(result.stdout, expected);
  }
});

test('Bash wizard offers Hermes, DeepSeek and Codex while preserving the existing choices', () => {
  for (const [choice, runtime] of [['1','qwenpaw'],['2','openclaw'],['3','hermes'],['4','deepseek-harness'],['5','codex']]) {
    const result = bash(`${fn('step_manager_runtime')}; step_manager_runtime <<< '${choice}'; printf 'SELECTED=%s' "$AGENTTEAMS_MANAGER_RUNTIME"`, {
      AGENTTEAMS_NON_INTERACTIVE: '0', AGENTTEAMS_UPGRADE: '0',
    });
    assert.equal(result.status, 0, result.stderr);
    assert.ok(result.stdout.endsWith(`SELECTED=${runtime}`), result.stdout);
  }
});

test('new Harnesses wait for Controller readiness rather than a live process', () => {
  for (const runtime of ['hermes','deepseek-harness','codex']) {
    for (const ready of ['true','false']) {
      const result = bash(`DOCKER_CMD=mock_docker; mock_docker(){ case "$*" in *'agt get managers default -o json') printf '{"ready":${ready}}';; *) exit 90;; esac; }; sleep(){ :; }; ${fn('wait_manager_ready')}; wait_manager_ready test-manager`, {
        AGENTTEAMS_MANAGER_RUNTIME: runtime, AGENTTEAMS_READY_TIMEOUT: '1', CONTROLLER_CONTAINER: 'test-controller',
      });
      assert.equal(result.status, ready === 'true' ? 0 : 70, result.stderr);
    }
  }
});

const hasPwsh = spawnSync('pwsh', ['-NoProfile','-Command','exit 0']).status === 0;
test('Bash rejects unsupported E2EE and requires updated Codex/Core images', () => {
  for (const [runtime, e2ee, manager, controller, expected] of [
    ['codex','0','','',70], ['codex','0','custom:ci','',70], ['codex','0','custom:ci','core:ci',0],
    ['codex','1','custom:ci','core:ci',70], ['deepseek-harness','true','','',70], ['hermes','0','','',0],
  ]) {
    const result = bash(`${fn('validate_manager_runtime')}; validate_manager_runtime`, {
      AGENTTEAMS_MANAGER_RUNTIME: runtime, AGENTTEAMS_MATRIX_E2EE: e2ee,
      AGENTTEAMS_INSTALL_MANAGER_IMAGE: manager, AGENTTEAMS_INSTALL_EMBEDDED_IMAGE: controller,
      AGENTTEAMS_VERSION: 'v1.2.7',
    });
    assert.equal(result.status, expected, result.stderr);
  }
});

test('PowerShell rejects unsupported E2EE and requires updated Codex/Core images', { skip: !hasPwsh }, () => {
  const result = spawnSync('pwsh', ['-NoProfile','-NonInteractive','-Command', `
    $ErrorActionPreference='Stop'; $source=[Console]::In.ReadToEnd(); $tokens=$null; $errors=$null
    $ast=[System.Management.Automation.Language.Parser]::ParseInput($source,[ref]$tokens,[ref]$errors)
    $fn=$ast.Find({param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Assert-ManagerRuntime'},$true)
    Invoke-Expression $fn.Extent.Text
    function Get-Msg {param($key) $key}
    $script:AGENTTEAMS_VERSION='v1.2.7'
    foreach($case in @(@('codex','0','','',$false),@('codex','0','custom:ci','',$false),
        @('codex','0','custom:ci','core:ci',$true),@('codex','1','custom:ci','core:ci',$false),
        @('deepseek-harness','true','','',$false),@('hermes','0','','',$true))) {
      $script:config=@{MANAGER_RUNTIME=$case[0]; MATRIX_E2EE=$case[1]}
      $env:AGENTTEAMS_INSTALL_MANAGER_IMAGE=$case[2]; $env:AGENTTEAMS_INSTALL_EMBEDDED_IMAGE=$case[3]
      $passed=$true; try { Assert-ManagerRuntime } catch { $passed=$false }
      if($passed -ne $case[4]){throw ('Wrong compatibility decision: '+($case -join ','))}
    }
  `], { encoding: 'utf8', input: ps, env: Object.fromEntries(Object.entries(process.env).filter(([k]) => !k.startsWith('AGENTTEAMS_'))) });
  assert.equal(result.status, 0, result.stderr);
});

test('PowerShell selects shared images and checks the Manager ready flag', { skip: !hasPwsh }, () => {
  const result = spawnSync('pwsh', ['-NoProfile','-NonInteractive','-Command', `
    $ErrorActionPreference='Stop'
    $source=[Console]::In.ReadToEnd(); $tokens=$null; $errors=$null
    $ast=[System.Management.Automation.Language.Parser]::ParseInput($source,[ref]$tokens,[ref]$errors)
    if($errors.Count){throw ($errors | Out-String)}
    $start=$source.IndexOf('    $managerImage = switch ($config.MANAGER_RUNTIME)')
    $end=$source.IndexOf('    $portPrefix =', $start)
    $block=$source.Substring($start,$end-$start)
    $script:MANAGER_IMAGE='openclaw'; $script:MANAGER_QWENPAW_IMAGE='qwen'
    $script:HERMES_WORKER_IMAGE='hermes'; $script:DEEPSEEK_HARNESS_WORKER_IMAGE='deepseek-harness'; $script:CODEX_WORKER_IMAGE='codex'
    foreach($runtime in @('hermes','deepseek-harness','codex')) {
      $config=@{MANAGER_RUNTIME=$runtime}; Invoke-Expression $block
      if($managerImage -ne $runtime){throw "Wrong image for $runtime : $managerImage"}
    }
    $fn=$ast.Find({param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Wait-ManagerReady'},$true)
    Invoke-Expression $fn.Extent.Text
    function Write-Log {} ; function Get-Msg { param($key) $key }; function Start-Sleep {}
    function Exit-Script {throw 'Not ready'}
    function docker { if(($args -join ' ') -notlike '*agt get managers default -o json'){throw 'Wrong readiness probe'}; $global:LASTEXITCODE=0; '{"ready":'+$script:Ready+'}' }
    foreach($runtime in @('hermes','deepseek-harness','codex')) {
      $script:config=@{MANAGER_RUNTIME=$runtime}; $script:CONTROLLER_CONTAINER='test-controller'
      $script:Ready='true'; if(-not (Wait-ManagerReady -Container test-manager -Timeout 1)){throw 'Not ready'}
      $script:Ready='false'; $failed=$false
      try { Wait-ManagerReady -Container test-manager -Timeout 1 } catch { $failed=$true }
      if(-not $failed){throw 'A false ready flag was accepted'}
    }
  `], { encoding: 'utf8', input: ps, env: Object.fromEntries(Object.entries(process.env).filter(([k]) => !k.startsWith('AGENTTEAMS_'))) });
  assert.equal(result.status, 0, result.stderr);
});
