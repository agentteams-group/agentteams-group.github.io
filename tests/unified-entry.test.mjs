import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import { spawnSync } from 'node:child_process';

const sh = fs.readFileSync(new URL('../public/install.sh', import.meta.url), 'utf8');
const ps = fs.readFileSync(new URL('../public/install.ps1', import.meta.url), 'utf8');
const dashboardVersion = JSON.parse(fs.readFileSync(new URL('../dashboard-installer-release.json', import.meta.url), 'utf8')).version;
function fn(name) {
  const match = sh.match(new RegExp(`^${name}\\(\\) \\{\\n[\\s\\S]*?^\\}`, 'm'));
  assert.ok(match, name);
  return match[0];
}

test('Bash unified entry defaults apply only to supported fresh installs and preserve saved choices', () => {
  for (const [version, upgrade, saved, expected] of [
    ['v1.2.7','0','','0'], ['v1.2.8','0','','1'], ['v1.2.8','1','','0'],
    ['v1.2.8','0','0','0'], ['v1.2.8','1','1','1'],
  ]) {
    const result = spawnSync('bash', ['-c', `set -e; error(){ exit 70; }; ${fn('_normalize_version')}; ${fn('_ver_lt')}; ${fn('configure_unified_entry_version')}; ${fn('prepare_unified_entry')}; configure_unified_entry_version; prepare_unified_entry; printf '%s|%s|%s' "$AGENTTEAMS_UNIFIED_ENTRY" "$AGENTTEAMS_DASHBOARD_IMAGE" "$AGENTTEAMS_DASHBOARD_URL"`], {
      encoding:'utf8', env:{PATH:'/usr/bin:/bin', AGENTTEAMS_VERSION:version, AGENTTEAMS_UPGRADE:upgrade,
        AGENTTEAMS_UNIFIED_ENTRY:saved, AGENTTEAMS_REGISTRY:'test', AGENTTEAMS_DASHBOARD:'1',
        AGENTTEAMS_DASHBOARD_VERSION:'v1.4.2', DASHBOARD_CONTAINER:'isolated-dashboard'},
    });
    assert.equal(result.status,0,result.stderr);
    assert.equal(result.stdout, `${expected}|test/agentteams/agentteams-dashboard:v1.4.2${expected === '1' ? '-unified' : ''}|${expected === '1' ? 'http://isolated-dashboard:3000' : ''}`);
  }
});

test('Bash upgrades prior default unified images while retaining the entry choice', () => {
  for (const prior of ['v1.4.1', 'v1.4.2']) {
    const result = spawnSync('bash', ['-c', `set -e
      ${fn('prepare_upgrade_dashboard')}
      ${fn('prepare_unified_entry')}
      AGENTTEAMS_REGISTRY=test; AGENTTEAMS_DASHBOARD=1; AGENTTEAMS_UNIFIED_ENTRY=1
      AGENTTEAMS_DASHBOARD_VERSION=${prior}
      AGENTTEAMS_DASHBOARD_IMAGE=test/agentteams/agentteams-dashboard:${prior}-unified
      prepare_upgrade_dashboard; prepare_unified_entry
      printf '%s' "$AGENTTEAMS_DASHBOARD_IMAGE"
    `], {encoding:'utf8'});
    assert.equal(result.status,0,result.stderr);
    assert.equal(result.stdout, `test/agentteams/agentteams-dashboard:${dashboardVersion}-unified`);
  }
});

test('Bash rejects unsupported unified entry and preserves custom Dashboard images', () => {
  const result = spawnSync('bash', ['-c', `set -e
    error(){ :; }
    ${fn('_normalize_version')}
    ${fn('_ver_lt')}
    ${fn('configure_unified_entry_version')}
    ${fn('prepare_unified_entry')}
    ${fn('check_unified_entry_images')}
    AGENTTEAMS_VERSION=v1.2.7; AGENTTEAMS_UNIFIED_ENTRY=1
    if configure_unified_entry_version; then exit 80; fi
    AGENTTEAMS_VERSION=v1.2.8; configure_unified_entry_version
    AGENTTEAMS_DASHBOARD_IMAGE=custom:test; AGENTTEAMS_DASHBOARD=1
    prepare_unified_entry
    [ "$AGENTTEAMS_DASHBOARD_IMAGE" = custom:test ]
    AGENTTEAMS_USE_EMBEDDED=1; DOCKER_CMD=mock
    mock(){ printf '%s' "$LABEL"; }
    LABEL=
    if check_unified_entry_images; then exit 81; fi
    LABEL=1; AGENTTEAMS_DASHBOARD=0
    check_unified_entry_images
  `],{encoding:'utf8'});
  assert.equal(result.status,0,result.stderr);
});

test('PowerShell upgrades prior default unified images while retaining the entry choice', () => {
  const result = spawnSync('pwsh',['-NoProfile','-NonInteractive','-Command',`
    $ErrorActionPreference='Stop'; $tokens=$null; $errors=$null
    $ast=[System.Management.Automation.Language.Parser]::ParseInput([Console]::In.ReadToEnd(),[ref]$tokens,[ref]$errors)
    foreach($name in @('Prepare-UpgradeDashboard','Initialize-UnifiedEntry')) {
      $fn=$ast.Find({param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true)
      Invoke-Expression $fn.Extent.Text
    }
    $script:AGENTTEAMS_REGISTRY='test'; $script:InstallEnvKeys=@{}; $script:AGENTTEAMS_VERSION='v1.2.8'
    $script:AGENTTEAMS_UPGRADE=$true; $env:AGENTTEAMS_UNIFIED_ENTRY='1'
    foreach($prior in @('v1.4.1','v1.4.2')) {
      $script:config=@{DASHBOARD='1'; DASHBOARD_VERSION=$prior; DASHBOARD_IMAGE="test/agentteams/agentteams-dashboard:$prior-unified"}
      Prepare-UpgradeDashboard; Initialize-UnifiedEntry
      if($script:config.DASHBOARD_IMAGE -ne 'test/agentteams/agentteams-dashboard:${dashboardVersion}-unified'){throw 'Prior unified default was left behind'}
    }
  `],{encoding:'utf8',input:ps,env:Object.fromEntries(Object.entries(process.env).filter(([k])=>!k.startsWith('AGENTTEAMS_')))});
  assert.equal(result.status,0,result.stderr);
});

test('PowerShell unified entry preserves upgrades and validates image capabilities before replacement', () => {
  const result = spawnSync('pwsh',['-NoProfile','-NonInteractive','-Command',`
    $ErrorActionPreference='Stop'; $tokens=$null; $errors=$null
    $ast=[System.Management.Automation.Language.Parser]::ParseInput([Console]::In.ReadToEnd(),[ref]$tokens,[ref]$errors)
    foreach($name in @('Initialize-UnifiedEntry','Assert-UnifiedEntryImages')) {
      $fn=$ast.Find({param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true)
      if(-not $fn){throw "Missing $name"}; Invoke-Expression $fn.Extent.Text
    }
    $script:AGENTTEAMS_REGISTRY='test'; $script:DASHBOARD_CONTAINER='isolated-dashboard'
    $script:AGENTTEAMS_USE_EMBEDDED='1'; $script:EMBEDDED_IMAGE='core:test'
    foreach($case in @(@('v1.2.7',$false,'','0'),@('v1.2.8',$false,'','1'),@('v1.2.8',$true,'','0'),@('v1.2.8',$true,'1','1'),@('v1.2.8',$false,'0','0'))) {
      $script:AGENTTEAMS_VERSION=$case[0]; $script:AGENTTEAMS_UPGRADE=$case[1]
      $env:AGENTTEAMS_UNIFIED_ENTRY=$case[2]; $script:config=@{DASHBOARD='1';DASHBOARD_VERSION='v1.4.2'}
      Initialize-UnifiedEntry
      if($script:config.UNIFIED_ENTRY -ne $case[3]){throw 'Wrong upgrade/default decision'}
    }
    $env:AGENTTEAMS_UNIFIED_ENTRY='1'; $script:config.DASHBOARD_IMAGE='custom:test'; Initialize-UnifiedEntry
    if($script:config.DASHBOARD_IMAGE -ne 'custom:test'){throw 'Custom image was replaced'}
    $script:capability='1'
    function docker { $global:LASTEXITCODE=0; if($args -contains 'core:test'){return $script:capability}; return '/dashboard' }
    Assert-UnifiedEntryImages
    $script:capability=''; $failed=$false
    try { Assert-UnifiedEntryImages } catch { $failed=$true }
    if(-not $failed){throw 'Unsupported image passed preflight'}
    $script:AGENTTEAMS_VERSION='v1.2.7'; $failed=$false
    try { Initialize-UnifiedEntry } catch { $failed=$true }
    if(-not $failed){throw 'Unsupported Core version passed preflight'}
  `],{encoding:'utf8',input:ps,env:Object.fromEntries(Object.entries(process.env).filter(([k])=>!k.startsWith('AGENTTEAMS_')))});
  assert.equal(result.status,0,result.stderr);
});

test('Bash missing-env recovery preserves the actual Controller entry configuration', () => {
  for (const [enabled, expected, override] of [['true','1',''], ['false','0',''], ['','0',''], ['true','0','0']]) {
    const result = spawnSync('bash', ['-c', `set -e
      ${fn('recover_existing_install')}
      ${fn('load_upgrade_config')}
      ${fn('_normalize_version')}
      ${fn('_ver_lt')}
      ${fn('configure_unified_entry_version')}
      log(){ :; }; msg(){ :; }; die(){ exit 71; }; error(){ exit 72; }
      detect_installed_data_volume(){ echo retained-data; }
      detect_installed_workspace(){ echo /retained-workspace; }
      docker(){
        case "$1" in
          ps) echo isolated-controller ;;
          inspect) printf '%s\\n' AGENTTEAMS_ADMIN_USER=operator AGENTTEAMS_ADMIN_PASSWORD=saved AGENTTEAMS_MANAGER_PASSWORD=saved AGENTTEAMS_REGISTRATION_TOKEN=saved AGENTTEAMS_MINIO_USER=operator AGENTTEAMS_MINIO_PASSWORD=saved AGENTTEAMS_MANAGER_GATEWAY_KEY=saved AGENTTEAMS_MATRIX_APPSERVICE_ENABLED=false
            [ -z "$ENABLED" ] || printf 'AGENTTEAMS_UNIFIED_ENTRY_ENABLED=%s\\n' "$ENABLED" ;;
          *) exit 73 ;;
        esac
      }
      DOCKER_CMD=docker; CONTROLLER_CONTAINER=isolated-controller
      recover_existing_install
      load_upgrade_config /nonexistent/agentteams-entry-recovery.env
      AGENTTEAMS_VERSION=v1.2.9; AGENTTEAMS_UPGRADE=1
      configure_unified_entry_version
      printf '%s' "$AGENTTEAMS_UNIFIED_ENTRY"
    `], {encoding:'utf8',env:{PATH:'/usr/bin:/bin',ENABLED:enabled,AGENTTEAMS_UNIFIED_ENTRY:override,_INSTALL_ENV_KEYS:override ? ' AGENTTEAMS_UNIFIED_ENTRY ' : ' '}});
    assert.equal(result.status,0,result.stderr);
    assert.equal(result.stdout,expected,`runtime enabled=${enabled}, override=${override}`);
  }
});

test('PowerShell missing-env recovery preserves Controller entry configuration and caller overrides', () => {
  const result = spawnSync('pwsh',['-NoProfile','-NonInteractive','-Command',`
    $ErrorActionPreference='Stop'; $tokens=$null; $errors=$null
    $ast=[System.Management.Automation.Language.Parser]::ParseInput([Console]::In.ReadToEnd(),[ref]$tokens,[ref]$errors)
    foreach($name in @('Recover-ExistingInstall','Load-UpgradeConfig','Initialize-UnifiedEntry')) {
      $fn=$ast.Find({param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true)
      Invoke-Expression $fn.Extent.Text
    }
    function Write-Log {}; function Get-Msg { 'recovered' }
    function Get-InstalledStorage { @{Data='retained-data';Workspace='/retained-workspace'} }
    function docker {
      $global:LASTEXITCODE=0
      if($args[0] -eq 'ps'){return 'isolated-controller'}
      if($args[0] -ne 'inspect'){throw 'Unexpected mutation'}
      $saved=@('AGENTTEAMS_ADMIN_USER=operator','AGENTTEAMS_ADMIN_PASSWORD=saved','AGENTTEAMS_MANAGER_PASSWORD=saved','AGENTTEAMS_REGISTRATION_TOKEN=saved','AGENTTEAMS_MINIO_USER=operator','AGENTTEAMS_MINIO_PASSWORD=saved','AGENTTEAMS_MANAGER_GATEWAY_KEY=saved','AGENTTEAMS_MATRIX_APPSERVICE_ENABLED=false')
      if($script:enabled){$saved+= "AGENTTEAMS_UNIFIED_ENTRY_ENABLED=$script:enabled"}
      ConvertTo-Json -InputObject $saved -Compress
    }
    $script:CONTROLLER_CONTAINER='isolated-controller'; $script:AGENTTEAMS_ENV_FILE='/nonexistent/agentteams-entry-recovery.env'
    $script:AGENTTEAMS_VERSION='v1.2.9'; $script:AGENTTEAMS_UPGRADE=$true; $script:AGENTTEAMS_REGISTRY='test'
    foreach($case in @(@('true','1',''),@('false','0',''),@('','0',''),@('true','0','0'))) {
      $script:enabled=$case[0]; $env:AGENTTEAMS_UNIFIED_ENTRY=$case[2]
      $script:InstallEnvKeys=@{}; if($case[2]){$script:InstallEnvKeys['AGENTTEAMS_UNIFIED_ENTRY']=$true}
      $script:config=@{DASHBOARD_VERSION='v1.4.3'}
      Recover-ExistingInstall; Load-UpgradeConfig; Initialize-UnifiedEntry
      if($script:config.UNIFIED_ENTRY -ne $case[1]){throw "Wrong recovered entry: $($case[0]) -> $($script:config.UNIFIED_ENTRY)"}
    }
  `],{encoding:'utf8',input:ps,env:Object.fromEntries(Object.entries(process.env).filter(([k])=>!k.startsWith('AGENTTEAMS_')))});
  assert.equal(result.status,0,result.stderr);
});
