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

  testPromise("interleaved .res.mjs unlinks never surface; each distinct .res source does", async () => {
    // The real directory-mv burst chokidar emits: source AND generated files
    // unlink interleaved. Only `.res` sources are emitted (never a `.res.mjs`),
    // and every *distinct* source is emitted — two moved modules must both drive
    // a rebuild, not collapse to one representative.
    let calls = ref([])
    let fire = Watch.debounce(40, (e, p) => calls := Array.concat(calls.contents, [(e, p)]))
    fire(Watch.Unlink, "/p/src/old/A.res")
    fire(Watch.Unlink, "/p/src/old/A.res.mjs")
    fire(Watch.Unlink, "/p/src/old/A_Behavior.res")
    fire(Watch.Unlink, "/p/src/old/A_Behavior.res.mjs")
    fire(Watch.Add, "/p/src/new/A.res")
    fire(Watch.Add, "/p/src/new/A.res.mjs")
    await delay(120)
    let paths = calls.contents->Array.map(((_, p)) => p)
    expect(calls.contents->Array.every(((e, p)) => Watch.isStructuralSource(e, p)))->toEqual(true)
    expect(paths->Array.includes("/p/src/old/A.res"))->toEqual(true)
    expect(paths->Array.includes("/p/src/old/A_Behavior.res"))->toEqual(true)
    expect(paths->Array.some(p => p->String.endsWith(".mjs")))->toEqual(false)
    expect(calls.contents->Array.length)->toEqual(2)
  })

  testPromise("a burst spanning two packages emits an unlink per package (A4.1)", async () => {
    // Regression: the old single-`bestPath` debounce clean-rebuilt only one
    // package on a multi-package burst, stranding the other with stale .res.mjs.
    let calls = ref([])
    let fire = Watch.debounce(40, (e, p) => calls := Array.concat(calls.contents, [(e, p)]))
    fire(Watch.Unlink, "/pkgA/src/Foo.res")
    fire(Watch.Unlink, "/pkgB/src/Bar.res")
    await delay(120)
    let paths = calls.contents->Array.map(((_, p)) => p)
    expect(paths->Array.includes("/pkgA/src/Foo.res"))->toEqual(true)
    expect(paths->Array.includes("/pkgB/src/Bar.res"))->toEqual(true)
    expect(calls.contents->Array.length)->toEqual(2)
  })

  testPromise("a structural signal suppresses a co-occurring plain change", async () => {
    // A structural rebuild does its own re-run, so a plain edit in the same
    // window must not also emit a separate Change (which would double-run).
    let calls = ref([])
    let fire = Watch.debounce(40, (e, _p) => calls := Array.concat(calls.contents, [e]))
    fire(Watch.Change, "/p/src/Edited.res")
    fire(Watch.Unlink, "/p/src/old/Moved.res")
    await delay(120)
    expect(calls.contents)->toEqual([Watch.Unlink])
  })

  testPromise("a lone change stays a change (incremental re-run)", async () => {
    let calls = ref([])
    let fire = Watch.debounce(40, (e, _p) => calls := Array.concat(calls.contents, [e]))
    fire(Watch.Change, "/p/src/A.res")
    await delay(120)
    expect(calls.contents)->toEqual([Watch.Change])
  })
})
