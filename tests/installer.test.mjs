import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import { spawnSync } from 'node:child_process';
import { checkRelease, sha256 } from '../scripts/update-installer.mjs';

const metadata = JSON.parse(fs.readFileSync(new URL('../installer-release.json', import.meta.url), 'utf8'));
const source = fs.readFileSync(new URL('../public/agentteams-install.sh', import.meta.url), 'utf8');
const prelude = source.slice(0, source.indexOf('\n_normalize_version()')).replace('website_main() {\n', '');
function shellFunction(name) {
  const match = source.match(new RegExp(`^${name}\\(\\) \\{\\n[\\s\\S]*?^\\}`, 'm'));
  assert.ok(match, `Missing installer function: ${name}`);
  return match[0];
}
function shell(code, env = {}) {
  return spawnSync('bash', ['-c', code], { encoding: 'utf8', env: { PATH: '/usr/bin:/bin', ...env } });
}

test('stable promotion requires a matching published release, not main or a preview', () => {
  const release = { tag_name: metadata.version, published_at: metadata.publishedAt, draft: false, prerelease: false };
  checkRelease(release, metadata.version);
  for (const change of [{ draft: true }, { prerelease: true }, { published_at: null }, { tag_name: 'main' }]) {
    assert.throws(() => checkRelease({ ...release, ...change }, metadata.version), /published stable release/);
  }
  assert.throws(() => checkRelease({ ...release, tag_name: 'main' }, 'main'), /published stable release/);
  assert.equal(sha256(source), metadata.sha256);
  assert.match(metadata.sourceURL, new RegExp(`/${metadata.commit}/install/agentteams-install.sh$`));
});

test('fresh install and wizard back navigation keep the promoted version without querying latest', () => {
  const result = shell(`${prelude}
    _refresh_known_stable_version() { echo 'Unexpected release lookup' >&2; exit 90; }
    resolve_image_tags() { printf '%s:%s\\n' "$AGENTTEAMS_VERSION" "$AGENTTEAMS_AUTO_VERSION"; }
    ${shellFunction('step_version')}
    step_version
    unset AGENTTEAMS_VERSION
    AGENTTEAMS_AUTO_VERSION=0
    step_version
  `);
  assert.equal(result.status, 0, result.stderr);
  assert.equal(result.stdout, `${metadata.version}:1\n${metadata.version}:1\n`);
});

test('explicit version overrides remain explicit and do not change the website default', () => {
  const result = shell(`${prelude}
    _refresh_known_stable_version() { exit 90; }
    resolve_image_tags() { printf '%s:%s\\n' "$AGENTTEAMS_VERSION" "$AGENTTEAMS_AUTO_VERSION"; }
    ${shellFunction('step_version')}
    step_version
  `, { AGENTTEAMS_VERSION: 'v1.2.4' });
  assert.equal(result.status, 0, result.stderr);
  assert.equal(result.stdout, 'v1.2.4:0\n');
});

test('missing pinned embedded image stops instead of pulling latest', () => {
  const result = shell(`${prelude}
    AGENTTEAMS_AUTO_VERSION=0
    AGENTTEAMS_REGISTRY=example.invalid
    DOCKER_CMD=mock_docker
    mock_docker() { case "$*" in *:latest) return 0 ;; *) return 1 ;; esac; }
    log() { :; }
    msg() { :; }
    _ver_lt() { return 1; }
    die() { printf '%s\\n' "$*" >&2; exit 70; }
    ${shellFunction('resolve_embedded_image')}
    resolve_embedded_image
  `);
  assert.equal(result.status, 70, result.stderr);
  // A fallback would succeed in this mock, so it must not be attempted.
  assert.match(result.stderr, /Pinned embedded image .* is unavailable. Refusing fallback to latest/);
});

test('available pinned image is selected successfully', () => {
  const result = shell(`${prelude}
    AGENTTEAMS_AUTO_VERSION=0
    AGENTTEAMS_REGISTRY=example.invalid
    DOCKER_CMD=mock_docker
    mock_docker() { return 0; }
    log() { :; }
    msg() { :; }
    ${shellFunction('resolve_embedded_image')}
    resolve_embedded_image
    printf '%s\\n' "$EMBEDDED_IMAGE"
  `);
  assert.equal(result.status, 0, result.stderr);
  assert.equal(result.stdout, `example.invalid/agentteams/agentteams-embedded:${metadata.version}\n`);
});

const harnessImages = {
  WORKER_IMAGE: 'openclaw',
  QWENPAW_WORKER_IMAGE: 'qwenpaw',
  HERMES_WORKER_IMAGE: 'hermes',
  DEEPSEEK_HARNESS_WORKER_IMAGE: 'deepseek',
  OPENHUMAN_WORKER_IMAGE: 'openhuman',
  CODEX_WORKER_IMAGE: 'codex',
};
function resolvedImages(env = {}) {
  const names = [...Object.keys(harnessImages), 'MANAGER_IMAGE', 'MANAGER_QWENPAW_IMAGE'];
  const result = shell(`${prelude}
    ${shellFunction('_normalize_version')}
    ${shellFunction('_ver_lt')}
    ${shellFunction('_supports_deepseek_harness')}
    ${shellFunction('resolve_image_tags')}
    AGENTTEAMS_REGISTRY=registry.example
    resolve_image_tags
    ${names.map((name) => `printf '${name}=%s\\n' "$${name}"`).join('\n')}
  `, env);
  assert.equal(result.status, 0, result.stderr);
  return Object.fromEntries(result.stdout.trim().split('\n').map((line) => line.split('=')));
}

test('promoted installer selects six versioned Harness images and shares Manager images', () => {
  const images = resolvedImages();
  for (const [name, runtime] of Object.entries(harnessImages)) {
    assert.equal(images[name], `registry.example/agentteams/agentteams-harness-${runtime}:${metadata.version}`);
  }
  assert.equal(images.MANAGER_IMAGE, images.WORKER_IMAGE);
  assert.equal(images.MANAGER_QWENPAW_IMAGE, images.QWENPAW_WORKER_IMAGE);
});

test('promoted Harness defaults retain all explicit Worker and Manager image overrides', () => {
  const overrides = Object.fromEntries(
    [...Object.keys(harnessImages), 'MANAGER_IMAGE', 'MANAGER_QWENPAW_IMAGE']
      .map((name) => [`AGENTTEAMS_INSTALL_${name}`, `custom.example/${name.toLowerCase()}:pinned`]),
  );
  const images = resolvedImages(overrides);
  for (const [name, image] of Object.entries(images)) {
    assert.equal(image, overrides[`AGENTTEAMS_INSTALL_${name}`]);
  }
});

test('image preflight reads platform fields supported by each engine', () => {
  for (const engine of ['docker', 'podman']) {
    for (const arch of ['arm64', 'amd64']) {
      const result = shell(`
        AGENTTEAMS_AUTO_VERSION=1
        AGENTTEAMS_VERSION=v1.2.7
        DOCKER_CMD=${engine}
        ${engine}() {
          [ "$1" = info ] || exit 91
          [ "$3" = '${engine === 'podman' ? '{{.Host.OS}}/{{.Host.Arch}}' : '{{.OSType}}/{{.Architecture}}'}' ] || return 92
          printf 'linux/${arch}\\n'
        }
        die() { echo "$*" >&2; exit 70; }
        _check_version_images() { printf '%s\\n' "$2"; }
        resolve_image_tags() { :; }
        ${shellFunction('_select_available_auto_version')}
        _select_available_auto_version
      `);
      assert.equal(result.status, 0, result.stderr);
      assert.equal(result.stdout.trim(), `linux/${arch}`);
    }
  }
});
