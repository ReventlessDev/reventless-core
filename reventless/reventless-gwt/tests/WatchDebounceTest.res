// Unit tests for Watch's event coalescing — the part Phase 12 added so a
// relocation's structural `unlink` survives a debounce window that also carries
// the trailing `add`/`change` of the same `mv`. The debounce uses real
// setTimeout(120ms), so these await past the window.

open JestGlobals

@val external setTimeout: (unit => unit, int) => unit = "setTimeout"
let delay = (ms: int): promise<unit> =>
  Promise.make((resolve, _reject) => setTimeout(() => resolve(), ms))

describe("Watch.isStructuralSource", () => {
  testPromise("an unlink of a .res source is structural", async () =>
    expect(Watch.isStructuralSource(Unlink, "/p/src/Foo/Bar.res"))->toEqual(true)
  )
  testPromise("a generated .res.mjs unlink is NOT structural (ends in .mjs)", async () =>
    expect(Watch.isStructuralSource(Unlink, "/p/src/Foo/Bar.res.mjs"))->toEqual(false)
  )
  testPromise("an add of a .res source is not structural (incremental handles it)", async () =>
    expect(Watch.isStructuralSource(Add, "/p/src/Foo/Bar.res"))->toEqual(false)
  )
  testPromise("a change of a .res source is not structural", async () =>
    expect(Watch.isStructuralSource(Change, "/p/src/Foo/Bar.res"))->toEqual(false)
  )
})

describe("Watch.debounce coalescing", () => {
  testPromise("a burst collapses to one call carrying the strongest event", async () => {
    let calls = ref([])
    let fire = Watch.debounce(40, (e, p) => calls := Array.concat(calls.contents, [(e, p)]))
    // A move/ungroup: the new file is created, an edit lands, then the old file
    // is unlinked — all inside one window. The unlink must win.
    fire(Watch.Change, "/p/src/A.res")
    fire(Watch.Add, "/p/src/new/A.res")
    fire(Watch.Unlink, "/p/src/old/A.res")
    await delay(120)
    expect(calls.contents->Array.length)->toEqual(1)
    let (e, p) = calls.contents->Array.getUnsafe(0)
    expect(e)->toEqual(Watch.Unlink)
    expect(p)->toEqual("/p/src/old/A.res")
  })

  testPromise("a later weaker event does not mask an earlier unlink", async () => {
    let calls = ref([])
    let fire = Watch.debounce(40, (e, _p) => calls := Array.concat(calls.contents, [e]))
    fire(Watch.Unlink, "/p/src/old/A.res")
    fire(Watch.Change, "/p/src/A.res")
    await delay(120)
    expect(calls.contents)->toEqual([Watch.Unlink])
  })

  testPromise("interleaved .res.mjs unlinks don't steal the representative path", async () => {
    // The real directory-mv burst chokidar emits: source AND generated files
    // unlink interleaved. The coalesced path must be a `.res` source, not the
    // last-seen `.res.mjs` (which would misclassify as a non-structural change).
    let calls = ref([])
    let fire = Watch.debounce(40, (e, p) => calls := Array.concat(calls.contents, [(e, p)]))
    fire(Watch.Unlink, "/p/src/old/A.res")
    fire(Watch.Unlink, "/p/src/old/A.res.mjs")
    fire(Watch.Unlink, "/p/src/old/A_Behavior.res")
    fire(Watch.Unlink, "/p/src/old/A_Behavior.res.mjs")
    fire(Watch.Add, "/p/src/new/A.res")
    fire(Watch.Add, "/p/src/new/A.res.mjs")
    await delay(120)
    expect(calls.contents->Array.length)->toEqual(1)
    let (e, p) = calls.contents->Array.getUnsafe(0)
    expect(e)->toEqual(Watch.Unlink)
    expect(Watch.isStructuralSource(e, p))->toEqual(true)
  })

  testPromise("a lone change stays a change (incremental re-run)", async () => {
    let calls = ref([])
    let fire = Watch.debounce(40, (e, _p) => calls := Array.concat(calls.contents, [e]))
    fire(Watch.Change, "/p/src/A.res")
    await delay(120)
    expect(calls.contents)->toEqual([Watch.Change])
  })
})
