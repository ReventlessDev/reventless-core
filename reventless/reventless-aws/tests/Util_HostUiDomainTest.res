open TestHelpers

describe("Util_HostUiDomain.deriveFqdn", () => {
  test("non-prod stack keeps the stack suffix", () =>
    expect(
      Util_HostUiDomain.deriveFqdn(
        ~baseName="online-shop-hybrid-platform",
        ~stack="alpha",
        ~baseDomain="app.reventless.dev",
        ~prodStacks=Util_HostUiDomain.defaultProdStacks,
      ),
    )->toBe("online-shop-hybrid-platform-alpha.app.reventless.dev")
  )

  test("default prod stack 'main' drops the stack suffix", () =>
    expect(
      Util_HostUiDomain.deriveFqdn(
        ~baseName="online-shop-hybrid-platform",
        ~stack="main",
        ~baseDomain="app.reventless.dev",
        ~prodStacks=Util_HostUiDomain.defaultProdStacks,
      ),
    )->toBe("online-shop-hybrid-platform.app.reventless.dev")
  )

  test("default prod stack 'prod' drops the stack suffix", () =>
    expect(
      Util_HostUiDomain.deriveFqdn(
        ~baseName="p",
        ~stack="prod",
        ~baseDomain="d",
        ~prodStacks=Util_HostUiDomain.defaultProdStacks,
      ),
    )->toBe("p.d")
  )

  test("custom prod-stack name strips the suffix", () =>
    expect(
      Util_HostUiDomain.deriveFqdn(
        ~baseName="p",
        ~stack="production",
        ~baseDomain="d",
        ~prodStacks=["production"],
      ),
    )->toBe("p.d")
  )

  test("non-prod with default prodStacks keeps the suffix", () =>
    expect(
      Util_HostUiDomain.deriveFqdn(
        ~baseName="p",
        ~stack="alpha",
        ~baseDomain="d",
        ~prodStacks=Util_HostUiDomain.defaultProdStacks,
      ),
    )->toBe("p-alpha.d")
  )

  test("baseName override produces a shorter URL", () =>
    expect(
      Util_HostUiDomain.deriveFqdn(
        ~baseName="online-shop-hybrid",
        ~stack="alpha",
        ~baseDomain="app.reventless.dev",
        ~prodStacks=Util_HostUiDomain.defaultProdStacks,
      ),
    )->toBe("online-shop-hybrid-alpha.app.reventless.dev")
  )
})

describe("Util_HostUiDomain.parseProdStacks", () => {
  test("splits a simple CSV", () =>
    expect(Util_HostUiDomain.parseProdStacks("prod,main"))->toEqual(["prod", "main"])
  )

  test("trims whitespace around entries", () =>
    expect(Util_HostUiDomain.parseProdStacks(" production , live "))->toEqual([
      "production",
      "live",
    ])
  )

  test("drops empty entries from trailing commas", () =>
    expect(Util_HostUiDomain.parseProdStacks("prod,,main,"))->toEqual(["prod", "main"])
  )

  test("single entry without comma", () =>
    expect(Util_HostUiDomain.parseProdStacks("production"))->toEqual(["production"])
  )
})
