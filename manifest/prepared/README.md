# Prepared inputs

Written by [`cache-pack.sh`](../../cache-pack.sh), read by
[`fetch-prepared.sh`](../../fetch-prepared.sh):

| | |
|---|---|
| `source.json` | size and SHA-256 of each prepared artifact, plus the `mtd1`/`mtd3` hashes of the dump they came from. The trust anchor. |
| `bundle.sha256` | hash and filename of the published bundle. |
| `bundle.url` | where it lives. `BASEOS_PREPARED_URL` overrides it. |

The bundle carries `uboot.img`, `boot.img` and `stock-harvest.tar`. `source.json`
travels in git rather than inside the bundle, so what validates the download is
not part of it.
