open JestGlobals

// The words the local platform reads and writes for a closed set, held as
// variants: each reads back as its case and prints as the same word.

describe("LocalPlatformRegistry.storeKind", () => {
  testSync(
    "an entry's store kind decodes, an unknown one is kept, and each encodes as it came",
    () => {
      let words = ["sqlite", "memory", "postgres", "cloud"]
      let decoded =
        words->Array.map(
          w => JSON.String(w)->S.parseOrThrow(~to=LocalPlatformRegistry.storeKindSchema),
        )
      expect(decoded)->toEqual([
        LocalPlatformRegistry.SqliteStore,
        MemoryStore,
        PostgresStore,
        OtherStore("cloud"),
      ])
      expect(
        decoded->Array.map(
          k => k->S.convertOrThrow(~from=LocalPlatformRegistry.storeKindSchema, ~to=S.json),
        ),
      )->toEqual(words->Array.map(w => JSON.String(w)))
    },
  )
})

describe("the log-level readers", () => {
  testSync("a feed filter's level reads in any case, warning included", () =>
    expect(
      ["debug", "INFO", "Warn", "warning", "error", "fatal"]->Array.map(
        w => LocalFeed.levelOfString(w)->Option.map(ReventlessCore.Logger.levelLabel),
      ),
    )->toEqual([Some("DEBUG"), Some("INFO"), Some("WARN"), Some("WARN"), Some("ERROR"), None])
  )

  testSync("the platform API's level is the upper-case word, exactly", () =>
    expect(
      ["DEBUG", "INFO", "WARN", "ERROR", "warn", "WARNING"]->Array.map(
        w => LocalPlatformObserve.levelOfWire(w)->Option.map(ReventlessCore.Logger.levelLabel),
      ),
    )->toEqual([Some("DEBUG"), Some("INFO"), Some("WARN"), Some("ERROR"), None, None])
  )
})
