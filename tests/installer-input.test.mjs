import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';

for (const name of ['agentteams-install', 'agentteams-dashboard']) {
  const source = fs.readFileSync(new URL(`../public/${name}.sh`, import.meta.url), 'utf8');
  // Exercise the shipped input boundary without starting containers or reading credentials.
  const start = source.indexOf('website_main() {\n');
  const end = source.lastIndexOf('\n}\n\n# Connect interactive');
  const probe = `
if [ "\${AGENTTEAMS_NON_INTERACTIVE:-0}" = 1 ]; then
  printf 'AUTOMATED:%s\\n' "$#"
  printf 'ARG:%s\\n' "$@"
else
  printf 'READY\\n'
  read -r answer
  printf 'ANSWER:%s\\n' "$answer"
fi
`;
  assert.ok(start >= 0 && end > start, `Missing input boundary: ${name}`);
  const harness = source.slice(start, start + 'website_main() {\n'.length) + probe + source.slice(end);

  test(`${name}: piping a script without a terminal fails before installation`, () => {
    const result = spawnSync('bash', [], { input: harness, encoding: 'utf8', detached: true });
    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /requires a terminal/);
    assert.doesNotMatch(result.stdout, /READY/);
  });

  test(`${name}: automation needs no terminal and preserves command arguments`, () => {
    const result = spawnSync('bash', ['-s', '--', 'worker', '--name', 'demo worker'], {
      input: harness, encoding: 'utf8', detached: true,
      env: { ...process.env, AGENTTEAMS_NON_INTERACTIVE: '1' },
    });
    assert.equal(result.status, 0, result.stderr);
    assert.equal(result.stdout, 'AUTOMATED:3\nARG:worker\nARG:--name\nARG:demo worker\n');
  });

  test(`${name}: file execution preserves redirected answers`, (t) => {
    const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'agentteams-input-'));
    t.after(() => fs.rmSync(directory, { recursive: true, force: true }));
    const file = path.join(directory, 'installer.sh');
    fs.writeFileSync(file, harness);
    const result = spawnSync('bash', [file], { input: 'file answer\n', encoding: 'utf8', detached: true });
    assert.equal(result.status, 0, result.stderr);
    assert.equal(result.stdout, 'READY\nANSWER:file answer\n');
  });
}
