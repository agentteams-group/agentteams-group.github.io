import fs from 'node:fs';
import path from 'node:path';
import { installerFiles, validateBuild } from './validate-build.mjs';

const directory = path.resolve('dist');
const files = validateBuild(directory);
if (!process.env.SITE_URL) throw new Error('Set SITE_URL to the HTTPS website origin.');
const site = new URL(process.env.SITE_URL);
if (site.protocol !== 'https:' || site.pathname !== '/' || site.search || site.hash || site.username || site.password) {
  throw new Error('SITE_URL must be an HTTPS origin without a path, credentials, query or fragment.');
}
const requests = [
  ...files.filter((file) => file.endsWith('.html') && file !== '404.html').map((file) => ({
    route: `/${file.replace(/index\.html$/, '')}`, file, status: 200, type: 'text/html',
  })),
  ...files.filter((file) => /\.(css|js)$/.test(file)).map((file) => ({
    route: `/${file}`, file, status: 200, type: file.endsWith('.css') ? 'text/css' : 'javascript',
  })),
  ...installerFiles.map((file) => ({ route: `/${file}`, file, status: 200, type: 'text/plain', ...(file.endsWith('.sh') ? { cache: 'no-cache' } : {}) })),
  { route: `/__website_missing_${Date.now()}__/`, file: '404.html', status: 404, type: 'text/html' },
];
for (const request of requests) {
  const url = new URL(request.route, site);
  url.searchParams.set('verify', process.env.GITHUB_SHA || String(Date.now()));
  const response = await fetch(url, {
    redirect: 'manual', signal: AbortSignal.timeout(15_000), headers: { 'Cache-Control': 'no-cache' },
  });
  if (response.status !== request.status) throw new Error(`${request.route}: expected ${request.status}, received ${response.status}`);
  if (!response.headers.get('content-type')?.includes(request.type)) throw new Error(`${request.route}: incorrect Content-Type`);
  if (request.cache && !response.headers.get('cache-control')?.includes(request.cache)) throw new Error(`${request.route}: incorrect Cache-Control`);
  if (response.headers.get('content-disposition')?.toLowerCase().includes('attachment')) throw new Error(`${request.route}: response triggers a download`);
  const actual = Buffer.from(await response.arrayBuffer());
  const expected = fs.readFileSync(path.join(directory, request.file));
  if (!actual.equals(expected)) throw new Error(`${request.route}: served content differs from this deployment artifact`);
  console.log(`Verified ${request.status} ${request.route}`);
}
