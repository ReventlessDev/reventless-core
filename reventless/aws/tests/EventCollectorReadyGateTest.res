open JestGlobals

// Guards what `Util_Lambda.updateLanded` waits for — the barrier the deploy
// publishes its synthetic re-detect behind.
//
// That collector Lambda is what ANSWERS the handshake: reached while it is still
// serving the previous bundle, it replies with the previous definition, Connect
// sees a definition it already holds and emits nothing, and the registration
// keeps the old structure — with no second re-detect coming.
//
// The first attempt at this gate depended on `arn`, and failed in production
// exactly as it had before: the re-detect went out ~1.2s BEFORE the Lambda update
// even started. A Lambda's identifiers are equal on both sides of a code update,
// so the engine resolves them from existing state without waiting for it. The
// mechanism (`flatMap` awaiting the Output it returns) was never in doubt — the
// property was.
//
// So these pin the property, not the mechanism. The middle test is the one that
// fails for an identifier-based gate.

// The engine's Output constructor, so a field can be left genuinely pending
// rather than faked. A resolved promise settles on the next tick either way,
// which is the difference under test.
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
  let p = Promise.make((resolve, _) => settle := (() => resolve(value)))
  (
    makeOutput(
      Set.make(),
      p,
      Promise.resolve(true),
      Promise.resolve(false),
      Promise.resolve(Set.make()),
    ),
    settle.contents,
  )
}

let ticks = async () =>
  await Promise.make((resolve, _) => {
    let _ = setTimeout(() => resolve(), 50)
  })

/** A collector mid-update, the way the engine presents one: the identifiers are
    already known — they do not change across a code update — and only
    `lastModified` is still pending. `complete` is AWS answering. */
let deploying = (): (Pulumi.Output.t<PulumiAws.Lambda.Function.t>, unit => unit) => {
  let (lastModified, complete) = pending("2026-09-08T12:13:41.891+0000")
  let fn: PulumiAws.Lambda.Function.t = {
    arn: "arn:aws:lambda:eu-west-1:123456789012:function:OrderingPluginEventColl"->Pulumi.Output.make,
    id: "OrderingPluginEventColl"->Pulumi.Output.make,
    name: "OrderingPluginEventColl"->Pulumi.Output.make,
    invokeArn: "arn:aws:apigateway:invoke"->Pulumi.Output.make,
    lastModified,
  }
  // `apply` preserves the nested Outputs, which is how the real resource arrives.
  (()->Pulumi.Output.make->Pulumi.Output.apply(_ => fn), complete)
}

let observe = (gate: Pulumi.Output.t<unit>): ref<bool> => {
  let settled = ref(false)
  let _ = gate->Pulumi.Output.apply(_ => settled := true)
  settled
}

describe("Util_Lambda.updateLanded", () => {
  // The regression. Every identifier on the record is already resolved here, so a
  // gate reading any of them opens immediately — which is the production failure,
  // reproduced.
  testAsync("does not open while only the identifiers are known", async () => {
    let (lambda, _complete) = deploying()
    let settled = lambda->Util_Lambda.updateLanded->observe
    await ticks()
    expect(settled.contents)->toBe(false)
  })

  testAsync("opens once AWS reports the update", async () => {
    let (lambda, complete) = deploying()
    let settled = lambda->Util_Lambda.updateLanded->observe
    complete()
    await ticks()
    expect(settled.contents)->toBe(true)
  })

  // Kept as the reason the gate is written the way it is: both shapes that were
  // tried before open against a collector still serving the previous bundle.
  testAsync("the shapes that shipped before open too early", async () => {
    let (lambda, _complete) = deploying()
    let onResource = lambda->Pulumi.Output.apply(_ => ())->observe
    let onArn = lambda->Pulumi.Output.flatMap(fn => fn.arn)->Pulumi.Output.apply(_ => ())->observe
    await ticks()
    expect(onResource.contents)->toBe(true)
    expect(onArn.contents)->toBe(true)
  })
})
