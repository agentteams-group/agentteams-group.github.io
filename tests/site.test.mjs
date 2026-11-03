import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { installerFiles, requiredFiles, validateBuild } from '../scripts/validate-build.mjs';
import { createDeploymentPlan, uploadWebsite } from '../scripts/deploy-oss.mjs';

function fixture(t) {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'agentteams-website-'));
  t.after(() => fs.rmSync(directory, { recursive: true, force: true }));
  for (const file of [...requiredFiles, '_astro/site.abc123.css', 'images/team.svg']) {
    fs.mkdirSync(path.dirname(path.join(directory, file)), { recursive: true });
    if (installerFiles.includes(file)) {
      fs.copyFileSync(new URL(`../public/${file}`, import.meta.url), path.join(directory, file));
      continue;
    }
    const route = `/${file.replace(/index\.html$/, '')}`;
    fs.writeFileSync(path.join(directory, file), file.endsWith('.html')
      ? `<!doctype html><html lang="zh-CN"><head><title>AgentTeams</title><meta name="description" content="Team collaboration"><link rel="canonical" href="https://agentteams.cloud${route}"><link rel="stylesheet" href="/_astro/site.abc123.css"></head><body><main id="main"><a href="/docs/architecture/#roles">Architecture</a><h1 id="roles">Roles</h1></main></body></html>`
      : 'fixture');
  }
  return directory;
}

test('valid nested pages and cross-page anchors can be published', (t) => {
  const files = validateBuild(fixture(t));
  assert.ok(files.includes('docs/architecture/index.html'));
});

test('missing stylesheet blocks publication even when every page exists', (t) => {
  const directory = fixture(t);
  fs.unlinkSync(path.join(directory, '_astro/site.abc123.css'));
  assert.throws(() => createDeploymentPlan(directory), /Broken local reference/);
});

test('broken fragment links block publication', (t) => {
  const directory = fixture(t);
  const file = path.join(directory, 'docs/architecture/index.html');
  fs.writeFileSync(file, fs.readFileSync(file, 'utf8').replace('id="roles"', 'id="changed"'));
  assert.throws(() => validateBuild(directory), /Missing anchor/);
});

test('missing required pages block publication', (t) => {
  const directory = fixture(t);
  fs.unlinkSync(path.join(directory, '404.html'));
  assert.throws(() => createDeploymentPlan(directory), /Missing required output: 404.html/);
});

test('missing or modified installer blocks publication before uploading', (t) => {
  for (const name of installerFiles) {
    const directory = fixture(t);
    const file = path.join(directory, name);
    fs.appendFileSync(file, '\n# unreviewed change\n');
    assert.throws(() => createDeploymentPlan(directory), /Installer release checksum mismatch/);
    fs.unlinkSync(file);
    assert.throws(() => createDeploymentPlan(directory), /Missing required output: agentteams-/);
  }
});

test('hidden files and symlinks cannot leak into the public bucket', (t) => {
  const directory = fixture(t);
  fs.writeFileSync(path.join(directory, '.env'), 'PRIVATE=value');
  assert.throws(() => createDeploymentPlan(directory), /Hidden files/);
  fs.unlinkSync(path.join(directory, '.env'));
  fs.symlinkSync(path.join(directory, 'index.html'), path.join(directory, 'linked.html'));
  assert.throws(() => createDeploymentPlan(directory), /Symbolic links/);
});

test('assets finish before HTML, homepage is last, and cache policies differ', async (t) => {
  const plan = createDeploymentPlan(fixture(t));
  const uploads = [];
  const client = { put: async (key, file, options) => uploads.push({ key, file, options }) };
  await uploadWebsite(client, plan, () => {});
  assert.equal(uploads.at(-1).key, 'index.html');
  const firstPage = uploads.findIndex(({ key }) => key.endsWith('.html'));
  assert.ok(uploads.slice(0, firstPage).every(({ key }) => !key.endsWith('.html')));
  assert.ok(uploads.slice(firstPage).every(({ key }) => key.endsWith('.html')));
  assert.equal(uploads.find(({ key }) => key.startsWith('_astro/')).options.headers['Cache-Control'], 'public,max-age=31536000,immutable');
  assert.equal(uploads.find(({ key }) => key === 'images/team.svg').options.headers['Cache-Control'], 'public,max-age=300');
  assert.equal(uploads.at(-1).options.headers['Cache-Control'], 'public,max-age=300');
  assert.equal(uploads.at(-1).options.mime, 'text/html; charset=utf-8');
  for (const name of installerFiles) {
    const installer = uploads.find(({ key }) => key === name);
    assert.equal(installer.options.headers['Cache-Control'], name.endsWith('.sh') ? 'no-cache' : 'public,max-age=300');
    assert.equal(installer.options.mime, 'text/plain; charset=utf-8');
  }
});

test('an asset upload failure leaves all HTML untouched', async (t) => {
  const plan = createDeploymentPlan(fixture(t));
  const uploaded = [];
  const client = { put: async (key) => {
    if (key === 'images/team.svg') throw new Error('OSS unavailable');
    uploaded.push(key);
  } };
  await assert.rejects(uploadWebsite(client, plan, () => {}), /OSS unavailable/);
  assert.ok(uploaded.length > 0);
  assert.ok(uploaded.every((key) => !key.endsWith('.html')));
});

test('the same artifact produces the same plan without deleting previous objects', async (t) => {
  const directory = fixture(t);
  const plan = createDeploymentPlan(directory);
  assert.deepEqual(createDeploymentPlan(directory), plan);
  const objects = new Map([['_astro/previous-version.css', 'retained']]);
  const client = { put: async (key, file) => objects.set(key, fs.readFileSync(file, 'utf8')) };
  await uploadWebsite(client, plan, () => {});
  const first = new Map(objects);
  await uploadWebsite(client, createDeploymentPlan(directory), () => {});
  assert.deepEqual(objects, first);
  assert.equal(objects.get('_astro/previous-version.css'), 'retained');
  const homepage = path.join(directory, 'index.html');
  fs.writeFileSync(homepage, fs.readFileSync(homepage, 'utf8').replace('Team collaboration', 'Updated collaboration'));
  await uploadWebsite(client, createDeploymentPlan(directory), () => {});
  assert.match(objects.get('index.html'), /Updated collaboration/);
});
