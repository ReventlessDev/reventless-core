# The generators emit sources the format check rejects

**Date:** 2026-09-10<br/>
**Status:** Open. Found while adding a slice to the hybrid ordering plugin; worked around there by
running the formatter after the generator. Nothing is broken today — the tree is canonical — but the
next person to regenerate anything meets it again.

---

## What happens

`npm run generate` in a plugin package rewrites `src/Plugin.res` from the component sources. The
generator emits unformatted output: long record literals and functor applications on one line. The
committed copies are formatted, because `5f7a10a4a` *"reprint every source through the formatter"*
swept the whole tree — **including the eight generated `Plugin.res` files and the generated
`Main.res` files** — and `ea2266d64` then added `format:res:check` to keep it that way.

So a regeneration that adds one slice produces a diff of roughly **13 real lines and 140 lines of
reformatting**, and the result fails the repo's own check:

```
$ npm run generate && git diff --stat src/Plugin.res
 1 file changed, 27 insertions(+), 140 deletions(-)

$ npm run format:res:check
The 1 files listed above need formatting
```

Running `rescript format` on the file afterwards collapses that to 13 insertions and 0 deletions.

## Why it matters more than the diff noise

- **The noise hides the change.** A reviewer looking at a regenerated plugin root has to find one new
  slice registration inside a hundred and forty lines of rewrapping.
- **It is a CI failure waiting for whoever forgets the second step.** The check is enforced, the
  generator is not; nothing tells an author the two disagree.
- **The file says not to edit it.** `Plugin.res` opens with *"AUTO-GENERATED — do not edit"*, which is
  exactly the instruction that makes "and then run the formatter over it" surprising.

## Where it would be fixed

`format:res` takes every tracked `.res` with one template excluded, so generated files are in the set
deliberately rather than by oversight — which points at the generator rather than at the file set.

Six write sites, five generators, all in `reventless/spec/src/generator/`: `PluginGenerator` (the
plugin root and the deploy `Main.res`), `PlatformGenerator`, `GraftTrait`, `CertifyTrait`,
`TraitManifestCli`.

Two shapes, and the choice is not obvious:

| | |
|---|---|
| **Format inside the generator** | One change, every consumer benefits, output is canonical wherever it lands. But the generator ships in a published package and would be shelling out to a formatter in someone else's repo — including repos with different conventions, or none |
| **Format in the `generate` script** | `generate-plugin src/ && rescript format src/Plugin.res`, twelve package.json files. Honest about being this repo's policy rather than the generator's, and touches nothing downstream. Twelve places to forget |

The second is the safer default and the first is the one that actually holds. Not decided here.

## Honesty ledger

- **Measured:** the 27/140 and 13/0 diffs, on `examples/online-shop-hybrid/ordering`, adding one
  StateChangeSlice; `format:res:check` failing before the formatter runs and passing after; the eight
  generated `Plugin.res` files in `5f7a10a4a`; the six write sites.
- **Not measured:** whether the other two example trees regenerate identically — the same generator
  writes them, so the same result is expected but was not run. `online-shop-dcb`'s two `*-aws`
  packages cannot be built at all right now for an unrelated reason (their generated `Plugin.res` was
  never committed), so they would need generating before they could be compared.
- **Not investigated:** whether `rescript format` is reliably resolvable from a consumer's
  `node_modules` when the generator runs there, which is the thing that decides between the two shapes
  above.
