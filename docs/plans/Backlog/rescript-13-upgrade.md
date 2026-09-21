# Plan (Backlog): ReScript 13 and the steps that prepare for it

**Status:** Backlog (not started). ReScript 13 is still in alpha (`13.0.0-alpha.6` on 2026-09-16).<br/>
**Analysis:** [rescript-version-upgrade.md](../../analysis/done/rescript-version-upgrade.md).
That analysis moved the repo to 12.3.1. This plan holds what it left open.

## In plain words

Our own sources already avoid everything ReScript 13 removes. What blocks the upgrade is
outside code: the serialization library `sury` accepts only ReScript 12, and the file format
the compiler uses to talk to our PPX has not been confirmed stable in a final release.
Steps 1–2 can be done now, independently. Step 3 waits for upstream.

## Steps

1. ✅ **sury / sury-ppx 11.0.0-rc.2 → 11.0.0 final.** Done 2026-09-21, see
   [sury-11-final.md](../done/sury-11-final.md). sury 11.0.0 still declares
   `rescript: 12.x`, so step 3 still waits for a sury release that accepts 13.
2. **Remove `@rescript/std ^11.1.4`** from `rescript/ssh2` and `rescript/web`. It is the
   runtime package from the v11 era. Check whether anything still imports it, and drop it.
3. **ReScript 13**, once 13.0.0 is final and a sury release accepts it:
   - Wipe every `lib/`. The AST, CMI and CMT formats change, so stale caches fail with
     "The value X can't be found".
   - Check first that both PPXes load and produce unchanged output. The upstream changelog
     says the external PPX format stays compatible. The arity wrapper that 12.3.1 needed
     (`Function$` with `@res.arity`) is the one to watch.
   - Re-run the removal checks in the analysis (`Js`, `Belt`, `%re`, uncurried syntax,
     `Obj`, `@get`/`@set`). All of them had zero hits on 2026-09-21.
   - Check the `@rescript/react` version in the hybrid `seed-data` (0.15 needs React 19.2).
   - Clean build, goldens, full tests, as for 12.3.1.
