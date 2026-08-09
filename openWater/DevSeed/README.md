# DevSeed

Test recordings that debug builds carry, so the sessions described in
`openWaterTests/Expectations/` are on whatever device is to hand without
importing them by hand.

**Everything here except this file is gitignored.** These are riders' GPS
traces and they do not belong in the repository — see `docs/OPEN.md`.

Fill it from your own `testdata/`:

```bash
scripts/sync-dev-seed.sh
```

Xcode's synchronised group picks up whatever is in this folder at build time.
On a clone with nothing here, the folder is empty, `DevSeed` finds no
archives and the app starts with an empty library. That is correct, not a
failure.
