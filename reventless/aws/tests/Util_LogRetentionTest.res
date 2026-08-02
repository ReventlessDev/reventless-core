open JestGlobals

let prodStacks = Util_HostUiDomain.defaultProdStacks

describe("Util_LogRetention.retentionDaysFor", () => {
  testSync("prod keeps logs a year", () =>
    expect(Util_LogRetention.retentionDaysFor(~stack="prod", ~prodStacks))->toBe(365)
  )

  testSync("'main' is production too, by the shared prod list", () =>
    expect(Util_LogRetention.retentionDaysFor(~stack="main", ~prodStacks))->toBe(365)
  )

  testSync("beta keeps a month of pre-prod history", () =>
    expect(Util_LogRetention.retentionDaysFor(~stack="beta", ~prodStacks))->toBe(30)
  )

  testSync("a PR stack keeps the minimum — torn down quickly", () =>
    expect(Util_LogRetention.retentionDaysFor(~stack="pr-1234", ~prodStacks))->toBe(3)
  )

  testSync("alpha keeps a week — active development, consumed within hours", () =>
    expect(Util_LogRetention.retentionDaysFor(~stack="alpha", ~prodStacks))->toBe(7)
  )

  // Same fail-open as the store-layout allow-list: an unlisted production name
  // silently gets the dev tier. Asserted so it is a decision on record and the
  // config override is the documented fix.
  testSync("an unlisted stack falls open to the dev tier", () =>
    expect(Util_LogRetention.retentionDaysFor(~stack="production", ~prodStacks))->toBe(7)
  )

  testSync("adding it to the prod list is the fix", () =>
    expect(
      Util_LogRetention.retentionDaysFor(~stack="production", ~prodStacks=["prod", "production"]),
    )->toBe(365)
  )

  // The config key is the escape hatch — a stack dialled without a code change,
  // including `0` (never expire) as an explicit opt-in.
  testSync("a config override wins over the tier default", () =>
    expect(Util_LogRetention.retentionDaysFor(~stack="alpha", ~prodStacks, ~configOverride=14))->toBe(14)
  )

  testSync("0 = never expire is expressible via the override", () =>
    expect(Util_LogRetention.retentionDaysFor(~stack="prod", ~prodStacks, ~configOverride=0))->toBe(0)
  )
})

describe("Util_LogRetention.logLevelFor", () => {
  // Retention and level pull in opposite directions: prod is long-lived AND
  // quiet; the dev stacks are short-lived AND loud.
  testSync("prod is quiet — info, no debug noise or payload leakage", () =>
    expect(Util_LogRetention.logLevelFor(~stack="prod", ~prodStacks))->toBe("info")
  )

  testSync("beta mirrors prod so pre-prod behaves like prod", () =>
    expect(Util_LogRetention.logLevelFor(~stack="beta", ~prodStacks))->toBe("info")
  )

  testSync("alpha is verbose — debug feedback during active development", () =>
    expect(Util_LogRetention.logLevelFor(~stack="alpha", ~prodStacks))->toBe("debug")
  )

  testSync("a PR stack is verbose too", () =>
    expect(Util_LogRetention.logLevelFor(~stack="pr-7", ~prodStacks))->toBe("debug")
  )

  testSync("a config override wins over the tier default", () =>
    expect(
      Util_LogRetention.logLevelFor(~stack="prod", ~prodStacks, ~configOverride="debug"),
    )->toBe("debug")
  )
})

describe("Util_LogRetention.managesLogGroup", () => {
  // Managed for every stack by default — a stack deployed on this framework gets
  // its groups from Pulumi before Lambda/AppSync would auto-create them, so a
  // fresh stack has nothing to adopt.
  testSync("alpha is managed", () =>
    expect(Util_LogRetention.managesLogGroup(~stack="alpha"))->toBe(true)
  )

  testSync("a PR stack is managed", () =>
    expect(Util_LogRetention.managesLogGroup(~stack="pr-42"))->toBe(true)
  )

  testSync("prod is managed too — a fresh prod stack has no group to adopt", () =>
    expect(Util_LogRetention.managesLogGroup(~stack="prod"))->toBe(true)
  )

  testSync("beta is managed too", () =>
    expect(Util_LogRetention.managesLogGroup(~stack="beta"))->toBe(true)
  )

  // The escape hatch: a stack pending a `pulumi import` stays on auto-created
  // groups until the import is done — a config flip, not a code change.
  testSync("a stack named in unmanagedLogGroupStacks is left auto-created", () =>
    expect(
      Util_LogRetention.managesLogGroup(~stack="legacy-prod", ~unmanagedStacks=["legacy-prod"]),
    )->toBe(false)
  )

  testSync("only the named stacks are excluded — others stay managed", () =>
    expect(
      Util_LogRetention.managesLogGroup(~stack="alpha", ~unmanagedStacks=["legacy-prod"]),
    )->toBe(true)
  )
})

describe("Util_LogRetention.parseUnmanagedStacks", () => {
  testSync("empty config manages every stack", () =>
    expect(Util_LogRetention.parseUnmanagedStacks(""))->toEqual([])
  )

  testSync("CSV is trimmed and empty entries dropped", () =>
    expect(Util_LogRetention.parseUnmanagedStacks(" legacy-prod , , old-beta "))->toEqual([
      "legacy-prod",
      "old-beta",
    ])
  )
})
