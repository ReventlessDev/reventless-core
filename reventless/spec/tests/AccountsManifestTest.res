open JestGlobals

// The manifest's write-back, which is the part of provisioning with no precedent
// in this repo: it mutates a file a human also edits. The happy path is the least
// interesting thing here — what is tested is what a *second* run does, and what
// survives a rewrite.

let manifest = `# The cast, and why fulfil is elevated.
#
# THESE ARE THROWAWAY DEV CREDENTIALS.

- username: admin
  password: ""
  groups: [Admin, Shopper]

- username: shopper
  password: keep-me
  groups: [Shopper]
  userId: already-known
`

describe("AccountsManifest.parseString", () => {
  testSync("reads the entries a manifest declares", () =>
    expect(AccountsManifest.parseString(manifest))->toEqual(
      Ok([
        {AccountsManifest.username: "admin", password: "", groups: ["Admin", "Shopper"]},
        {
          AccountsManifest.username: "shopper",
          password: "keep-me",
          groups: ["Shopper"],
          userId: "already-known",
        },
      ]),
    )
  )

  // Strict rather than lenient, and deliberately unlike the seed harness's own
  // reader: on both platforms a silently dropped account reads as a login that
  // stopped working for no stated reason.
  testSync("refuses the whole file rather than skipping a malformed entry", () =>
    expect(AccountsManifest.parseString("- username: admin\n")->Result.isError)->toBe(true)
  )
})

describe("AccountsManifest.applyFills", () => {
  let fill = (~index, ~password=?, ~userId=?) => {
    AccountsManifest.index,
    password,
    userId,
  }

  // The reason the rewrite goes through `parseDocument` rather than
  // re-serializing the parsed entries. Both manifests carry more explanation
  // than data, and a tool that quietly deleted it would cost more than it saved.
  testSync("keeps every comment the file carries", () => {
    switch AccountsManifest.applyFills(manifest, [fill(~index=0, ~password="minted")]) {
    | Error(message) => fail(message)
    | Ok((rewritten, _)) =>
      expect(rewritten->String.includes("# The cast, and why fulfil is elevated."))->toBe(true)
      expect(rewritten->String.includes("# THESE ARE THROWAWAY DEV CREDENTIALS."))->toBe(true)
    }
  })

  testSync("writes a generated password into an empty field", () => {
    switch AccountsManifest.applyFills(manifest, [fill(~index=0, ~password="minted")]) {
    | Error(message) => fail(message)
    | Ok((rewritten, report)) =>
      expect(report->Array.getUnsafe(0))->toEqual({
        AccountsManifest.index: 0,
        passwordWritten: true,
        userIdWritten: false,
      })
      expect(AccountsManifest.parseString(rewritten))->toEqual(
        Ok([
          {AccountsManifest.username: "admin", password: "minted", groups: ["Admin", "Shopper"]},
          {
            AccountsManifest.username: "shopper",
            password: "keep-me",
            groups: ["Shopper"],
            userId: "already-known",
          },
        ]),
      )
    }
  })

  // 🚨 The failure this whole rule exists for. A second run is the normal case —
  // an operator adding one account to four — and the obvious implementation
  // replaces a credential somebody is currently signed in with.
  testSync("never replaces a password already in the file", () => {
    switch AccountsManifest.applyFills(manifest, [fill(~index=1, ~password="clobber")]) {
    | Error(message) => fail(message)
    | Ok((rewritten, report)) =>
      expect((report->Array.getUnsafe(0)).passwordWritten)->toBe(false)
      expect(rewritten->String.includes("clobber"))->toBe(false)
      expect(rewritten->String.includes("keep-me"))->toBe(true)
    }
  })

  // Whitespace is not a password. An operator who cleared the field left it
  // empty, and a run that read `"  "` as somebody's choice would strand them.
  testSync("treats a whitespace-only password as empty", () => {
    let blanked = manifest->String.replace(`password: ""`, `password: "   "`)
    switch AccountsManifest.applyFills(blanked, [fill(~index=0, ~password="minted")]) {
    | Error(message) => fail(message)
    | Ok((_, report)) => expect((report->Array.getUnsafe(0)).passwordWritten)->toBe(true)
    }
  })

  // Unlike the password, the pool is authoritative for the id: it mints the sub
  // and the file is only ever a copy, so a stale one is corrected rather than
  // preserved. A stale `userId` keys the demo's rows to somebody nobody holds.
  testSync("adds a userId that is missing and corrects one that is stale", () => {
    switch AccountsManifest.applyFills(
      manifest,
      [fill(~index=0, ~userId="minted-sub"), fill(~index=1, ~userId="corrected-sub")],
    ) {
    | Error(message) => fail(message)
    | Ok((rewritten, report)) =>
      expect(report->Array.map(r => r.userIdWritten))->toEqual([true, true])
      switch AccountsManifest.parseString(rewritten) {
      | Error(message) => fail(message)
      | Ok(entries) =>
        expect(entries->Array.map(e => e.userId))->toEqual([
          Some("minted-sub"),
          Some("corrected-sub"),
        ])
      }
    }
  })

  // What makes a second run visibly a no-op rather than merely a harmless one.
  testSync("reports nothing written when every field is already answered", () =>
    switch AccountsManifest.applyFills(
      manifest,
      [fill(~index=1, ~password="clobber", ~userId="already-known")],
    ) {
    | Error(message) => fail(message)
    | Ok((_, report)) =>
      expect(report->Array.getUnsafe(0))->toEqual({
        AccountsManifest.index: 1,
        passwordWritten: false,
        userIdWritten: false,
      })
    }
  )
})
