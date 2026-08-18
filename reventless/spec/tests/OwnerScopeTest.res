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

  // A deployment is two kinds of process: the one that provisions resolvers and
  // the function runtimes that later stamp and scope. Only the environment
  // reaches both, so a value set in code has to be the override rather than the
  // only channel.
  describe("the elevated list resolves from code, then the environment:", () => {
    let withEnv = (value, fn) => {
      OwnerScope.clearElevatedGroups()
      switch value {
      | Some(v) => NodeProcess.env->Dict.set("REVENTLESS_ELEVATED_GROUPS", v)
      | None => NodeProcess.env->Dict.delete("REVENTLESS_ELEVATED_GROUPS")
      }
      let result = fn()
      NodeProcess.env->Dict.delete("REVENTLESS_ELEVATED_GROUPS")
      OwnerScope.setElevatedGroups([])
      result
    }

    testSync("nothing set anywhere resolves to empty", () =>
      expect(withEnv(None, () => OwnerScope.elevatedGroups()))->toEqual([])
    )

    testSync("the environment is read when no code set a list", () =>
      expect(withEnv(Some("Admin"), () => OwnerScope.elevatedGroups()))->toEqual(["Admin"])
    )

    testSync("a comma-separated list is split and trimmed", () =>
      expect(withEnv(Some("Admin, Support ,Ops"), () => OwnerScope.elevatedGroups()))->toEqual([
        "Admin",
        "Support",
        "Ops",
      ])
    )

    // Trailing separators and stray whitespace are what a hand-edited deploy
    // variable actually looks like; an empty group name would match nobody and
    // silently pad the list.
    testSync("empty entries are dropped rather than kept as blank groups", () =>
      expect(withEnv(Some("Admin,,  ,"), () => OwnerScope.elevatedGroups()))->toEqual(["Admin"])
    )

    testSync("an explicit call wins over the environment", () =>
      expect(
        withEnv(Some("Admin"), () => {
          OwnerScope.setElevatedGroups(["Ops"])
          OwnerScope.elevatedGroups()
        }),
      )->toEqual(["Ops"])
    )

    // Explicitly empty is a decision, not an absence — a root that states "no
    // group is elevated here" must not be overridden by an inherited variable.
    testSync("an explicit empty list wins over the environment", () =>
      expect(
        withEnv(Some("Admin"), () => {
          OwnerScope.setElevatedGroups([])
          OwnerScope.elevatedGroups()
        }),
      )->toEqual([])
    )

    // The end-to-end shape: with only the environment set, a caller in that
    // group is classified exempt without anyone calling a setter.
    testSync("classification honours an environment-only configuration", () =>
      expect(
        withEnv(Some("Admin"), () =>
          cognito(~userId="ops-1", ~groups=["Admin"])->OwnerScope.resolve
        ),
      )->toEqual(OwnerScope.Elevated({userId: "ops-1"}))
    )
  })

  // `@retired` narrows on the same classification `@owner` does, and the two
  // must not be able to disagree about who an operator is. These pin the ways
  // the retirement rule deliberately differs.
  describe("retirement narrowing:", () => {
    let retiredOf = (identity, ~asked=false) =>
      identity
      ->OwnerScope.decideRetired(~retiredField=Some("archived"), ~asked, ~elevated=["Admin"])
      ->OwnerScope.retiredScopeOf
      ->Option.map(scope => scope.OwnerScope.field)

    testSync("a view that declares no retirement flag narrows nothing", () =>
      expect(
        cognito(~userId="u-1", ~groups=[])
        ->OwnerScope.decideRetired(~retiredField=None, ~elevated=["Admin"])
        ->OwnerScope.retiredScopeOf,
      )->toEqual(None)
    )

    testSync("an ordinary caller never sees retired rows", () =>
      expect(retiredOf(cognito(~userId="u-1", ~groups=["User"])))->toEqual(Some("archived"))
    )

    // Elevation buys the ability to ask, not a standing exemption — otherwise
    // the archive is always underfoot for the people who manage it.
    testSync("an elevated caller is excluded too until they ask", () =>
      expect(retiredOf(cognito(~userId="ops-1", ~groups=["Admin"])))->toEqual(Some("archived"))
    )

    testSync("an elevated caller who asks gets them", () =>
      expect(retiredOf(cognito(~userId="ops-1", ~groups=["Admin"]), ~asked=true))->toEqual(None)
    )

    // The request is a request, not the decision. Reading it before classifying
    // would make the argument the whole rule.
    testSync("an ordinary caller asking is ignored, not obeyed", () =>
      expect(retiredOf(cognito(~userId="u-1", ~groups=["User"]), ~asked=true))->toEqual(
        Some("archived"),
      )
    )

    testSync("a system caller may ask", () =>
      expect((retiredOf(iam), retiredOf(iam, ~asked=true)))->toEqual((Some("archived"), None))
    )

    // Where this parts company with `decide`: an owner-scoped read of an
    // unidentified caller is refused because there is no value to match, but
    // retirement has the same predicate for every non-exempt caller, so the
    // fail-closed action is simply the narrow read.
    testSync("an unidentified caller is excluded rather than refused", () =>
      expect(retiredOf(rawIdentity({"provider": "Cognito"})))->toEqual(Some("archived"))
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

// The two forms of `@retired` differ in exactly one place, and this is it. Every
// reader asks `isRetiredValue` rather than branching on the form, so a form that
// answered differently here would answer differently on every door at once.
describe("OwnerScope.isRetiredValue:", () => {

  let boolean: OwnerScope.retiredScope = {field: "archived", values: None}
  let state: OwnerScope.retiredScope = {field: "accountStatus", values: Some(["Deactivated"])}
  // A lifecycle withdrawn by two states. They exclude identically; what differs
  // between them is the way back, which commands express and this does not know.
  let twoStates: OwnerScope.retiredScope = {
    field: "shelfStatus",
    values: Some(["Archived", "Discontinued"]),
  }
  // A state form naming nothing: no state has been declared to withdraw a row,
  // so no row is. Distinct from the boolean form, which is `values: None`.
  let noStates: OwnerScope.retiredScope = {field: "shelfStatus", values: Some([])}

  testSync("the boolean form retires on true", () =>
    expect(boolean->OwnerScope.isRetiredValue(Some(JSON.Encode.bool(true))))->toEqual(true)
  )

  testSync("and keeps the row on false", () =>
    expect(boolean->OwnerScope.isRetiredValue(Some(JSON.Encode.bool(false))))->toEqual(false)
  )

  testSync("the state form retires on the named state", () =>
    expect(state->OwnerScope.isRetiredValue(Some(JSON.Encode.string("Deactivated"))))->toEqual(true)
  )

  testSync("and keeps the row in any other state", () =>
    expect(state->OwnerScope.isRetiredValue(Some(JSON.Encode.string("Active"))))->toEqual(false)
  )

  // Membership, not equality. Both states withdraw the row, and neither is the
  // primary one — a one-member set is the ordinary case, not the only one.
  testSync("every state in the set retires the row", () =>
    expect((
      twoStates->OwnerScope.isRetiredValue(Some(JSON.Encode.string("Archived"))),
      twoStates->OwnerScope.isRetiredValue(Some(JSON.Encode.string("Discontinued"))),
    ))->toEqual((true, true))
  )

  testSync("and a state in neither keeps the row", () =>
    expect(twoStates->OwnerScope.isRetiredValue(Some(JSON.Encode.string("Listed"))))->toEqual(false)
  )

  // The empty case, kept distinct from the boolean form: `values: Some([])` is a
  // state form that names nothing, so it withdraws nothing — where `values: None`
  // would read the same cell as a boolean and retire the row on `true`.
  testSync("a set naming no states retires nothing", () =>
    expect((
      noStates->OwnerScope.isRetiredValue(Some(JSON.Encode.string("Archived"))),
      noStates->OwnerScope.isRetiredValue(Some(JSON.Encode.bool(true))),
    ))->toEqual((false, false))
  )

  // The mirror image of the owner rule, landing the opposite way on purpose: an
  // owner-scoped read excludes a row that states no owner, because such a row
  // belongs to nobody in particular. A retirement read keeps a row that states
  // nothing, because absent means not retired — which is what every row written
  // before the annotation is. Excluding those would empty the view the day it
  // lands, on both forms alike.
  testSync("an absent field keeps the row, on the boolean form", () =>
    expect(boolean->OwnerScope.isRetiredValue(None))->toEqual(false)
  )

  testSync("and on the state form", () =>
    expect(state->OwnerScope.isRetiredValue(None))->toEqual(false)
  )

  // A value of the wrong shape is not the retirement value, so the row stays.
  // The alternative — treating "cannot read this" as retired — would hide rows
  // on a decoding accident.
  testSync("a value of the wrong shape is not the retired one", () =>
    expect((
      boolean->OwnerScope.isRetiredValue(Some(JSON.Encode.string("true"))),
      state->OwnerScope.isRetiredValue(Some(JSON.Encode.bool(true))),
    ))->toEqual((false, false))
  )
})
