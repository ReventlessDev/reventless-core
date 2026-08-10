// The read-path interceptor runtime: its contract, and the cold-start seam it
// depends on for that contract to mean anything.
//
// The hook this handler consults is a module-level `ref`, and in a deployed
// runtime only a `RuntimeExtension`'s `onColdStart` ever fills it. This runtime
// is not built by a compiled entry shell, so it awaits `runtimeExtensionsReady`
// itself — and the failure mode when it does not is silent by construction: the
// hook reads `None`, every read is allowed, and interception costs a full Lambda
// invocation per read while observing nothing. Nothing errors, so only a test
// says so.

open JestGlobals
open ReventlessCore

// Both names must resolve to the SAME promise. HandlerFactoryHelpers re-exports
// this binding rather than defining its own precisely so the seam fires once per
// process; a second definition would fire every registered extension's
// `onColdStart` twice in any runtime that reached both modules.
@module("../src/adapter/Runtime/RuntimeExtensionsReady.mjs")
external readyFromOwnModule: promise<unit> = "runtimeExtensionsReady"

@module("../src/adapter/Runtime/HandlerFactoryHelpers.mjs")
external readyFromHelpers: promise<unit> = "runtimeExtensionsReady"

let identity: Reventless.Identity.t = {
  userId: "anonymous",
  username: "anonymous",
  groups: [],
  provider: InMemory,
}

let read = (~readModelName="Product"): QueryInterceptor_Lambda.payload => {
  readModelName,
  arguments: JSON.Null,
  identity,
}

// The handler ignores it; Lambda supplies the real one.
let context: PulumiAws.Lambda.context = %raw(`{}`)

describe("cold-start seam", () => {
  test("one seam, one promise — the helpers re-export is not a second copy", async () => {
    expect(readyFromHelpers === readyFromOwnModule)->toBe(true)
  })
})

describe("interceptor handler", () => {
  beforeEach(() => QueryDb_Callback.clearQueryInterceptor())

  testPromise("no registered hook passes the read through", async () => {
    let allowed = await QueryInterceptor_Lambda.handler(read(), context)
    expect(allowed)->toBe(true)
  })

  testPromise("an allowing hook is consulted and the read proceeds", async () => {
    let seen = ref([])
    QueryDb_Callback.registerQueryInterceptor(async (
      ~identity as _,
      ~readModelName,
      ~args as _,
    ) => {
      seen := seen.contents->Array.concat([readModelName])
      QueryDb_Callback.Allow
    })
    let allowed = await QueryInterceptor_Lambda.handler(read(~readModelName="Order"), context)
    expect((allowed, seen.contents))->toEqual((true, ["Order"]))
  })

  testPromise("a denying hook fails the read with the hook's own message", async () => {
    // The refusal has to surface as a thrown error: the pipeline's response
    // function turns `ctx.error` into a GraphQL field error, and a returned
    // `false` would read as a successful read of nothing.
    QueryDb_Callback.registerQueryInterceptor(async (
      ~identity as _,
      ~readModelName as _,
      ~args as _,
    ) => QueryDb_Callback.Deny("over the allowance"))
    let message = try {
      let _ = await QueryInterceptor_Lambda.handler(read(), context)
      "did not throw"
    } catch {
    | JsExn(e) => e->JsExn.message->Option.getOr("no message")
    | _ => "not a JS error"
    }
    expect(message)->Expect.toBe("over the allowance")
  })
})
