// Which refusal an admin-gated field gives, and why the two are not one.
//
// A group check has two ways to say no, and for a long time it said them with
// one code. A caller the server identified who does not hold the group, a
// caller whose token did not verify, and a caller who presented nothing at all
// all read `UNAUTHORIZED` — so the answer a client can draw from a refusal is
// the same in a case where presenting credentials again fixes it and a case
// where it never will.
//
// Clients resolve that by guessing, and the guess that fits an expired token is
// to discard the session. Applied to a caller who simply lacks the group, it
// ends a session that is working perfectly — and on a platform whose discovery
// surfaces are all admin-gated, every non-admin caller meets this refusal as a
// matter of course.
//
// `FORBIDDEN` is the fact that removes the guess: the caller is known, and the
// answer will not change if they authenticate again.

open JestGlobals

let identity = (~groups): Reventless.Identity.t => {
  userId: "u-1",
  username: "u",
  groups,
  provider: InMemory,
}

// The context shape `buildAuthContext` writes. Built here rather than driven
// through a server so the two axes — holds the group, and was authenticated —
// can be set independently, including the combination a real request cannot
// produce but a malformed context can.
let context = (~groups, ~authenticated): JSON.t =>
  Obj.magic({"identity": identity(~groups), "authenticated": authenticated})

let ok: GraphqlYoga.resolverFn = async (_root, _args, _ctx) => JSON.Encode.string("ran")

// The thrown value is a `GraphQLError`, but a ReScript `catch` hands back its
// own exception wrapper — so it is unwrapped before the message and extensions
// are read off the raw object. No decoder: that shape is the contract this file
// is about, and describing it through one would test the decoder instead.
let describeRefusal = (e: exn): (string, string) =>
  switch e->JsExn.fromException {
  | None => ("not a JavaScript error", "")
  | Some(js) => (js->JsExn.message->Option.getOr(""), (js->Obj.magic)["extensions"]["code"])
  }

let refusalOf = async (~groups, ~authenticated): result<JSON.t, (string, string)> => {
  let guarded = Auth_GraphqlContext.requireGroup(~group="Admin", ok)
  try {
    Ok(await guarded(JSON.Encode.null, JSON.Encode.null, context(~groups, ~authenticated)))
  } catch {
  | e => Error(describeRefusal(e))
  }
}

describe("requireGroup", () => {
  testPromise("runs the resolver for a caller holding the group", async () => {
    let outcome = await refusalOf(~groups=["Admin"], ~authenticated=true)
    expect(outcome)->toEqual(Ok(JSON.Encode.string("ran")))
  })

  // The case that ended working sessions: a real caller, a real token, and a
  // group they do not hold. Nothing about signing in again changes it.
  testPromise("refuses an identified caller without the group as FORBIDDEN", async () => {
    let outcome = await refusalOf(~groups=["Shopper"], ~authenticated=true)
    expect(outcome)->toEqual(Error(("Forbidden: requires group \"Admin\"", "FORBIDDEN")))
  })

  // Unchanged, deliberately. A client reading only `UNAUTHORIZED` already treats
  // it as "your credentials are not being honoured", and confining the code to
  // the case where that holds makes such a client right rather than broken.
  testPromise("refuses a caller it could not identify as UNAUTHORIZED", async () => {
    let outcome = await refusalOf(~groups=[], ~authenticated=false)
    expect(outcome)->toEqual(Error(("Unauthorized: requires group \"Admin\"", "UNAUTHORIZED")))
  })

  // A context without the key proves nothing about the caller, so it takes the
  // reading that asks for credentials rather than the one that says theirs were
  // read and found wanting.
  testPromise("reads a context missing the outcome as unidentified", async () => {
    let guarded = Auth_GraphqlContext.requireGroup(~group="Admin", ok)
    let legacyContext: JSON.t = Obj.magic({"identity": identity(~groups=["Shopper"])})
    let code = try {
      let _ = await guarded(JSON.Encode.null, JSON.Encode.null, legacyContext)
      "no refusal"
    } catch {
    | e => describeRefusal(e)->Pair.second
    }
    expect(code)->toBe("UNAUTHORIZED")
  })
})

describe("isAuthenticated", () => {
  testSync("a verified caller is authenticated", () =>
    expect(Auth_GraphqlContext.isAuthenticated(Authenticated(identity(~groups=[]))))->toBe(true)
  )

  // The distinction `identityFromAuthResult` loses: both of these become the
  // anonymous identity, and only one of them means credentials were rejected.
  testSync("a rejected token is not", () =>
    expect(Auth_GraphqlContext.isAuthenticated(AuthError("Invalid bearer token")))->toBe(false)
  )

  testSync("nor is an anonymous caller", () =>
    expect(Auth_GraphqlContext.isAuthenticated(Anonymous))->toBe(false)
  )
})
