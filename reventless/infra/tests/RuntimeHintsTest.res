open JestGlobals

module RH = RuntimeHints

// Precedence for per-component runtime hints (see
// docs/plans/configurable-component-runtime-resources.md): memory is a floor
// (override raises the per-kind default via Math.Int.max, never lowers it),
// timeout is a replace (an explicit value wins outright).

describe("RuntimeHints.resolveMemory", () => {
  testSync("no hint falls through to the per-kind default", () => {
    expect(RH.resolveMemory(None, ~default=1024))->toBe(1024)
  })
  testSync("an override above the default wins", () => {
    expect(RH.resolveMemory(Some({memorySize: 2048}), ~default=1024))->toBe(2048)
  })
  testSync("an override below the default is clamped up to the floor", () => {
    expect(RH.resolveMemory(Some({memorySize: 256}), ~default=1024))->toBe(1024)
  })
  testSync("an absent memorySize field falls through to the default", () => {
    expect(RH.resolveMemory(Some({timeout: 60}), ~default=1024))->toBe(1024)
  })
})

describe("RuntimeHints.resolveTimeout", () => {
  testSync("an explicit timeout replaces the default (no max)", () => {
    expect(RH.resolveTimeout(Some({timeout: 15}), ~default=30))->toBe(15)
  })
  testSync("no hint falls through to the default", () => {
    expect(RH.resolveTimeout(None, ~default=30))->toBe(30)
  })
})
