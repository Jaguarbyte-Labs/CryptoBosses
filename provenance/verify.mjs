#!/usr/bin/env node
// CryptoBosses: verify the island provenance yourself. Node 18+, no dependencies, read-only.
//
//   node provenance/verify.mjs                  check the published lists + the on-chain hash (fast, no images)
//   node provenance/verify.mjs --ids 0-99       also download those island images from the CDN and hash them
//   node provenance/verify.mjs --ids all        download all 10,000 images (~650 MB) and rebuild the provenance from scratch
//   node provenance/verify.mjs --dir ./img      hash a local folder holding 0.svg ... 9999.svg instead of downloading
//
// Rule:  hN = SHA-256(bytes of N.svg)      PROVENANCE = SHA-256( h0 + h1 + ... + h9999 )   (lowercase hex, no separator)

import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const CDN = 'https://cdn.cryptobossesnft.com/img/';
const BOSSES = '0x4958b779Bf6DB003DD87F67F0fc89d049d227C17';
const RPCS = ['https://ethereum-rpc.publicnode.com', 'https://eth.drpc.org', 'https://cloudflare-eth.com'];
const sha = (b) => createHash('sha256').update(b).digest('hex');
const arg = (k) => { const i = process.argv.indexOf(k); return i > 0 ? process.argv[i + 1] : undefined; };
const ok = (m) => console.log(`  \x1b[32m✔\x1b[0m ${m}`), bad = (m) => { console.log(`  \x1b[31m✘\x1b[0m ${m}`); process.exitCode = 1; };

// 1. the published per-island list and the published final hash agree
const list = readFileSync(join(HERE, 'islands', 'SHA256SUMS'), 'utf8').trim().split('\n').map((l) => l.split(/\s+/)[0]);
const published = readFileSync(join(HERE, 'islands', 'PROVENANCE-HASH.txt'), 'utf8').trim();
console.log('\nCryptoBosses island provenance\n');
list.length === 10000 ? ok('SHA256SUMS lists 10,000 islands') : bad(`SHA256SUMS lists ${list.length} lines`);
const fromList = sha(list.join(''));
fromList === published ? ok(`SHA-256 of the 10,000 hashes = ${published}`) : bad(`list gives ${fromList}, PROVENANCE-HASH.txt says ${published}`);

// 2. the hash stored in the collection contract (BOSS_PROVENANCE)
let onchain;
for (const rpc of RPCS) {
  try {
    const r = await fetch(rpc, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'eth_call', params: [{ to: BOSSES, data: '0x25dc226a' }, 'latest'] }) });
    const hex = (await r.json()).result.slice(2), len = parseInt(hex.slice(64, 128), 16);
    onchain = Buffer.from(hex.slice(128, 128 + len * 2), 'hex').toString('utf8'); break;
  } catch { /* next RPC */ }
}
if (onchain === undefined) console.log('  ? could not reach an Ethereum RPC; skipped the on-chain check');
else onchain === published ? ok(`BOSS_PROVENANCE() on Ethereum mainnet matches`) : bad(`BOSS_PROVENANCE() on-chain is ${onchain}`);

// 3. optional: hash the images themselves
const dir = arg('--dir'), ids = arg('--ids') ?? (dir ? 'all' : undefined);
if (ids) {
  const [a, b] = ids === 'all' ? [0, 9999] : ids.split('-').map(Number).concat(Number(ids.split('-')[0])).slice(0, 2);
  const got = []; let wrong = 0;
  for (let id = a; id <= b; id++) {
    const bytes = dir ? readFileSync(join(dir, `${id}.svg`)) : Buffer.from(await (await fetch(CDN + id + '.svg')).arrayBuffer());
    const h = sha(bytes); got[id] = h;
    if (h !== list[id]) { wrong++; bad(`island #${id}: ${h} differs from the list`); }
    if ((id - a) % 500 === 499) console.log(`    ${id - a + 1} / ${b - a + 1} images`);
  }
  if (!wrong) ok(`${b - a + 1} image(s) #${a}..#${b} match SHA256SUMS (${dir ? 'local folder' : 'downloaded from the CDN'})`);
  if (a === 0 && b === 9999 && !wrong) sha(got.join('')) === published ? ok('provenance rebuilt from the images themselves') : bad('rebuilt provenance differs');
}
console.log(process.exitCode ? '\nFAILED\n' : '\nAll checks passed.\n');
