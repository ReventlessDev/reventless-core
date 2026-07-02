// Regression test for Projection.optimizeActions (plan A7 / D2).
//
// optimizeActions merges consecutive per-id actions. A non-merging pair (Delete
// then Update) grows the accumulator to length 2; the next merge (Update+Set)
// must fold only the last action and keep everything before it exactly once.
// Before the `~end=count-1` fix, `previousActions` still contained the
// just-merged action, so the earlier action was duplicated — applied twice.

open JestGlobals
open Reventless.Projection

describe("Projection.optimizeActions", () => {
  testSync("does not duplicate the pre-merge action (off-by-one regression)", () => {
    let optimized = Projection.optimizeActions([Delete("a"), Update("a", x => x + 1), Set("a", 99)])
    // Was 3 (with a duplicated Update("a")) before the fix.
    expect(optimized->Array.length)->toBe(2)
    let sets =
      optimized->Array.filterMap(a =>
        switch a {
        | Set(id, s) => Some((id, s))
        | _ => None
        }
      )
    expect(sets)->toEqual([("a", 99)])
  })

  testSync("merges a same-id Create+Update chain into a single Create", () => {
    let optimized = Projection.optimizeActions([Create("a", 0), Update("a", x => x + 1), Update("a", x => x + 10)])
    let creates =
      optimized->Array.filterMap(a =>
        switch a {
        | Create(id, s) => Some((id, s))
        | _ => None
        }
      )
    expect(creates)->toEqual([("a", 11)])
  })
})
