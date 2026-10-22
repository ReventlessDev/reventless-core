open JestGlobals

// The Cognito identity provider's sequencing, against fake pool calls: what is
// undone when a later step fails, which failures are verdicts, and that a new
// principal's domain id is minted into the store. The SDK calls themselves are
// one line each and are exercised by a deployed stack.

module Backend = IdentityProvider_Cognito_Backend
module IP = Reventless.IdentityProvider

@new external makeAwsError: string => exn = "Error"
@set external setName: (exn, string) => unit = "name"

let awsError = (code: string): exn => {
  let e = makeAwsError(`${code}: from the fake pool`)
  e->setName(code)
  e
}

type pool = {
  users: dict<(string, array<string>)>,
  rows: dict<string>,
  calls: array<string>,
}

let fakeOps = (~pool: pool, ~failOn: option<(string, string)>=?): Backend.ops => {
  let fail = step =>
    switch failOn {
    | Some((at, code)) if at == step => throw(awsError(code))
    | _ => ()
    }
  let record = step => {
    let _ = pool.calls->Array.push(step)
    fail(step)
  }
  {
    createUser: async (~username, ~attributes as _) => {
      record("createUser")
      if pool.users->Dict.has(username) {
        throw(awsError("UsernameExistsException"))
      }
      let sub = `sub-${username}`
      pool.users->Dict.set(username, (sub, []))
      Some(sub)
    },
    subOf: async (~username) => {
      record("subOf")
      switch pool.users->Dict.get(username) {
      | Some((sub, _)) => Some(sub)
      | None => throw(awsError("UserNotFoundException"))
      }
    },
    setPassword: async (~username as _, ~password as _) => record("setPassword"),
    addToGroup: async (~username, ~group) => {
      record("addToGroup")
      switch pool.users->Dict.get(username) {
      | Some((sub, groups)) => pool.users->Dict.set(username, (sub, Array.concat(groups, [group])))
      | None => throw(awsError("UserNotFoundException"))
      }
    },
    removeFromGroup: async (~username, ~group) => {
      record("removeFromGroup")
      switch pool.users->Dict.get(username) {
      | Some((sub, groups)) =>
        pool.users->Dict.set(username, (sub, groups->Array.filter(g => g != group)))
      | None => throw(awsError("UserNotFoundException"))
      }
    },
    deleteUser: async (~username) => {
      record("deleteUser")
      if !(pool.users->Dict.has(username)) {
        throw(awsError("UserNotFoundException"))
      }
      pool.users->Dict.delete(username)
    },
    putUserId: async (~sub, ~userId) => {
      record("putUserId")
      pool.rows->Dict.set(sub, userId)
    },
    deleteUserId: async (~sub) => {
      record("deleteUserId")
      pool.rows->Dict.delete(sub)
    },
  }
}

let emptyPool = () => {users: Dict.make(), rows: Dict.make(), calls: []}
let email = address => Reventless.Messaging.ToEmail(Reventless.Email.unsafe(address))

describe("IdentityProvider_Cognito_Backend", () => {
  testPromise("creates the principal, sets its password and groups, and mints its id", async () => {
    let pool = emptyPool()
    let provider = Backend.withOps(fakeOps(~pool), ~hasStore=true)
    let answer = await provider.createPrincipal(
      ~contact=email("new@example.com"),
      ~credential=Password("pw"),
      ~groups=["Shopper"],
    )
    expect(answer)->toEqual(Ok({IP.providerId: "new@example.com"}))
    expect(pool.users->Dict.get("new@example.com"))->toEqual(
      Some(("sub-new@example.com", ["Shopper"])),
    )
    expect(
      pool.rows->Dict.get("sub-new@example.com")->Option.map(ReventlessCore.Auth_UserId.isMinted),
    )->toEqual(Some(true))
  })

  testPromise("an existing account is a Conflict, not an outage", async () => {
    let pool = emptyPool()
    let provider = Backend.withOps(fakeOps(~pool), ~hasStore=true)
    let create = () =>
      provider.createPrincipal(
        ~contact=email("twice@example.com"),
        ~credential=NoCredential,
        ~groups=[],
      )
    let _ = await create()
    expect(await create())->toEqual(Error(IP.Conflict))
  })

  // The case the undo exists for: left in place, the retry would meet the
  // account and answer Conflict to someone whose first attempt timed out.
  testPromise("a later step failing undoes the account, so a retry starts clean", async () => {
    let pool = emptyPool()
    let failing = Backend.withOps(
      fakeOps(~pool, ~failOn=("addToGroup", "TooManyRequestsException")),
      ~hasStore=true,
    )
    let first = await failing.createPrincipal(
      ~contact=email("retry@example.com"),
      ~credential=Password("pw"),
      ~groups=["Shopper"],
    )
    expect(
      switch first {
      | Error(Unavailable(_)) => true
      | _ => false
      },
    )->toBe(true)
    expect(pool.users->Dict.has("retry@example.com"))->toBe(false)
    expect(pool.rows->Dict.keysToArray)->toEqual([])

    let healthy = Backend.withOps(fakeOps(~pool), ~hasStore=true)
    let second = await healthy.createPrincipal(
      ~contact=email("retry@example.com"),
      ~credential=Password("pw"),
      ~groups=["Shopper"],
    )
    expect(second)->toEqual(Ok({IP.providerId: "retry@example.com"}))
  })

  testPromise("a password the pool's policy rejects is Refused, and undone", async () => {
    let pool = emptyPool()
    let provider = Backend.withOps(
      fakeOps(~pool, ~failOn=("setPassword", "InvalidPasswordException")),
      ~hasStore=true,
    )
    let answer = await provider.createPrincipal(
      ~contact=email("weak@example.com"),
      ~credential=Password("1"),
      ~groups=[],
    )
    expect(
      switch answer {
      | Error(Refused(_)) => true
      | _ => false
      },
    )->toBe(true)
    expect(pool.users->Dict.has("weak@example.com"))->toBe(false)
  })

  testPromise("NoCredential sets no password", async () => {
    let pool = emptyPool()
    let provider = Backend.withOps(fakeOps(~pool), ~hasStore=true)
    let _ = await provider.createPrincipal(
      ~contact=email("later@example.com"),
      ~credential=NoCredential,
      ~groups=[],
    )
    expect(pool.calls->Array.includes("setPassword"))->toBe(false)
  })

  // A pool provisioned before the identity store: principals are still made,
  // and each keeps its `sub` as its id, as every account before the store did.
  testPromise("without a store, no id is minted", async () => {
    let pool = emptyPool()
    let provider = Backend.withOps(fakeOps(~pool), ~hasStore=false)
    let _ = await provider.createPrincipal(
      ~contact=email("old@example.com"),
      ~credential=NoCredential,
      ~groups=[],
    )
    expect(pool.calls->Array.includes("putUserId"))->toBe(false)
    expect(pool.users->Dict.has("old@example.com"))->toBe(true)
  })

  testPromise("a push address is refused before the pool is asked", async () => {
    let pool = emptyPool()
    let provider = Backend.withOps(fakeOps(~pool), ~hasStore=true)
    let answer = await provider.createPrincipal(
      ~contact=ToPush(Fcm({registrationToken: "tok"})),
      ~credential=NoCredential,
      ~groups=[],
    )
    expect(
      switch answer {
      | Error(Refused(_)) => true
      | _ => false
      },
    )->toBe(true)
    expect(pool.calls)->toEqual([])
  })

  testPromise("groups change on the pool, and an unknown principal is Refused", async () => {
    let pool = emptyPool()
    let provider = Backend.withOps(fakeOps(~pool), ~hasStore=true)
    let principal: IP.principal = {providerId: "grp@example.com"}
    let _ = await provider.createPrincipal(
      ~contact=email("grp@example.com"),
      ~credential=NoCredential,
      ~groups=["Shopper"],
    )
    expect(await provider.addToGroup(~principal, ~group="Reviewer"))->toEqual(Ok())
    expect(await provider.removeFromGroup(~principal, ~group="Shopper"))->toEqual(Ok())
    expect(pool.users->Dict.get("grp@example.com"))->toEqual(
      Some(("sub-grp@example.com", ["Reviewer"])),
    )
    expect(
      switch await provider.addToGroup(~principal={providerId: "ghost"}, ~group="Shopper") {
      | Error(Refused(_)) => true
      | _ => false
      },
    )->toBe(true)
  })

  testPromise("deleting removes the account and its row, and a second delete is Ok", async () => {
    let pool = emptyPool()
    let provider = Backend.withOps(fakeOps(~pool), ~hasStore=true)
    let principal: IP.principal = {providerId: "gone@example.com"}
    let _ = await provider.createPrincipal(
      ~contact=email("gone@example.com"),
      ~credential=NoCredential,
      ~groups=[],
    )
    expect(await provider.deletePrincipal(~principal))->toEqual(Ok())
    expect(pool.users->Dict.has("gone@example.com"))->toBe(false)
    expect(pool.rows->Dict.has("sub-gone@example.com"))->toBe(false)
    expect(await provider.deletePrincipal(~principal))->toEqual(Ok())
  })

  testPromise("an outage while deleting is retried, not reported as done", async () => {
    let pool = emptyPool()
    let _ = await Backend.withOps(fakeOps(~pool), ~hasStore=true).createPrincipal(
      ~contact=email("busy@example.com"),
      ~credential=NoCredential,
      ~groups=[],
    )
    let failing = Backend.withOps(
      fakeOps(~pool, ~failOn=("deleteUser", "TooManyRequestsException")),
      ~hasStore=true,
    )
    expect(
      switch await failing.deletePrincipal(~principal={providerId: "busy@example.com"}) {
      | Error(Unavailable(_)) => true
      | _ => false
      },
    )->toBe(true)
    expect(pool.users->Dict.has("busy@example.com"))->toBe(true)
  })

  testSync("no pool configured answers Unavailable with no operations", () =>
    expect(Backend.provider(~poolId="", ~identityStore="").operations)->toEqual([])
  )

  testSync("a configured pool publishes all four operations", () =>
    expect(Backend.provider(~poolId="eu-west-1_X", ~identityStore="t").operations)->toEqual([
      IP.CreatePrincipal,
      AddToGroup,
      RemoveFromGroup,
      DeletePrincipal,
    ])
  )
})

describe("AutomationSliceRuntime_Builder_Single.declaresIdentityProvider", () => {
  let info = (needs): AutomationSliceRuntime_Builder_Single.sliceInfo => {
    specModulePath: "",
    bodyModulePath: "",
    callbackType: "outbound",
    queryDbTableName: Pulumi.Output.make(""),
    queryDbResources: [],
    context: None,
    sourceTopics: Dict.make(),
    consumesDcbLog: true,
    commandTargetName: None,
    schedule: None,
    schedulesResources: [],
    capabilityNeeds: needs,
  }

  // The grant that can create and delete accounts follows a declaration, not
  // the pool merely existing, which on AWS it always does.
  testSync("only a slice declaring the need earns the grant", () => {
    expect(
      AutomationSliceRuntime_Builder_Single.declaresIdentityProvider([info([Messaging]), info([])]),
    )->toBe(false)
    expect(
      AutomationSliceRuntime_Builder_Single.declaresIdentityProvider([
        info([Messaging]),
        info([IdentityProvider]),
      ]),
    )->toBe(true)
  })
})
