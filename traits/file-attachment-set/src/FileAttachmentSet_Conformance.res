/**
The conformance suite, run by a host against its own graft. `Make(Binding).register()`
inside a Jest test file registers one `describe` block over the binding.
*/

module Make = (B: FileAttachmentSet.Binding) => {
  module G = ReventlessGwt.Behavior_GWT.Make(B.Spec, B.Behavior)

  let withA = Array.concat(B.created, [B.attachedC(B.refA)])
  let withAB = Array.concat(withA, [B.attachedC(B.refB)])

  let register = () =>
    G.describe(`${B.Spec.name} conforms to the attachment-set trait`, () => {
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
