/**
The conformance suite, run by a host against its own graft. `Make(Binding).register()`
inside a Jest test file registers one `describe` block over the binding.
*/

/** The suite's title, composed once and read twice: the suite registers it,
    and `certify-trait` computes the same string to find the run's assertions in
    a test report. Exported rather than inlined so neither side parses the
    other's prose.

    One title for both cardinalities: a host conforms to this trait or it does
    not, and which of the two suites established that is not a fact a
    certificate should have to know. `MakeSingle` registers under the same
    name. */
let suiteName = (host: string) => `${host} conforms to the attachments trait`

module Make = (B: Attachments.Binding) => {
  module G = ReventlessGwt.Behavior_GWT.Make(B.Spec, B.Behavior)

  let withA = Array.concat(B.created, [B.attachedC(B.refA)])
  let withAB = Array.concat(withA, [B.attachedC(B.refB)])

  let register = () =>
    G.describe(suiteName(B.Spec.name), () => {
      G.test("the first attachment is appended", () =>
        G.givenEvents(B.created)->G.whenCmd(B.attach(B.refA))->G.thenEvent(B.attached(B.refA))
      )

      G.test("attaching a ref already in the set is a no-op", () =>
        G.givenEvents(withA)->G.whenCmd(B.attach(B.refA))->G.thenNoEvent
      )

      G.test("a second ref extends the set rather than replacing it", () =>
        G.givenEvents(withA)->G.whenCmd(B.attach(B.refB))->G.thenEvent(B.attached(B.refB))
      )

      G.test("removing an attached ref is appended", () =>
        G.givenEvents(withA)->G.whenCmd(B.remove(B.refA))->G.thenEvent(B.removed(B.refA))
      )

      G.test("removing a ref not in the set is a no-op", () =>
        G.givenEvents(withA)->G.whenCmd(B.remove(B.refB))->G.thenNoEvent
      )

      G.test("a removed ref can be attached again", () =>
        G.givenEvents(Array.concat(withA, [B.removedC(B.refA)]))
        ->G.whenCmd(B.attach(B.refA))
        ->G.thenEvent(B.attached(B.refA))
      )

      G.test("the primary must be in the set", () =>
        G.givenEvents(withA)->G.whenCmd(B.setPrimary(B.refB))->G.thenError(B.notAttached)
      )

      G.test("the first attached is the primary until one is chosen", () =>
        G.givenEvents(withAB)->G.whenCmd(B.setPrimary(B.refA))->G.thenNoEvent
      )

      G.test("choosing another primary is appended", () =>
        G.givenEvents(withAB)->G.whenCmd(B.setPrimary(B.refB))->G.thenEvent(B.primarySet(B.refB))
      )

      G.test("choosing the current primary is a no-op", () =>
        G.givenEvents(Array.concat(withAB, [B.primarySetC(B.refB)]))
        ->G.whenCmd(B.setPrimary(B.refB))
        ->G.thenNoEvent
      )

      G.test("removing the chosen primary lets the first remaining stand in", () =>
        G.givenEvents(Array.concat(withAB, [B.primarySetC(B.refB), B.removedC(B.refB)]))
        ->G.whenCmd(B.setPrimary(B.refA))
        ->G.thenNoEvent
      )

      G.test("a caption needs its ref in the set", () =>
        G.givenEvents(withA)
        ->G.whenCmd(B.setAltText(B.refB, "side"))
        ->G.thenError(B.notAttached)
      )

      G.test("a caption is appended", () =>
        G.givenEvents(withA)
        ->G.whenCmd(B.setAltText(B.refA, "front"))
        ->G.thenEvent(B.altTextSet(B.refA, "front"))
      )

      G.test("repeating the caption is a no-op", () =>
        G.givenEvents(Array.concat(withA, [B.altTextSetC(B.refA, "front")]))
        ->G.whenCmd(B.setAltText(B.refA, "front"))
        ->G.thenNoEvent
      )
    })
}

/**
The suite for a host of the bounded cardinality.

Smaller than `Make`'s, and smaller for a reason worth reading: most of what the
larger suite asserts is about choosing between members, and a set that holds one
member has nothing to choose. Those assertions are not skipped here — they are
unreachable, because {!Attachments.SingleBinding} does not admit the commands
that would reach them. The absent primary is checked by the compiler.

What is left is the one rule cardinality actually changes — a second attachment
replaces rather than joins — plus the ref-less remove and the captions, which a
single image wants exactly as much as a gallery member does.
*/
module MakeSingle = (B: Attachments.SingleBinding) => {
  module G = ReventlessGwt.Behavior_GWT.Make(B.Spec, B.Behavior)

  let withA = Array.concat(B.created, [B.attachedC(B.refA)])

  let register = () =>
    G.describe(suiteName(B.Spec.name), () => {
      G.test("the first attachment is appended", () =>
        G.givenEvents(B.created)->G.whenCmd(B.attach(B.refA))->G.thenEvent(B.attached(B.refA))
      )

      G.test("attaching the ref already held is a no-op", () =>
        G.givenEvents(withA)->G.whenCmd(B.attach(B.refA))->G.thenNoEvent
      )

      // The assertion the cardinality exists for. Two facts, in order: what was
      // there leaves before what replaces it arrives, so a reader replaying the
      // log never sees the set hold both.
      G.test("a second ref replaces the first rather than joining it", () =>
        G.givenEvents(withA)
        ->G.whenCmd(B.attach(B.refB))
        ->G.thenEvents([B.removed(B.refA), B.attached(B.refB)])
      )

      G.test("clearing a held set removes what it holds", () =>
        G.givenEvents(withA)->G.whenCmd(B.clear)->G.thenEvent(B.removed(B.refA))
      )

      G.test("clearing an empty set is a no-op", () =>
        G.givenEvents(B.created)->G.whenCmd(B.clear)->G.thenNoEvent
      )

      G.test("a replaced ref can be attached again", () =>
        G.givenEvents(Array.concat(withA, [B.removedC(B.refA), B.attachedC(B.refB)]))
        ->G.whenCmd(B.attach(B.refA))
        ->G.thenEvents([B.removed(B.refB), B.attached(B.refA)])
      )

      // The caption names no ref either, so what it lands on is whatever is
      // held — and the assertion is that it lands on the *right* ref, which is
      // the only thing a ref-less command can get wrong.
      G.test("a caption lands on the ref that is held", () =>
        G.givenEvents(withA)
        ->G.whenCmd(B.setAltText("front"))
        ->G.thenEvent(B.altTextSet(B.refA, "front"))
      )

      G.test("a caption follows a replacement onto the new ref", () =>
        G.givenEvents(Array.concat(withA, [B.removedC(B.refA), B.attachedC(B.refB)]))
        ->G.whenCmd(B.setAltText("side"))
        ->G.thenEvent(B.altTextSet(B.refB, "side"))
      )

      G.test("captioning an empty set is refused", () =>
        G.givenEvents(B.created)->G.whenCmd(B.setAltText("front"))->G.thenError(B.notAttached)
      )

      G.test("repeating the caption is a no-op", () =>
        G.givenEvents(Array.concat(withA, [B.altTextSetC(B.refA, "front")]))
        ->G.whenCmd(B.setAltText("front"))
        ->G.thenNoEvent
      )
    })
}
