// Guards the deploy-time check on a Lambda's 4KB environment.
//
// The check exists because the limit is enforced by AWS mid-`pulumi up`, on a
// call that names a byte count and not the field that grew. The two cases worth
// pinning are the ones that decide whether a deploy proceeds: an exact total
// already over the limit must stop it, and an over-limit total that only appears
// once the unresolved queue-URL vars are estimated must not — a wrong estimate
// blocking a good deploy would be worse than the failure it prevents.

open JestGlobals

let budget = Util_LambdaEnvBudget.limit

let throws = (f: unit => 'a): option<string> =>
  try {
    let _ = f()
    None
  } catch {
  | exn => exn->JsExn.fromException->Option.flatMap(JsExn.message)
  }

describe("Util_LambdaEnvBudget.check", () => {
  testSync("passes a small environment", () => {
    let msg = throws(() =>
      Util_LambdaEnvBudget.check(~lambdaName="Small", ~handlerConfigJson=`{"queueUrl":"q"}`)
    )
    expect(msg)->toEqual(None)
  })

  testSync("throws when HANDLER_CONFIG alone exceeds the limit", () => {
    let big = `{"x":"` ++ String.repeat("a", budget) ++ `"}`
    let msg = throws(() => Util_LambdaEnvBudget.check(~lambdaName="TooBig", ~handlerConfigJson=big))
    expect(msg->Option.isSome)->toBe(true)
    // Names the Lambda and points at the fix, not just the byte count.
    expect(msg->Option.mapOr(false, m => m->String.includes("TooBig")))->toBe(true)
    expect(msg->Option.mapOr(false, m => m->String.includes("extraStringAssets")))->toBe(true)
  })

  testSync("counts the queue-URL var names toward the exact total", () => {
    // Sized so HANDLER_CONFIG alone fits and the var NAMES alone push it over —
    // the names are known at check time, so this must throw rather than warn.
    let keys = Array.make(~length=40, "")->Array.mapWithIndex((_, i) =>
      `PTA_AVeryLongAggregateNameNumber${i->Int.toString}_QUEUE_URL`
    )
    let keyBytes = keys->Array.reduce(0, (acc, k) => acc + String.length(k))
    let fixed = Util_LambdaEnvBudget.frameworkVarsBytes + String.length("HANDLER_CONFIG")
    // Just past the limit on the exact total alone — the names are enough.
    let json = String.repeat("a", budget - fixed - keyBytes + 1)
    let msg = throws(() =>
      Util_LambdaEnvBudget.check(
        ~lambdaName="ManyTargets",
        ~handlerConfigJson=json,
        ~outputValuedKeys=keys,
      )
    )
    expect(msg->Option.isSome)->toBe(true)
  })

  testSync("only estimating over the limit warns rather than throwing", () => {
    // Exact total sits under the limit; it is the per-URL allowance that crosses
    // it. The deploy must be allowed to proceed and find out.
    let keys = Array.make(~length=20, "")->Array.mapWithIndex((_, i) => `PTA_A${i->Int.toString}_URL`)
    let exact =
      Util_LambdaEnvBudget.frameworkVarsBytes +
      String.length("HANDLER_CONFIG") +
      keys->Array.reduce(0, (acc, k) => acc + String.length(k))
    let room = budget - exact - 100
    let json = String.repeat("a", room)
    let msg = throws(() =>
      Util_LambdaEnvBudget.check(
        ~lambdaName="Estimated",
        ~handlerConfigJson=json,
        ~outputValuedKeys=keys,
      )
    )
    expect(msg)->toEqual(None)
  })
})
