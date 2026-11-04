import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import { spawnSync } from 'node:child_process';
import { sha256 } from '../scripts/update-installer.mjs';

const metadata = JSON.parse(fs.readFileSync(new URL('../dashboard-installer-release.json', import.meta.url), 'utf8'));
const source = fs.readFileSync(new URL('../public/agentteams-dashboard.sh', import.meta.url), 'utf8');
// Only evaluate constants and selected functions; never run the installer entry point.
const prelude = source.slice(0, source.indexOf('\nENV_FILE=')).replace('website_main() {\n', '');
function shellFunction(name) {
  const match = source.match(new RegExp(`^${name}\\(\\) \\{\\n[\\s\\S]*?^\\}`, 'm'));
  assert.ok(match, `Missing Dashboard function: ${name}`);
  return match[0];
}
function shell(code) {
  return spawnSync('bash', ['-c', `${prelude}
    info() { :; }
    ok() { :; }
    warn() { :; }
    err() { printf '%s\\n' "$*" >&2; }
    ${code}
  `], { encoding: 'utf8', env: { PATH: '/usr/bin:/bin' } });
}

test('Dashboard uses its own promoted release and defaults to loopback binding', () => {
  assert.equal(sha256(source), metadata.sha256);
  const result = shell(`${shellFunction('resolve_port_prefix')}
    printf '%s\\n' "$DEFAULT_DASHBOARD_VERSION" "$DEFAULT_IMAGE"
    resolve_port_prefix
    printf '<%s>\\n' "$_port_prefix"
    AGENTTEAMS_LOCAL_ONLY=0
    resolve_port_prefix
    printf '<%s>\\n' "$_port_prefix"
  `);
  assert.equal(result.status, 0, result.stderr);
  assert.equal(result.stdout, `${metadata.version}\nhigress-registry.cn-hangzhou.cr.aliyuncs.com/agentteams/agentteams-dashboard:${metadata.version}\n<127.0.0.1:>\n<>\n`);
});

test('Dashboard installation stops when the existing AgentTeams network is absent', () => {
  const result = shell(`
    detect_docker() { DOCKER_CMD=mock_docker; }
    mock_docker() { return 1; }
    ${shellFunction('preflight')}
    preflight
    echo SHOULD_NOT_INSTALL
  `);
  assert.equal(result.status, 1);
  assert.match(result.stderr, /agentteams-net.*not found/);
  assert.doesNotMatch(result.stdout, /SHOULD_NOT_INSTALL/);
});

test('Dashboard image pull failure stops without building local source', () => {
  const result = shell(`
    DOCKER_CMD=mock_docker
    mock_docker() { printf 'docker:%s\\n' "$*"; return 1; }
    ${shellFunction('ensure_image')}
    ensure_image "$DEFAULT_IMAGE"
    echo SHOULD_NOT_START
  `);
  assert.equal(result.status, 1);
  assert.match(result.stderr, /Installation stopped; no local source build was attempted/);
  assert.match(result.stdout, new RegExp(`docker:pull .*:${metadata.version}`));
  assert.doesNotMatch(result.stdout, /docker:build|SHOULD_NOT_START/);
});

test('Dashboard reuses an available versioned image without an unnecessary pull', () => {
  const result = shell(`
    DOCKER_CMD=mock_docker
    mock_docker() { [ "$1" = image ] && [ "$2" = inspect ]; }
    ${shellFunction('ensure_image')}
    ensure_image "$DEFAULT_IMAGE"
    echo READY
  `);
  assert.equal(result.status, 0, result.stderr);
  assert.equal(result.stdout, 'READY\n');
});

test('Dashboard update preserves the existing container when pulling fails', () => {
  const result = shell(`
    DOCKER_CMD=mock_docker
    mock_docker() { return 1; }
    preflight() { :; }
    load_env() {
      AGENTTEAMS_PORT_DASHBOARD=$DEFAULT_PORT
      AGENTTEAMS_DASHBOARD_IMAGE=$DEFAULT_IMAGE
      AGENTTEAMS_CONTROLLER_URL=http://agentteams-controller:8090
    }
    recreate_container() { echo SHOULD_NOT_RECREATE; }
    print_success() { echo SHOULD_NOT_SUCCEED; }
    ${shellFunction('do_update')}
    do_update
  `);
  assert.equal(result.status, 1);
  assert.match(result.stderr, /existing container was preserved/);
  assert.doesNotMatch(result.stdout, /SHOULD_NOT/);
});
