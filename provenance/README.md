# Provenance

Every CryptoBosses island image is fixed. Anyone can prove it, with no trust in us, in three steps: hash each image, hash the list, compare with the value stored in the collection contract.

## Current: the island deeds (on-chain)

| | |
|---|---|
| **Provenance hash** | `5bce3bceea9b28f3742c98cadb8e76d9fcb42e87e60aeae26347435b7dde29cc` |
| Stored in | `BOSS_PROVENANCE()` of `0x4958b779Bf6DB003DD87F67F0fc89d049d227C17` (Ethereum mainnet) |
| Images | `https://cdn.cryptobossesnft.com/img/{0..9999}.svg` |
| Rule | `hN = SHA-256(N.svg)` · `PROVENANCE = SHA-256(h0 + h1 + … + h9999)` (lowercase hex, no separator) |

| File | What it holds |
|---|---|
| [`islands/PROVENANCE-HASH.txt`](islands/PROVENANCE-HASH.txt) | the hash of all 10,000 images together |
| [`islands/SHA256SUMS`](islands/SHA256SUMS) | one hash per island, `sha256sum` format (`<hash>  N.svg`) |
| [`islands/provenance.txt`](islands/provenance.txt) | the same list as published at `cdn.cryptobossesnft.com/provenance.txt` |
| [`verify.mjs`](verify.mjs) | the check below, in one script (Node 18+, no dependencies, read-only) |

### Verify

```bash
node provenance/verify.mjs                 # list ⇄ hash ⇄ contract (seconds)
node provenance/verify.mjs --ids 0-99      # + download and hash islands #0..#99
node provenance/verify.mjs --ids all       # + all 10,000 images (~650 MB), rebuilt from scratch
```

Or with standard tools, for a single island:

```bash
curl -s https://cdn.cryptobossesnft.com/img/42.svg | sha256sum   # compare with line 43 of islands/SHA256SUMS
```

## Historical: the original 2021 artwork

The collection launched in 2021 with 10,000 PNG portraits (10,000 × 10,000 px). Their checksums are kept here unchanged, as they were first published. Since November 2026 the on-chain provenance points to the island deeds above.

| | |
|---|---|
| Provenance hash (2021) | `256a0598e63be92783e2983a9156f42989c0c91d1226faae578d632ff5f64aa8` |
| [`original-2021/SHA-256-Checksums`](original-2021/SHA-256-Checksums) | one hash per image, `./0.png` to `./9999.png` |
| [`original-2021/ALL-IMAGES-CONCATENATED.txt`](original-2021/ALL-IMAGES-CONCATENATED.txt) | the 10,000 hashes in order, the input of the 2021 hash |
