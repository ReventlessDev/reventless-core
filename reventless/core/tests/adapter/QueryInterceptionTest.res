open JestGlobals

// The seam is a single process-global switch, so what is worth pinning is the
// default (off) and the fact that switching it on does not also register a
// runtime interceptor — the two are deliberately separate decisions, and
// conflating them would provision an interceptor path for a hook nobody set.

module Interception = QueryInterception

describe("QueryInterception", () => {
  testSync("off by default — no registration, nothing provisioned", () => {
    Interception.reset()
    expect(Interception.isEnabled())->toBe(false)
  })

  testSync("use switches it on for the deployment", () => {
    Interception.reset()
    Interception.use()
    expect(Interception.isEnabled())->toBe(true)
    Interception.reset()
  })

  testSync("use is idempotent — an extension may call it more than once", () => {
    Interception.reset()
    Interception.use()
    Interception.use()
    expect(Interception.isEnabled())->toBe(true)
    Interception.reset()
  })

  testSync("reset puts it back, so one test cannot leak into the next", () => {
    Interception.use()
    Interception.reset()
    expect(Interception.isEnabled())->toBe(false)
  })

  // Provisioning the path and registering the hook are separate on purpose: the
  // framework provisions, the extension decides what runs. Asking for
  // interception must not fabricate an interceptor.
  testSync("switching provisioning on does not register a runtime interceptor", () => {
    QueryDb_Callback.clearQueryInterceptor()
    Interception.use()
    expect(QueryDb_Callback.queryInterceptorHook.contents->Option.isNone)->toBe(true)
    Interception.reset()
  })

  testSync("and registering a runtime interceptor does not switch provisioning on", () => {
    Interception.reset()
    QueryDb_Callback.registerQueryInterceptor((~identity as _, ~readModelName as _, ~args as _) =>
      Promise.resolve(QueryDb_Callback.Allow)
    )
    expect(Interception.isEnabled())->toBe(false)
    QueryDb_Callback.clearQueryInterceptor()
  })
})
