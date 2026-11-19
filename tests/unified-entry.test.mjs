import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync, spawn } from 'node:child_process';
import { createServer } from 'node:http';

const source = fs.readFileSync(new URL('../public/install.sh', import.meta.url), 'utf8');
const psSource = fs.readFileSync(new URL('../public/install.ps1', import.meta.url), 'utf8');
function fn(name) {
  const match = source.match(new RegExp(`^${name}\\(\\) \\{\\n[\\s\\S]*?^\\}`, 'm'));
  assert.ok(match, name);
  return match[0];
}
const functions = ['_ver_lt', 'configure_unified_entry_version', 'prepare_unified_entry', 'unified_entry_url', 'dashboard_browser_url', 'check_unified_entry_images', 'verify_unified_entry'].map(fn).join('\n');
function shell(code, env = {}) {
  return spawnSync('bash', ['-c', `set -e\n${functions}\nerror() { echo "$*" >&2; }\n${code}`], {
    encoding: 'utf8', env: { PATH: process.env.PATH, ...env },
  });
}

for (const [version, explicit, expected] of [
  ['v1.2.7', '', '0'], ['v1.2.8', '', '1'], ['v1.2.9', '', '1'],
  ['v1.3.0', '', '1'], ['v1.2.8', '0', '0'],
]) {
  test(`${version} selects entry mode ${expected} with override '${explicit}'`, () => {
    const result = shell(`AGENTTEAMS_VERSION=${version}; AGENTTEAMS_UNIFIED_ENTRY='${explicit}'; configure_unified_entry_version; printf '%s' "$AGENTTEAMS_UNIFIED_ENTRY"`);
    assert.equal(result.status, 0, result.stderr);
    assert.equal(result.stdout, expected);
  });
}

test('enabling the new entry on a pre-1.2.8 release fails before service changes', () => {
  const result = shell('AGENTTEAMS_VERSION=v1.2.7; AGENTTEAMS_UNIFIED_ENTRY=1; configure_unified_entry_version; echo SHOULD_NOT_START');
  assert.notEqual(result.status, 0);
  assert.doesNotMatch(result.stdout, /SHOULD_NOT_START/);
});

test('an old-version install does not persist an automatic opt-out that blocks the next upgrade', (t) => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'unified-version-upgrade-'));
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
  const writeEnv = source.match(/    cat > "\$\{ENV_FILE\}" << EOF\n[\s\S]*?\nEOF/)[0];
  const result = shell(`
    ${fn('load_current_params_from_env')}
    ENV_FILE="$TEST_ENV"; AGENTTEAMS_ENV_FILE="$TEST_ENV"
    AGENTTEAMS_VERSION=v1.2.7
    configure_unified_entry_version
    ${writeEnv}
    unset AGENTTEAMS_UNIFIED_ENTRY
    load_current_params_from_env
    AGENTTEAMS_VERSION=v1.2.8
    configure_unified_entry_version
    printf '%s' "$AGENTTEAMS_UNIFIED_ENTRY"
  `, { TEST_ENV: path.join(dir, 'install.env') });
  assert.equal(result.status, 0, result.stderr);
  assert.equal(result.stdout, '1');
});

for (const upgrade of [false, true]) {
  test(`Bash ${upgrade ? 'upgrade' : 'fresh install'} selects a paired image, keeps storage and persists entry settings`, (t) => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'unified-install-'));
    t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
    const envFile = path.join(dir, 'install.env');
    const workspace = path.join(dir, 'workspace');
    fs.mkdirSync(workspace);
    fs.writeFileSync(path.join(workspace, 'sentinel'), 'original workspace');
    if (upgrade) fs.writeFileSync(envFile, `AGENTTEAMS_DATA_DIR=original-data\nAGENTTEAMS_WORKSPACE_DIR=${workspace}\nAGENTTEAMS_DASHBOARD=1\nAGENTTEAMS_DASHBOARD_VERSION=v9.0.0\nAGENTTEAMS_DASHBOARD_IMAGE=registry/agentteams/agentteams-dashboard:v9.0.0\n`);
    const writeEnv = source.match(/    cat > "\$\{ENV_FILE\}" << EOF\n[\s\S]*?\nEOF/)[0];
    const result = shell(`
      ${fn('load_current_params_from_env')}
      AGENTTEAMS_ENV_FILE="$TEST_ENV"
      AGENTTEAMS_UNIFIED_ENTRY=1
      AGENTTEAMS_ENTRY_EXTERNAL_URL=https://at.example.com/
      load_current_params_from_env
      AGENTTEAMS_DATA_DIR="\${AGENTTEAMS_DATA_DIR:-original-data}"
      AGENTTEAMS_WORKSPACE_DIR="$TEST_WORKSPACE"
      AGENTTEAMS_REGISTRY=registry
      AGENTTEAMS_VERSION=v1.2.8
      AGENTTEAMS_DASHBOARD=1
      AGENTTEAMS_DASHBOARD_VERSION=v9.0.0
      DASHBOARD_CONTAINER=isolated-dashboard
      ENV_FILE="$TEST_ENV"
      prepare_unified_entry
      ${writeEnv}
      printf '%s\\n' "$AGENTTEAMS_DASHBOARD_IMAGE" "$AGENTTEAMS_DASHBOARD_URL" "$AGENTTEAMS_DATA_DIR" "$AGENTTEAMS_WORKSPACE_DIR"
      dashboard_browser_url
    `, { TEST_ENV: envFile, TEST_WORKSPACE: workspace });
    assert.equal(result.status, 0, result.stderr);
    assert.match(result.stdout, /v9\.0\.0-unified\nhttp:\/\/isolated-dashboard:3000\noriginal-data\n/);
    assert.ok(result.stdout.endsWith('https://at.example.com/dashboard/'));
    const saved = fs.readFileSync(envFile, 'utf8');
    assert.match(saved, /AGENTTEAMS_UNIFIED_ENTRY=1\n/);
    assert.match(saved, /AGENTTEAMS_DATA_DIR=original-data\n/);
    assert.ok(saved.includes(`AGENTTEAMS_WORKSPACE_DIR=${workspace}\n`));
    assert.equal(fs.readFileSync(path.join(workspace, 'sentinel'), 'utf8'), 'original workspace');
  });
}

test('Bash rejects unpaired release images before configuration or service changes', () => {
  const result = shell(`
    AGENTTEAMS_UNIFIED_ENTRY=1; AGENTTEAMS_USE_EMBEDDED=1; AGENTTEAMS_DASHBOARD=1
    EMBEDDED_IMAGE=old-controller; AGENTTEAMS_DASHBOARD_IMAGE=old-dashboard
    DOCKER_CMD=docker_mock
    docker_mock() { printf '<no value>'; }
    check_unified_entry_images
    echo SHOULD_NOT_TOUCH_SERVICES
  `);
  assert.notEqual(result.status, 0);
  assert.doesNotMatch(result.stdout, /SHOULD_NOT/);
  assert.match(result.stderr, /Existing services have not been stopped/);
  const installer = fn('install_manager');
  assert.ok(installer.indexOf('check_unified_entry_images') < installer.indexOf('cat > "${ENV_FILE}"'));
  assert.ok(installer.indexOf('check_unified_entry_images') < installer.indexOf('# --- Stop and remove existing containers ---'));
});

for (const gatewayReady of [false, true]) {
  test(`Bash verifies gateway API, page, static JS and Dashboard API (${gatewayReady ? 'ready' : 'missing route'})`, async (t) => {
    const requests = [];
    const server = createServer((req, res) => {
      requests.push(req.url);
      if (!gatewayReady) { res.writeHead(404); res.end(); return; }
      if (req.url === '/api/v1/version') {
        assert.equal(req.headers.authorization, 'Bearer test-token');
        res.end('{"controller":"v9.0.0"}');
      } else if (req.url === '/dashboard/') res.end('<html><script src="/dashboard/_next/static/test.js"></script></html>');
      else if (req.url === '/dashboard/_next/static/test.js') res.end('window.ready=true');
      else if (req.url === '/dashboard/api/agentteams/healthz/') res.end('{}');
      else { res.writeHead(404); res.end(); }
    });
    await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
    t.after(() => server.close());
    const result = await new Promise((resolve, reject) => {
      const child = spawn('bash', ['-c', `set -e\n${functions}
        error() { echo "$*" >&2; }
        sleep() { :; }
        docker_mock() { echo test-token; }
        DOCKER_CMD=docker_mock
        AGENTTEAMS_UNIFIED_ENTRY=1; AGENTTEAMS_DASHBOARD=1
        CONTROLLER_CONTAINER=isolated-controller
        AGENTTEAMS_ENTRY_EXTERNAL_URL=http://127.0.0.1:${server.address().port}
        verify_unified_entry
        echo VERIFIED
      `]);
      let stdout = '', stderr = '';
      child.stdout.on('data', d => { stdout += d; });
      child.stderr.on('data', d => { stderr += d; });
      child.on('error', reject);
      child.on('close', status => resolve({ status, stdout, stderr }));
    });
    assert.equal(result.status === 0, gatewayReady, result.stderr);
    assert.equal(result.stdout.includes('VERIFIED'), gatewayReady);
    assert.ok(requests.every(url => url.startsWith('/api/') || url.startsWith('/dashboard/')));
    if (gatewayReady) assert.deepEqual(requests, ['/api/v1/version', '/dashboard/', '/dashboard/_next/static/test.js', '/dashboard/api/agentteams/healthz/']);
  });
}

test('PowerShell preserves upgrade storage, selects the paired image and saves the entry configuration', () => {
  const result = spawnSync('pwsh', ['-NoProfile', '-NonInteractive', '-Command', `
    $ErrorActionPreference='Stop'; $tokens=$null; $errors=$null
    $ast=[System.Management.Automation.Language.Parser]::ParseInput([Console]::In.ReadToEnd(),[ref]$tokens,[ref]$errors)
    if($errors.Count){throw ($errors | Out-String)}
    foreach($name in @('Prepare-UnifiedEntry','Get-UnifiedEntryUrl','Get-DashboardBrowserUrl','Assert-UnifiedEntryImages')) {
      $fn=$ast.Find({param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true)
      Invoke-Expression $fn.Extent.Text
    }
    $script:AGENTTEAMS_REGISTRY='registry'; $script:DASHBOARD_CONTAINER='isolated-dashboard'; $script:AGENTTEAMS_VERSION='v1.2.8'
    $script:config=@{DASHBOARD='1';DASHBOARD_VERSION='v9.0.0';UNIFIED_ENTRY='1';ENTRY_EXTERNAL_URL='https://at.example.com/';DATA_DIR='old-data';WORKSPACE_DIR='old-workspace'}
    Prepare-UnifiedEntry
    if($script:config.DATA_DIR -ne 'old-data' -or $script:config.WORKSPACE_DIR -ne 'old-workspace'){throw 'Storage changed'}
    if($script:config.DASHBOARD_URL -ne 'http://isolated-dashboard:3000'){throw 'Upstream missing'}
    if($script:config.DASHBOARD_IMAGE -ne 'registry/agentteams/agentteams-dashboard:v9.0.0-unified'){throw 'Wrong image'}
    if((Get-DashboardBrowserUrl) -ne 'https://at.example.com/dashboard/'){throw 'Wrong URL'}
    $script:AGENTTEAMS_USE_EMBEDDED='1'
    function docker { $global:LASTEXITCODE=0; return '<no value>' }
    $rejected=$false
    try { Assert-UnifiedEntryImages } catch { $rejected=$true }
    if(-not $rejected){throw 'Old image accepted'}
  `], { input: psSource, encoding: 'utf8' });
  assert.equal(result.status, 0, result.stderr);
});
