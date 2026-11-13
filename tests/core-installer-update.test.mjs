import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { prepareCoreInstaller, sha256 } from '../scripts/update-installer.mjs';

const root = new URL('../', import.meta.url);
const metadata = JSON.parse(fs.readFileSync(new URL('installer-release.json', root)));
const sources = Object.fromEntries(['sh', 'ps1'].map((extension) => [extension, fs.readFileSync(new URL(`public/install.${extension}`, root), 'utf8')]));

test('Core promotion updates only release markers and is idempotent', () => {
  for (const extension of ['sh', 'ps1']) {
    const source = sources[extension];
    assert.equal(prepareCoreInstaller(source, extension, metadata.version, metadata.version), source);
    const edited = `${source}\n# Independent installer change\n`;
    const promoted = prepareCoreInstaller(edited, extension, metadata.version, 'v9.8.7');
    assert.ok(promoted.endsWith('# Independent installer change\n'));
    assert.equal(prepareCoreInstaller(promoted, extension, 'v9.8.7', 'v9.8.7'), promoted);
    assert.equal(prepareCoreInstaller(promoted, extension, 'v9.8.7', metadata.version), edited);
    assert.throws(() => prepareCoreInstaller(source.replace('# AgentTeams website stable installer:', '# Removed:'), extension, metadata.version, 'v9.8.7'), /version marker/);
  }
});

function fixture(t) {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'website-core-update-'));
  t.after(() => fs.rmSync(directory, { recursive: true, force: true }));
  fs.mkdirSync(path.join(directory, 'scripts'));
  fs.mkdirSync(path.join(directory, 'public'));
  fs.mkdirSync(path.join(directory, 'bin'));
  fs.copyFileSync(new URL('scripts/update-installer.mjs', root), path.join(directory, 'scripts/update-installer.mjs'));
  fs.writeFileSync(path.join(directory, 'installer-release.json'), JSON.stringify(metadata, null, 2) + '\n');
  for (const extension of ['sh', 'ps1']) {
    for (const name of ['install', 'agentteams-install']) fs.writeFileSync(path.join(directory, `public/${name}.${extension}`), sources[extension]);
  }
  // Only mock Release metadata lookup; run the real updater and file writes.
  const gh = path.join(directory, 'bin/gh');
  fs.writeFileSync(gh, `#!${process.execPath}
const endpoint = process.argv[3];
if (endpoint.includes('/releases/tags/')) console.log(JSON.stringify({tag_name:endpoint.split('/').pop(),published_at:'2026-01-01T00:00:00Z',draft:false,prerelease:false}));
else if (endpoint.includes('/commits/')) console.log(JSON.stringify({sha:'${'a'.repeat(40)}'}));
else process.exit(1);
`);
  fs.chmodSync(gh, 0o755);
  return {
    directory,
    run: (version) => spawnSync(process.execPath, ['scripts/update-installer.mjs', version], {
      cwd: directory, encoding: 'utf8', env: { ...process.env, PATH: `${directory}/bin:${process.env.PATH}` },
    }),
    snapshot: () => Object.fromEntries(['installer-release.json', ...['sh', 'ps1'].flatMap((extension) => [`public/install.${extension}`, `public/agentteams-install.${extension}`])]
      .map((file) => [file, fs.readFileSync(path.join(directory, file), 'utf8')])),
  };
}

test('Core updater refreshes aliases and hashes, preserves provenance, and repeats without changes', (t) => {
  const f = fixture(t);
  const sourcePath = path.join(f.directory, 'public/install.sh');
  fs.appendFileSync(sourcePath, '\n# Independently maintained change\n');
  for (const version of [metadata.version, 'v9.8.7']) {
    const result = f.run(version);
    assert.equal(result.status, 0, result.stderr);
    const snapshot = f.snapshot();
    const release = JSON.parse(snapshot['installer-release.json']);
    assert.equal(release.version, version);
    assert.deepEqual(release.importedFrom, metadata.importedFrom);
    assert.match(snapshot['public/install.sh'], /Independently maintained change/);
    for (const extension of ['sh', 'ps1']) {
      assert.equal(snapshot[`public/install.${extension}`], snapshot[`public/agentteams-install.${extension}`]);
      assert.equal(sha256(snapshot[`public/install.${extension}`]), extension === 'sh' ? release.sha256 : release.powershell.sha256);
    }
    assert.equal(f.run(version).status, 0);
    assert.deepEqual(f.snapshot(), snapshot);
    const prelude = snapshot['public/install.sh'].split('\n_normalize_version()')[0].replace('website_main() {\n', '');
    const shell = spawnSync('bash', ['-c', `${prelude}\nprintf '%s' "$AGENTTEAMS_VERSION"`], { encoding: 'utf8', env: { PATH: '/usr/bin:/bin' } });
    assert.equal(shell.status, 0, shell.stderr);
    assert.equal(shell.stdout, version);
  }
});

test('Core updater rejects missing or duplicate markers and invalid Bash before any file writes', (t) => {
  const f = fixture(t);
  for (const [extension, badSource] of [
    ['ps1', sources.ps1.replace('AGENTTEAMS_KNOWN_STABLE_VERSION =', 'REMOVED =')],
    ['ps1', `${sources.ps1}\n$script:AGENTTEAMS_KNOWN_STABLE_VERSION = "${metadata.version}"\n`],
    ['sh', `${sources.sh}\nif then\n`],
  ]) {
    for (const ext of ['sh', 'ps1']) fs.writeFileSync(path.join(f.directory, `public/install.${ext}`), sources[ext]);
    fs.writeFileSync(path.join(f.directory, `public/install.${extension}`), badSource);
    const before = f.snapshot();
    assert.notEqual(f.run('v9.8.7').status, 0);
    assert.deepEqual(f.snapshot(), before);
  }
});
