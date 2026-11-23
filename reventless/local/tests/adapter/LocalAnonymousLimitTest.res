open JestGlobals

// The local doors' limit, as the resolvers apply it: only a rule that admits
// anonymous callers is counted, and the answer is a `Throttled` rejection.

@set_index external setEnv: (dict<string>, string, string) => unit = ""

let ctxFrom = (address: string): JSON.t =>
  JSON.Encode.object(Dict.fromArray([("sourceAddress", JSON.Encode.string(address))]))

let throttled = (~rule, ~ctx) =>
  CommandGeneratorResolvers_GraphQL.throttled(~rule, ~field="Registration_SignUp", ~ctx)

describe("the limit on anonymous doors", () => {
  beforeEach(() => {
    NodeProcess.env->setEnv(Reventless.AnonymousRequestLimit.envKey, "2/3600")
    LocalAnonymousLimit.reset()
  })
  afterEach(() => {
    NodeProcess.env->Dict.delete(Reventless.AnonymousRequestLimit.envKey)
    LocalAnonymousLimit.reset()
  })

  testSync("an anonymous door is limited per source address", () => {
    let ctx = ctxFrom("10.0.0.1")
    let answers = [
      throttled(~rule=AllowAnonymous, ~ctx)->Option.isSome,
      throttled(~rule=AllowAnonymous, ~ctx)->Option.isSome,
      throttled(~rule=AllowAnonymous, ~ctx)->Option.isSome,
    ]
    expect(answers)->toEqual([false, false, true])
  })

  testSync("another source is not held back by the first", () => {
    let _ = throttled(~rule=AllowAnonymous, ~ctx=ctxFrom("10.0.0.1"))
    let _ = throttled(~rule=AllowAnonymous, ~ctx=ctxFrom("10.0.0.1"))
    expect(throttled(~rule=AllowAnonymous, ~ctx=ctxFrom("10.0.0.2"))->Option.isSome)->toBe(false)
  })

  testSync("a door for signed-in callers is never counted", () => {
    let ctx = ctxFrom("10.0.0.1")
    let answers = Array.fromInitializer(
      ~length=5,
      _ => throttled(~rule=AllowAuthenticated, ~ctx)->Option.isSome,
    )
    expect(answers->Array.some(x => x))->toBe(false)
  })

  testSync("the refusal is a Throttled rejection, retryable by its cause", () => {
    let ctx = ctxFrom("10.0.0.1")
    let _ = throttled(~rule=AllowAnonymous, ~ctx)
    let _ = throttled(~rule=AllowAnonymous, ~ctx)
    let rejection = throttled(~rule=AllowAnonymous, ~ctx)->Option.getOr(JSON.Encode.null)
    let text = rejection->JSON.stringify
    expect((text->String.includes("Throttled"), text->String.includes("INFRASTRUCTURE")))->toEqual((
      true,
      true,
    ))
  })

  testSync("a view is counted under its own limit, not the doors'", () => {
    NodeProcess.env->setEnv(Reventless.AnonymousRequestLimit.viewEnvKey, "4/3600")
    LocalAnonymousLimit.reset()
    let view = () => LocalAnonymousLimit.admit(~kind=View, ~door="Windows", ~source="10.0.0.1")
    let _ = throttled(~rule=AllowAnonymous, ~ctx=ctxFrom("10.0.0.1"))
    let _ = throttled(~rule=AllowAnonymous, ~ctx=ctxFrom("10.0.0.1"))
    let doorSpent = throttled(~rule=AllowAnonymous, ~ctx=ctxFrom("10.0.0.1"))->Option.isSome
    let views = Array.fromInitializer(~length=5, _ => view())
    NodeProcess.env->Dict.delete(Reventless.AnonymousRequestLimit.viewEnvKey)
    expect((doorSpent, views))->toEqual((true, [true, true, true, true, false]))
  })

  testSync("a view's limit defaults to 300 an hour where none is set", () => {
    NodeProcess.env->Dict.delete(Reventless.AnonymousRequestLimit.viewEnvKey)
    LocalAnonymousLimit.reset()
    expect(LocalAnonymousLimit.configured(~kind=View))->toEqual({
      Reventless.AnonymousRequestLimit.requests: 300,
      windowSeconds: 3600,
    })
  })

  testSync("a mistyped limit fails rather than becoming the default", () => {
    NodeProcess.env->setEnv(Reventless.AnonymousRequestLimit.envKey, "ten")
    LocalAnonymousLimit.reset()
    let threw = switch throttled(~rule=AllowAnonymous, ~ctx=ctxFrom("10.0.0.1")) {
    | _ => false
    | exception _ => true
    }
    expect(threw)->toBe(true)
  })
})
