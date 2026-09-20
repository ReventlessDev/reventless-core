# Plan: the semantic-type list is exported, not transcribed

**Date:** 2026-09-20
**Status:** ✅ **Done, 2026-09-20.** `Semantic.brandedStrings` ships with the flag and the id
per entry, guarded by `SemanticBrandedStringsTest`. Full `reventless-spec` suite green (673
tests). The consumer that was blocked can proceed once this is published.

**The design changed on one point, in its favour.** The plan proposed a test comparing the new
registry against the ppx's list. While writing it, the ppx's own doc comment turned out to
state a mechanical rule for both facts — *"`grep -l '^type t = string' reventless/spec/src/semantic/*.res`
is the list"*, and the flag is whether the module exposes a bare `let schema`. Run against the
tree, that rule reproduces `branded_string_modules` exactly: the same twelve modules, the same
eight `true`s and four `false`s.

So **both hand-maintained lists are caches of a computable fact**, and the test recomputes it
from the files rather than comparing the two caches. That is strictly stronger: two lists agree
happily when both are wrong in the same way, and the failure actually worth catching — someone
adds a `type t = string` module and updates neither — is invisible to a two-way comparison.
Each list is checked against the computed truth separately, so a red test names which one
drifted. Verified by mutation in both directions.

## Why

The framework knows its semantic types in two places, neither of which a tool can read:

1. **`Semantic.Id`** ([`reventless/spec/src/semantic/Semantic.res:59`](../../reventless/spec/src/semantic/Semantic.res#L59))
   — the wire vocabulary `x-reventless-semantic` carries, as individual `let` bindings. There is
   no value enumerating them: a consumer can name a semantic type but cannot ask what they are.
2. **`branded_string_modules`** ([`packages/reventless-ppx/src/ppx/Util.ml:200`](../../packages/reventless-ppx/src/ppx/Util.ml#L200))
   — a hand-maintained OCaml association list of twelve entries, each with a boolean for
   whether the module exposes a name-derivable `let schema`. It is OCaml, inside the PPX, so it
   is unreachable from any ReScript or JavaScript consumer by construction.

The boolean is the part that matters and the part most likely to be transcribed wrong. The four
`false` entries — `MemberRef`, `StorageRef`, `UploadableFile`, `UploadableImage` — build their
schema from a function taking arguments (`forStore` / `forField` / `forCollection`), so a field
of one of those types always carries an explicit `@s.matches` and **there is no name a pass can
derive**. A consumer that offers those four as plain type picks emits code that does not
compile. That is not a degradation a consumer can detect; it is a build failure it causes.

Adding a semantic type today means editing both lists and every downstream copy, with nothing
checking that they agree. The two lists do not even hold the same set: `Semantic.Id` carries
composites (`money`, `dateRange`, `geoPoint`, `lifecycleTrail`) that `branded_string_modules`
does not, because the OCaml list is specifically the *transparent-string* ones.

## What

**Export one list, with the flag, from `reventless-spec`, and make the PPX's copy derive from
it or be checked against it.**

1. **A registry value in `Semantic.res`.** An array of records — the id, the module name, and
   whether the schema is name-derivable. `Semantic.Id`'s individual bindings stay; they are the
   ergonomic accessors, and the registry is the enumeration they were missing.

   **A plain ReScript value, and nothing more.** This package has no `gentypeconfig` and no
   `@genType` anywhere, and neither does any other package here — so a typed export is not the
   mechanism, it would be a new mechanism, introduced repo-wide to serve one consumer. A
   consumer that compiles ReScript reads this value by depending on the package, which is how
   the framework's other vocabularies already travel. One that needs a TypeScript view of it
   puts that boundary at its own edge, where such boundaries already exist. **Adding the first
   `@genType` here is out of scope and would be the more expensive answer to a question this
   value already settles.**
2. **Say which set is which.** The composites and the transparent-string brands are different
   populations with different rules, and a single flat list that hides the distinction would
   reproduce the current confusion at one remove. Mark it in the record.
3. **Neither list is trusted; both are checked against the sources.** The ppx keeps its copy —
   OCaml cannot see through `type t = string` at syntax level, so it genuinely needs one. What
   changes is that the copy is no longer the reference for anything: the test recomputes
   membership and the flag from `semantic/*.res` and checks each list against *that*,
   separately. **A silent divergence is the one outcome that must be impossible**, and a
   two-way comparison between caches does not deliver it.

## Verify — done

- ✅ Dropping one entry from the registry turns the two registry assertions red while the ppx
  assertion stays green, and vice versa when the ppx's flag is flipped instead. Both directions
  exercised by mutation, then restored; each failure names the list that drifted.
- ✅ The guard cannot pass vacuously: a first assertion proves the sources are readable from the
  test's working directory and that both computed sets are non-empty. Without it an unreadable
  path would make every later comparison trivially true.
- ✅ `CalendarDate` carries `date`, not `calendarDate` — asserted, because that one mapping is
  the reason the registry has to carry ids at all rather than leaving them derivable.
- ✅ Existing consumers of `Semantic.Id` compile unchanged; this adds a type and a value and
  reshapes nothing. Full package suite: 42 files, 673 tests, green.

## Scope

**In:** the registry value and the anti-drift check.

**Out:** introducing `@genType` or a `gentypeconfig` to this package. See §What, item 1.

**Out:** changing what any semantic type *does*; adding new ones; the per-type plans
(`semantic-date-range.md`, `semantic-geo-point.md` and siblings) keep their own scope. Also out:
what consumers do with the list — a picker that offers these types is a tools concern and is
planned there. This plan exists so that work is not blocked on transcribing a list it has been
told not to copy.
