open JestGlobals

describe("Basic test", () => {
  testSync("1 + 1 = 2", () => {
    expect(1 + 1)->toBe(2)
  })
})
