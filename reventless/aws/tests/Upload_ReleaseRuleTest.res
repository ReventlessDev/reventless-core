// The release rule as a pure decision — no S3, no AppSync (plan Step 4).
//
// `Upload_Presign_S3_Ops` splits the rule into `scopeCheck` (the string-checkable
// half: authenticated, in-store, owned) and `ageOk` (the clock half), composed by
// `decideRelease`. These tests pin every allow/deny reason so a release that should
// refuse can never silently succeed — the failure mode the plan exists to remove.

open JestGlobals

module Ops = Upload_Presign_S3_Ops

let prefix = "uploads"
let sub = "user-1"
let ownKey = "uploads/user-1/abc/file.png"
let otherKey = "uploads/user-2/abc/file.png"
let outsideKey = "other/user-1/abc/file.png"

let nowMs = 1_000_000.0
let windowMs = 900_000.0 // 15 minutes
let fresh = Some(nowMs -. 1_000.0) // 1s old
let stale = Some(nowMs -. 1_000_000.0) // ~16.6min old, beyond the window

describe("Upload_Presign_S3_Ops.scopeCheck", () => {
  testSync("rejects an empty sub as unauthenticated", () =>
    expect(Ops.scopeCheck(~key=ownKey, ~sub="", ~servedPrefix=prefix))->toEqual(
      Error("unauthenticated"),
    )
  )

  testSync("rejects a key outside the store prefix as not_in_store", () =>
    expect(Ops.scopeCheck(~key=outsideKey, ~sub, ~servedPrefix=prefix))->toEqual(
      Error("not_in_store"),
    )
  )

  testSync("rejects another identity's key as not_yours", () =>
    expect(Ops.scopeCheck(~key=otherKey, ~sub, ~servedPrefix=prefix))->toEqual(Error("not_yours"))
  )

  testSync("allows the caller's own in-store key", () =>
    expect(Ops.scopeCheck(~key=ownKey, ~sub, ~servedPrefix=prefix))->toEqual(Ok())
  )
})

describe("Upload_Presign_S3_Ops.ageOk", () => {
  testSync("treats an absent object as releasable (idempotent)", () =>
    expect(Ops.ageOk(~lastModifiedMs=None, ~nowMs, ~windowMs))->toBe(true)
  )

  testSync("allows an object younger than the window", () =>
    expect(Ops.ageOk(~lastModifiedMs=fresh, ~nowMs, ~windowMs))->toBe(true)
  )

  testSync("refuses an object older than the window", () =>
    expect(Ops.ageOk(~lastModifiedMs=stale, ~nowMs, ~windowMs))->toBe(false)
  )
})

describe("Upload_Presign_S3_Ops.decideRelease", () => {
  let decide = (~key, ~sub, ~lastModifiedMs) =>
    Ops.decideRelease(~key, ~sub, ~servedPrefix=prefix, ~lastModifiedMs, ~nowMs, ~windowMs)

  testSync("releases the caller's own fresh object", () =>
    expect(decide(~key=ownKey, ~sub, ~lastModifiedMs=fresh))->toEqual(Ops.Released)
  )

  testSync("releases an absent object (idempotent retry)", () =>
    expect(decide(~key=ownKey, ~sub, ~lastModifiedMs=None))->toEqual(Ops.Released)
  )

  testSync("refuses another identity's object with not_yours", () =>
    expect(decide(~key=otherKey, ~sub, ~lastModifiedMs=fresh))->toEqual(Ops.Refused("not_yours"))
  )

  testSync("refuses an object older than the window with too_old", () =>
    expect(decide(~key=ownKey, ~sub, ~lastModifiedMs=stale))->toEqual(Ops.Refused("too_old"))
  )

  testSync("refuses a key outside the store with not_in_store", () =>
    expect(decide(~key=outsideKey, ~sub, ~lastModifiedMs=fresh))->toEqual(
      Ops.Refused("not_in_store"),
    )
  )

  testSync("refuses an unauthenticated caller before any age check", () =>
    expect(decide(~key=ownKey, ~sub="", ~lastModifiedMs=stale))->toEqual(
      Ops.Refused("unauthenticated"),
    )
  )
})
