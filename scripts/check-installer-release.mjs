import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { pathToFileURL } from 'node:url';

const targets = {
  at: { repository: 'agentscope-ai/AgentTeams', metadata: 'installer-release.json' },
  dashboard: { repository: 'agentteams-group/agentteams-dashboard', metadata: 'dashboard-installer-release.json' },
};
const stableTag = /^v(\d+)\.(\d+)\.(\d+)$/;

export function compareVersions(left, right) {
  const parts = [left, right].map((tag) => {
    const match = stableTag.exec(tag);
    if (!match) throw new Error(`Invalid stable version: ${tag}`);
    return match.slice(1).map(BigInt);
  });
  for (let i = 0; i < 3; i++) {
    if (parts[0][i] !== parts[1][i]) return parts[0][i] > parts[1][i] ? 1 : -1;
  }
  return 0;
}

export function findUpgrade(releases, current) {
  compareVersions(current, current);
  const stable = releases.filter((release) => stableTag.test(release.tag_name)
    && !release.draft && !release.prerelease && release.published_at);
  stable.sort((a, b) => compareVersions(b.tag_name, a.tag_name));
  const latest = stable[0];
  return latest && compareVersions(latest.tag_name, current) > 0 ? latest : null;
}

function main() {
  const [product, ...extra] = process.argv.slice(2);
  if (!Object.hasOwn(targets, product) || extra.length) throw new Error('Usage: node scripts/check-installer-release.mjs at|dashboard');
  const target = targets[product];
  const metadata = JSON.parse(fs.readFileSync(new URL(`../${target.metadata}`, import.meta.url), 'utf8'));
  if (metadata.repository !== target.repository) throw new Error('Installer repository does not match the configured upstream.');
  const result = spawnSync('gh', ['api', '--paginate', '--slurp', `repos/${target.repository}/releases?per_page=100`], {
    encoding: 'utf8', timeout: 60_000, maxBuffer: 16 * 1024 * 1024,
  });
  if (result.status !== 0) throw new Error(`Release lookup failed: ${result.stderr || result.error}`);
  const release = findUpgrade(JSON.parse(result.stdout).flat(), metadata.version);
  const output = `changed=${Boolean(release)}\nprevious=${metadata.version}\nversion=${release?.tag_name || metadata.version}\n`;
  console.log(`${target.repository}: ${release ? `${metadata.version} → ${release.tag_name}` : `already current (${metadata.version}); no update`}`);
  if (process.env.GITHUB_OUTPUT) fs.appendFileSync(process.env.GITHUB_OUTPUT, output);
  if (process.env.GITHUB_STEP_SUMMARY) fs.appendFileSync(process.env.GITHUB_STEP_SUMMARY,
    `### ${target.repository}\n\n${release ? `发现正式版本 [${release.tag_name}](https://github.com/${target.repository}/releases/tag/${release.tag_name})，官网当前 ${metadata.version}。后续更新和检查成功后创建升级 PR。` : `官网 ${metadata.version}，没有更新的正式版本。`}\n`);
}

if (process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) {
  try { main(); } catch (error) { console.error(error.message); process.exitCode = 1; }
}
