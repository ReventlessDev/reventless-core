// Tests for Plugin.version / Plugin.compareVersions — the helpers the admin
// manifest resolvers (Platform_ComponentDefinitions / Platform_UIFragments, both
// the AWS Lambda and in-memory paths) use to collapse multiple Connected versions
// of a plugin down to the single newest one. Without correct numeric ordering a
// lingering older version surfaces a full duplicate set of AutoUI menu entries.

open JestGlobals

describe("Plugin.version", () => {
  testSync("extracts the version segment from name@version", () => {
    expect(Plugin.version("Catalog@0.10.0-alpha.73"))->toBe("0.10.0-alpha.73")
  })
  testSync("returns empty string when the id carries no @", () => {
    expect(Plugin.version("Platform"))->toBe("")
  })
})

describe("Plugin.compareVersions", () => {
  testSync("equal versions compare as 0", () => {
    expect(Plugin.compareVersions("0.10.0", "0.10.0"))->toBe(0)
  })
  testSync("higher patch is newer", () => {
    expect(Plugin.compareVersions("0.10.1", "0.10.0"))->toBe(1)
  })
  testSync("lower minor is older", () => {
    expect(Plugin.compareVersions("0.9.0", "0.10.0"))->toBe(-1)
  })
  testSync("orders prerelease counters numerically, not lexically", () => {
    // The case naive string compare gets wrong: "alpha.9" > "alpha.73" lexically,
    // but alpha.73 is the newer build.
    expect(Plugin.compareVersions("0.10.0-alpha.9", "0.10.0-alpha.73"))->toBe(-1)
    expect(Plugin.compareVersions("0.10.0-alpha.73", "0.10.0-alpha.7"))->toBe(1)
  })
})
