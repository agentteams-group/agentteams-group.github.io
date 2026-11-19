import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';

const bashSource = fs.readFileSync(new URL('../public/install.sh', import.meta.url), 'utf8');
const psSource = fs.readFileSync(new URL('../public/install.ps1', import.meta.url), 'utf8');
const hasPowerShell = spawnSync('pwsh', ['-NoProfile', '-Command', 'exit 0']).status === 0;

function bash(code, env = {}) {
  return spawnSync('bash', ['-e', '-c', code], { encoding: 'utf8', env: { PATH: '/usr/bin:/bin', ...env } });
}

const bashDetection = bashSource.slice(bashSource.indexOf('        _is_old_arch=0\n'),
  bashSource.indexOf('\n        if [ "${_is_old_arch}" = "1" ]; then'));
const bashHelper = bashSource.match(/^agentteams_existing_controller_is_embedded\(\) \{\n[\s\S]*?^\}/m)?.[0] || '';
assert.ok(bashDetection.includes('_is_old_arch=0'));

for (const [entrypoint, expected] of [['["supervisord","-c","/etc/supervisor/conf.d/supervisord.conf"]', '0'], ['["docker-proxy"]', '1']]) {
  test(`Bash classifies controller capabilities with a digest display: ${entrypoint}`, () => {
    const result = bash(`
      mock_docker() {
        case "$1" in
          inspect) printf '%s' "$ENTRYPOINT_JSON" ;;
          ps) case "$*" in *'{{.Image}}'*) echo 'smoke-controller 2a7570c1ebb3' ;; *) echo smoke-controller ;; esac ;;
          *) exit 90 ;;
        esac
      }
      DOCKER_CMD=mock_docker
      CONTROLLER_CONTAINER=smoke-controller
      ${bashHelper}
      ${bashDetection}
      printf '%s' "$_is_old_arch"
    `, { ENTRYPOINT_JSON: entrypoint });
    assert.equal(result.status, 0, result.stderr);
    assert.equal(result.stdout, expected);
  });

  test(`PowerShell classifies controller capabilities with a digest display: ${entrypoint}`, { skip: !hasPowerShell }, () => {
    const result = spawnSync('pwsh', ['-NoProfile', '-NonInteractive', '-Command', `
      $ErrorActionPreference='Stop'
      $source=[Console]::In.ReadToEnd(); $tokens=$null; $errors=$null
      $ast=[System.Management.Automation.Language.Parser]::ParseInput($source,[ref]$tokens,[ref]$errors)
      if($errors.Count){throw ($errors | Out-String)}
      $helper=$ast.Find({param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Test-ExistingEmbeddedController'},$true)
      if($helper){Invoke-Expression $helper.Extent.Text}
      function docker {
        if($args[0] -eq 'inspect'){return $env:ENTRYPOINT_JSON}
        if($args[0] -eq 'ps'){
          if(($args -join ' ') -like '*{{.Image}}*'){return 'smoke-controller 2a7570c1ebb3'}
          return 'smoke-controller'
        }
        throw 'Unexpected Docker operation'
      }
      $script:CONTROLLER_CONTAINER='smoke-controller'
      $start=$source.IndexOf('        $controllerNameHit =')
      $end=$source.IndexOf('        if ($isOldArch)', $start)
      if($start -lt 0 -or $end -lt 0){throw 'Missing upgrade classifier'}
      Invoke-Expression $source.Substring($start,$end-$start)
      if($isOldArch){'1'}else{'0'}
    `], { input: psSource, encoding: 'utf8', env: { ...process.env, ENTRYPOINT_JSON: entrypoint } });
    assert.equal(result.status, 0, result.stderr);
    assert.equal(result.stdout.trim(), expected);
  });
}

function credentialFixture(t) {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'upgrade-credentials-'));
  t.after(() => fs.rmSync(directory, { recursive: true, force: true }));
  const data = path.join(directory, 'data');
  const backup = path.join(directory, 'backup');
  fs.mkdirSync(data); fs.mkdirSync(backup);
  fs.writeFileSync(path.join(data, 'existing-worker.env'), 'WORKER_PASSWORD="keep-existing"\n');
  fs.writeFileSync(path.join(backup, 'default.env'), 'WORKER_PASSWORD="migrated-manager"\n');
  return { data, backup };
}

function assertCredentialMerge(f, result) {
  assert.equal(result.status, 0, result.stderr);
  assert.ok(fs.existsSync(path.join(f.data, 'existing-worker.env')), 'Migration deleted an existing Worker credential');
  assert.equal(fs.readFileSync(path.join(f.data, 'existing-worker.env'), 'utf8'), 'WORKER_PASSWORD="keep-existing"\n');
  assert.equal(fs.readFileSync(path.join(f.data, 'default.env'), 'utf8'), 'WORKER_PASSWORD="migrated-manager"\n');
}

test('Bash partial legacy migration preserves credentials outside the extracted registry', (t) => {
  const f = credentialFixture(t);
  const block = bashSource.slice(bashSource.indexOf('# --- Upgrade: inject extracted credentials'));
  const shell = block.match(/-c '\n([\s\S]*?)\n\s*' 2>\/dev\/null/);
  assert.ok(shell, 'Missing credential injection script');
  const code = shell[1].replaceAll('/data/worker-creds', '"$DATA_DIR"').replaceAll('/creds/', '"$BACKUP_DIR"/');
  assertCredentialMerge(f, bash(code, { DATA_DIR: f.data, BACKUP_DIR: f.backup }));
});

test('PowerShell partial legacy migration preserves credentials outside the extracted registry', (t) => {
  const f = credentialFixture(t);
  const shell = psSource.match(/\$injectShell = "([^\n]+)"/);
  assert.ok(shell, 'Missing PowerShell credential injection script');
  const code = shell[1].replaceAll('/data/worker-creds', '"$DATA_DIR"').replaceAll('/creds/', '"$BACKUP_DIR"/');
  assertCredentialMerge(f, bash(code, { DATA_DIR: f.data, BACKUP_DIR: f.backup }));
});
