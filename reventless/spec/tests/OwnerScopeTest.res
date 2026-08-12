open JestGlobals

// The cases that carry weight here are the ones where the ReScript type and the
// runtime value disagree. `Identity.t` declares `userId` and `groups`
// non-optional, and the AppSync templates hand the handler an object that
// sometimes has neither — so a test built only from well-typed record literals
// exercises the half of this module that was never in doubt.
//
// `rawIdentity` therefore builds identities the way the wire does: as untyped
// JS objects cast into position. Two of the cases below cannot be written any
// other way, and they are the two that decide whether a service write lands
// owned by `undefined`.
// `external` rather than a `%raw` lambda: the latter binds a weak type variable
// that the first call site fixes, so the IAM object below — which shares no
// fields with a Cognito one — would not typecheck.
external rawIdentity: 'a => Identity.t = "%identity"

describe("OwnerScope:", () => {

  let cognito = (~userId, ~groups): Identity.t =>
    rawIdentity({"userId": userId, "username": userId, "groups": groups, "provider": "Cognito"})

  // Exactly what `AppSync_Resolver_Functions` emits on the non-Cognito branch:
  // no userId, no groups, and a provider string the variant does not model.
  let iam: Identity.t = rawIdentity({
    "userArn": "arn:aws:sts::1:assumed-role/Ingester",
    "accountId": "1",
    "username": "Ingester",
    "provider": "IAM",
  })

  describe("an ordinary authenticated caller owns their rows:", () => {
    let scope = cognito(~userId="u-1", ~groups=["User"])->OwnerScope.resolve(~elevated=["Admin"])

    testSync("they are classified as an owner", () =>
      expect(scope)->toEqual(OwnerScope.Owned({userId: "u-1"}))
    )
    testSync("their id is what gets stamped and matched", () =>
      expect(OwnerScope.ownerId(scope))->toEqual(Some("u-1"))
    )
    testSync("they are not exempt", () => expect(OwnerScope.isExempt(scope))->toBe(false))
  })

  describe("a caller in an elevated group is exempt:", () => {
    let scope =
      cognito(~userId="u-2", ~groups=["User", "Admin"])->OwnerScope.resolve(~elevated=["Admin"])

    testSync("they are classified as elevated, not as an owner", () =>
      expect(scope)->toEqual(OwnerScope.Elevated({userId: "u-2"}))
    )
    // The property both the stamp and the read predicate key off: an exempt
    // caller contributes no owner value, so neither narrows.
    testSync("they contribute no owner id", () =>
      expect(OwnerScope.ownerId(scope))->toEqual(None)
    )
    testSync("they are exempt", () => expect(OwnerScope.isExempt(scope))->toBe(true))
  })

  // The default. A deployment that configures nothing scopes everyone, which
  // shows an operator too little rather than showing customers each other.
  testSync("with no elevated groups configured, an Admin is still an owner", () =>
    expect(cognito(~userId="u-3", ~groups=["Admin"])->OwnerScope.resolve(~elevated=[]))->toEqual(
      OwnerScope.Owned({userId: "u-3"}),
    )
  )

  describe("the IAM caller — the shape that has no userId at all:", () => {
    let scope = iam->OwnerScope.resolve(~elevated=["Admin"])

    // The failure this module exists to prevent: classified by groups first,
    // an IAM caller has none, so it reads as non-elevated and the write path
    // then stamps `undefined` as the owner. Every service-written row would
    // land owned by nobody, readable by nobody, silently.
    testSync("it is System, not a non-elevated owner", () =>
      expect(scope)->toEqual(OwnerScope.System)
    )
    testSync("it contributes no owner id", () => expect(OwnerScope.ownerId(scope))->toBe(None))
    testSync("it is exempt", () => expect(OwnerScope.isExempt(scope))->toBe(true))
  })

  describe("callers that cannot be identified are refused, not guessed:", () => {
    let reasonOf = scope =>
      switch scope {
      | OwnerScope.Unidentified(why) => Some(why)
      | _ => None
      }

    testSync("an anonymous identity is unidentified", () =>
      expect(Identity.anonymous->OwnerScope.resolve(~elevated=["Admin"])->reasonOf->Option.isSome)->toBe(
        true,
      )
    )

    testSync("a Cognito identity missing its userId is unidentified", () =>
      expect(
        rawIdentity({"username": "x", "groups": [], "provider": "Cognito"})
        ->OwnerScope.resolve(~elevated=[])
        ->reasonOf
        ->Option.isSome,
      )->toBe(true)
    )

    testSync("an empty userId is unidentified", () =>
      expect(
        cognito(~userId="", ~groups=[])->OwnerScope.resolve(~elevated=[])->reasonOf->Option.isSome,
      )->toBe(true)
    )

    // The fail-closed direction, and the reason `systemProviders` is an
    // allowlist. A provider nobody has classified must not inherit the IAM
    // caller's exemption — that would hand unscoped reads to whoever added it.
    testSync("an unrecognised provider is unidentified, NOT System", () => {
      let scope =
        rawIdentity({"userId": "u-9", "username": "u-9", "groups": [], "provider": "Kerberos"})
        ->OwnerScope.resolve(~elevated=[])
      expect((scope->reasonOf->Option.isSome, OwnerScope.isExempt(scope)))->toEqual((true, false))
    })

    testSync("the reason names the offending provider", () =>
      expect(
        rawIdentity({"userId": "u-9", "username": "u-9", "groups": [], "provider": "Kerberos"})
        ->OwnerScope.resolve(~elevated=[])
        ->reasonOf
        ->Option.getOr("")
        ->String.includes("Kerberos"),
      )->toBe(true)
    )

    // Unidentified yields no owner id — which is why a write may not simply ask
    // for the id and carry on. It has to branch on the classification.
    testSync("an unidentified caller contributes no owner id", () =>
      expect(OwnerScope.ownerId(Identity.anonymous->OwnerScope.resolve(~elevated=[])))->toBe(None)
    )

    // Not a well-typed possibility, and an entirely reachable one: an internal
    // caller that assembles a payload without an identity arrives here as
    // `undefined`. Reading through it raises a TypeError, which surfaces as a
    // crash rather than as the refusal this actually is.
    testSync("a wholly absent identity is unidentified, not a crash", () => {
      let absent: Identity.t = %raw(`undefined`)
      expect(absent->OwnerScope.resolve(~elevated=[])->reasonOf->Option.isSome)->toBe(true)
    })
  })

  describe("a Custom provider is a person, not a machine:", () => {
    // `Custom(_)` compiles to an object rather than a bare string, so the
    // string-provider branch never sees it. It must still resolve as a user.
    let scope =
      rawIdentity({
        "userId": "u-4",
        "username": "u-4",
        "groups": ["Admin"],
        "provider": {"TAG": "Custom", "_0": "keycloak"},
      })->OwnerScope.resolve(~elevated=["Admin"])

    testSync("it resolves by group like any other user", () =>
      expect(scope)->toEqual(OwnerScope.Elevated({userId: "u-4"}))
    )
  })

  describe("the configured default is used when no list is passed:", () => {
    testSync("setElevatedGroups changes how an unqualified resolve classifies", () => {
      let identity = cognito(~userId="u-5", ~groups=["Ops"])
      OwnerScope.setElevatedGroups([])
      let before = identity->OwnerScope.resolve
      OwnerScope.setElevatedGroups(["Ops"])
      let after = identity->OwnerScope.resolve
      OwnerScope.setElevatedGroups([])
      expect((before, after))->toEqual((
        OwnerScope.Owned({userId: "u-5"}),
        OwnerScope.Elevated({userId: "u-5"}),
      ))
    })
  })
})
