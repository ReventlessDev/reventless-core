open JestGlobals

// The local stash's two promises: a value is handed over once, and a value
// nobody takes is gone after its time. Time is moved, not waited for.

let clock = () => {
  let at = ref(1_000_000.)
  (() => at.contents, seconds => at := at.contents +. seconds *. 1000.)
}

describe("Stash_Memory_Backend", () => {
  testPromise("hands a value over once", async () => {
    let (now, _) = clock()
    let stash = Stash_Memory_Backend.make(~now)
    expect(await stash.put(~key="k", ~value="secret", ~ttl=60))->toEqual(Ok())
    expect(await stash.take(~key="k"))->toEqual(Ok(Some("secret")))
    expect(await stash.take(~key="k"))->toEqual(Ok(None))
  })

  testPromise("a value past its time is gone", async () => {
    let (now, advance) = clock()
    let stash = Stash_Memory_Backend.make(~now)
    let _ = await stash.put(~key="k", ~value="secret", ~ttl=60)
    advance(61.)
    expect(await stash.take(~key="k"))->toEqual(Ok(None))
  })

  testPromise("a value within its time is still there", async () => {
    let (now, advance) = clock()
    let stash = Stash_Memory_Backend.make(~now)
    let _ = await stash.put(~key="k", ~value="secret", ~ttl=60)
    advance(59.)
    expect(await stash.take(~key="k"))->toEqual(Ok(Some("secret")))
  })

  // The newer request is the one in flight: a person who submits the form twice
  // means the second password.
  testPromise("a second put under one key replaces the first", async () => {
    let (now, _) = clock()
    let stash = Stash_Memory_Backend.make(~now)
    let _ = await stash.put(~key="k", ~value="first", ~ttl=60)
    let _ = await stash.put(~key="k", ~value="second", ~ttl=60)
    expect(await stash.take(~key="k"))->toEqual(Ok(Some("second")))
  })

  testPromise("two stashes share nothing", async () => {
    let (now, _) = clock()
    let a = Stash_Memory_Backend.make(~now)
    let b = Stash_Memory_Backend.make(~now)
    let _ = await a.put(~key="k", ~value="secret", ~ttl=60)
    expect(await b.take(~key="k"))->toEqual(Ok(None))
  })

  testPromise("a platform with none refuses both operations", async () => {
    let none = Reventless.Capabilities.none.stash
    expect(await none.put(~key="k", ~value="v", ~ttl=60))->toEqual(
      Error(Reventless.Stash.Unavailable("no stash is configured for this platform")),
    )
    expect(await none.take(~key="k"))->toEqual(
      Error(Reventless.Stash.Unavailable("no stash is configured for this platform")),
    )
  })
})
