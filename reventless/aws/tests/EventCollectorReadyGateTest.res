open JestGlobals

// Guards what `eventCollectorReadyRef` waits for.
//
// The deploy publishes a synthetic re-detect once the EventCollector Lambda is
// ready, because that Lambda is what ANSWERS the handshake: reached while it is
// still serving the previous bundle, it replies with the previous definition,
// Connect sees a definition it already holds and emits nothing, and the
// registration keeps the old structure — with no second re-detect coming.
//
// The gate used to be `lambda->Output.apply(_ => ())`. `apply` receives the
// Function record as soon as the OUTER Output carries it, which is at
// construction, with every field inside still an unresolved Output — so the gate
// settled while the update was in flight and the whole barrier was inert. No
// deploy-shaped test catches it: the answer is only stale when a deploy changes a
// structure, and the race is won more often than it is lost.
//
// So this asserts the barrier directly — the gate must not settle until the
// resource's own outputs do.

// The engine's Output constructor, so a field can be left genuinely pending
// rather than faked. A resolved promise would settle on the next tick either
// way, which is the difference under test.
@module("@pulumi/pulumi") @new
external makeOutput: (
  Set.t<unit>,
  promise<'a>,
  promise<bool>,
  promise<bool>,
  promise<Set.t<unit>>,
) => Pulumi.Output.t<'a> = "Output"

let pending = (value: 'a): (Pulumi.Output.t<'a>, unit => unit) => {
  let settle = ref(() => ())
  let p = Promise.make((resolve, _) => settle := () => resolve(value))
  (
    makeOutput(Set.make(), p, Promise.resolve(true), Promise.resolve(false), Promise.resolve(Set.make())),
    settle.contents,
  )
}

let ticks = async () => await Promise.make((resolve, _) => {
  let _ = setTimeout(() => resolve(), 50)
})

// A Lambda mid-update: the resource record exists, its outputs do not yet.
let deploying = (): (Pulumi.Output.t<PulumiAws.Lambda.Function.t>, unit => unit) => {
  let (arn, complete) = pending("arn:aws:lambda:eu-west-1:123456789012:function:CatalogPluginEventColl")
  let fn: PulumiAws.Lambda.Function.t = {
    arn,
    id: "CatalogPluginEventColl"->Pulumi.Output.make,
    name: "CatalogPluginEventColl"->Pulumi.Output.make,
    invokeArn: "arn:aws:apigateway:invoke"->Pulumi.Output.make,
  }
  // `apply` preserves the nested Outputs, which is how the real resource arrives.
  (()->Pulumi.Output.make->Pulumi.Output.apply(_ => fn), complete)
}

let observe = (gate: Pulumi.Output.t<unit>): ref<bool> => {
  let settled = ref(false)
  let _ = gate->Pulumi.Output.apply(_ => settled := true)
  settled
}

describe("the EventCollector readiness gate", () => {
  testAsync("does not settle while the function's outputs are still pending", async () => {
    let (lambda, _complete) = deploying()
    let settled = lambda->Pulumi.Output.flatMap(fn => fn.arn)->Pulumi.Output.apply(_ => ())->observe
    await ticks()
    expect(settled.contents)->toBe(false)
  })

  testAsync("settles once they resolve", async () => {
    let (lambda, complete) = deploying()
    let settled = lambda->Pulumi.Output.flatMap(fn => fn.arn)->Pulumi.Output.apply(_ => ())->observe
    complete()
    await ticks()
    expect(settled.contents)->toBe(true)
  })

  // The shape that shipped, kept as the reason the one above is written the way it
  // is: applying to the resource settles against a Lambda still being updated.
  testAsync("settles immediately when taken off the resource instead", async () => {
    let (lambda, _complete) = deploying()
    let settled = lambda->Pulumi.Output.apply(_ => ())->observe
    await ticks()
    expect(settled.contents)->toBe(true)
  })
})
