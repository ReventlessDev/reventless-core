open JestGlobals


describe("Identity", () => {
  describe("anonymous", () => {
    testSync("has userId 'anonymous'", () => {
      expect(Reventless.Identity.anonymous.userId)->toBe("anonymous")
    })

    testSync("has empty groups", () => {
      expect(Reventless.Identity.anonymous.groups)->toEqual([])
    })

    testSync("has InMemory provider", () => {
      expect(Reventless.Identity.anonymous.provider)->toEqual(Reventless.Identity.InMemory)
    })
  })

  describe("hasGroup", () => {
    let identity: Reventless.Identity.t = {
      userId: "user-1",
      username: "alice",
      groups: ["admin", "editors"],
      provider: Cognito,
    }

    testSync("returns true when group is present", () => {
      expect(Reventless.Identity.hasGroup(identity, "admin"))->toBe(true)
    })

    testSync("returns false when group is absent", () => {
      expect(Reventless.Identity.hasGroup(identity, "viewers"))->toBe(false)
    })
  })

  describe("getClaim", () => {
    let identity: Reventless.Identity.t = {
      userId: "user-1",
      username: "alice",
      groups: [],
      claims: Dict.fromArray([("tenant", "acme"), ("role", "manager")]),
      provider: InMemory,
    }

    testSync("returns Some for existing claim", () => {
      expect(Reventless.Identity.getClaim(identity, "tenant"))->toEqual(Some("acme"))
    })

    testSync("returns None for missing claim", () => {
      expect(Reventless.Identity.getClaim(identity, "missing"))->toEqual(None)
    })

    testSync("returns None when claims are absent", () => {
      let noClaims: Reventless.Identity.t = {
        userId: "user-2",
        username: "bob",
        groups: [],
        provider: InMemory,
      }
      expect(Reventless.Identity.getClaim(noClaims, "tenant"))->toEqual(None)
    })
  })

  describe("schema roundtrip", () => {
    testSync("encode then decode preserves identity", () => {
      let identity: Reventless.Identity.t = {
        userId: "user-1",
        username: "alice",
        groups: ["admin"],
        claims: Dict.fromArray([("tenant", "acme")]),
        provider: Cognito,
      }
      let json = identity->Reventless.Util_Sury.toJson(Reventless.Identity.schema)
      let decoded = json->Reventless.Util_Sury.fromJson(Reventless.Identity.schema)
      expect(decoded)->toEqual(identity)
    })

    testSync("roundtrip with Custom provider", () => {
      let identity: Reventless.Identity.t = {
        userId: "ext-1",
        username: "external",
        groups: [],
        provider: Custom("oauth2"),
      }
      let json = identity->Reventless.Util_Sury.toJson(Reventless.Identity.schema)
      let decoded = json->Reventless.Util_Sury.fromJson(Reventless.Identity.schema)
      expect(decoded)->toEqual(identity)
    })

    testSync("roundtrip without optional claims", () => {
      let identity: Reventless.Identity.t = {
        userId: "user-3",
        username: "charlie",
        groups: [],
        provider: InMemory,
      }
      let json = identity->Reventless.Util_Sury.toJson(Reventless.Identity.schema)
      let decoded = json->Reventless.Util_Sury.fromJson(Reventless.Identity.schema)
      expect(decoded.userId)->toBe("user-3")->ignore
      expect(decoded.provider)->toEqual(Reventless.Identity.InMemory)
    })
  })
})

describe("RequestContext", () => {
  describe("test() constructor", () => {
    testSync("defaults to anonymous identity", () => {
      let ctx = RequestContext.test()
      expect(ctx.identity.userId)->toBe("anonymous")
    })

    testSync("accepts custom identity", () => {
      let identity: Reventless.Identity.t = {
        userId: "user-1",
        username: "alice",
        groups: ["admin"],
        provider: Cognito,
      }
      let ctx = RequestContext.test(~identity)
      expect(ctx.identity.userId)->toBe("user-1")
    })

    testSync("defaults to empty claims", () => {
      let ctx = RequestContext.test()
      expect(ctx.claims->Dict.keysToArray)->toEqual([])
    })
  })

  describe("getClaim", () => {
    testSync("returns claim value when present", () => {
      let ctx = RequestContext.test(~claims=Dict.fromArray([("tenant", "acme")]))
      expect(RequestContext.getClaim(ctx, "tenant"))->toEqual(Some("acme"))
    })

    testSync("returns None when absent", () => {
      let ctx = RequestContext.test()
      expect(RequestContext.getClaim(ctx, "missing"))->toEqual(None)
    })
  })

  describe("withClaim", () => {
    testSync("adds a claim to the context", () => {
      let ctx = RequestContext.test()
      let updated = RequestContext.withClaim(ctx, "tenant", "acme")
      expect(RequestContext.getClaim(updated, "tenant"))->toEqual(Some("acme"))
    })

    testSync("does not mutate the original context", () => {
      let ctx = RequestContext.test()
      let _updated = RequestContext.withClaim(ctx, "tenant", "acme")
      expect(RequestContext.getClaim(ctx, "tenant"))->toEqual(None)
    })
  })
})
