import fs from 'node:fs';
import path from 'node:path';
import { pathToFileURL } from 'node:url';
import { createHash } from 'node:crypto';
import { spawnSync } from 'node:child_process';
import { parseHTML } from 'linkedom';

const installerReleases = [
  ['agentteams-install', 'installer-release.json'],
  ['agentteams-dashboard', 'dashboard-installer-release.json'],
].map(([name, metadata]) => [name, JSON.parse(fs.readFileSync(new URL(`../${metadata}`, import.meta.url), 'utf8'))]);
export const installerFiles = [...installerReleases.flatMap(([name]) => [`${name}.sh`, `${name}.LICENSE`]), 'agentteams-install.ps1', 'install.sh', 'install.ps1'];
export const requiredFiles = [
  'index.html', 'quickstart/index.html', 'docs/index.html',
  'docs/architecture/index.html', 'community/index.html', '404.html',
  'favicon.svg', 'robots.txt', 'sitemap-index.xml',
  ...installerFiles,
];
const origin = 'https://agentteams.cloud';

function listFiles(directory, prefix = '') {
  return fs.readdirSync(directory, { withFileTypes: true }).flatMap((entry) => {
    const relative = path.posix.join(prefix, entry.name);
    if (entry.isSymbolicLink()) throw new Error(`Symbolic links cannot be published: ${relative}`);
    if (entry.name.startsWith('.')) throw new Error(`Hidden files cannot be published: ${relative}`);
    return entry.isDirectory() ? listFiles(path.join(directory, entry.name), relative) : [relative];
  }).sort();
}

export function validateBuild(directory) {
  const files = listFiles(directory);
  const available = new Set(files);
  for (const file of requiredFiles) {
    if (!available.has(file)) throw new Error(`Missing required output: ${file}`);
  }
  for (const [name, release] of installerReleases) {
    for (const [file, checksum] of [[`${name}.sh`, release.sha256], [`${name}.LICENSE`, release.licenseSha256]]) {
      const actual = createHash('sha256').update(fs.readFileSync(path.join(directory, file))).digest('hex');
      if (actual !== checksum) throw new Error(`Installer release checksum mismatch: ${file}`);
    }
    const syntax = spawnSync('bash', ['-n', path.join(directory, `${name}.sh`)], { encoding: 'utf8' });
    if (syntax.status !== 0) throw new Error(`Installer syntax check failed: ${name}: ${syntax.stderr || syntax.error}`);
  }
  const psRelease = installerReleases[0][1].powershell;
  const psHash = createHash('sha256').update(fs.readFileSync(path.join(directory, 'agentteams-install.ps1'))).digest('hex');
  if (psHash !== psRelease.sha256) throw new Error('Installer release checksum mismatch: agentteams-install.ps1');
  for (const [file, checksum] of [['install.sh', installerReleases[0][1].sha256], ['install.ps1', psRelease.sha256]]) {
    const hash = createHash('sha256').update(fs.readFileSync(path.join(directory, file))).digest('hex');
    if (hash !== checksum) throw new Error(`Installer release checksum mismatch: ${file}`);
  }
  const pages = new Map();
  for (const file of files.filter((file) => file.endsWith('.html'))) {
    const { document } = parseHTML(fs.readFileSync(path.join(directory, file), 'utf8'));
    if (!document.querySelector('title')?.textContent.trim()) throw new Error(`Missing title: ${file}`);
    if (!document.querySelector('meta[name="description"]')?.getAttribute('content')) throw new Error(`Missing description: ${file}`);
    if (document.documentElement.lang !== 'zh-CN') throw new Error(`Missing page language: ${file}`);
    if (!document.querySelector('main')) throw new Error(`Missing main landmark: ${file}`);
    const canonical = document.querySelector('link[rel="canonical"]')?.getAttribute('href');
    const pagePath = `/${file.replace(/index\.html$/, '')}`;
    if (canonical !== new URL(pagePath, origin).href) throw new Error(`Incorrect canonical URL: ${file}`);
    if (file !== '404.html' && document.querySelector('meta[name="robots"]')?.getAttribute('content')?.includes('noindex')) {
      throw new Error(`Published page has noindex: ${file}`);
    }
    pages.set(file, document);
  }
  for (const [file, document] of pages) {
    const pageURL = new URL(`/${file.replace(/index\.html$/, '')}`, origin);
    for (const element of document.querySelectorAll('[href], [src]')) {
      const reference = element.getAttribute('href') ?? element.getAttribute('src');
      if (!reference || element.getAttribute('rel') === 'canonical') continue;
      const url = new URL(reference, pageURL);
      if (url.origin !== origin) continue;
      let target = decodeURIComponent(url.pathname).slice(1);
      if (url.pathname.endsWith('/')) target += 'index.html';
      if (!available.has(target)) throw new Error(`Broken local reference in ${file}: ${reference}`);
      if (url.hash && pages.has(target) && !pages.get(target).getElementById(decodeURIComponent(url.hash.slice(1)))) {
        throw new Error(`Missing anchor in ${file}: ${reference}`);
      }
    }
  }
  return files;
}

if (process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) {
  const files = validateBuild(path.resolve('dist'));
  console.log(`Validated ${files.filter((file) => file.endsWith('.html')).length} pages and ${files.length} output files.`);
}
