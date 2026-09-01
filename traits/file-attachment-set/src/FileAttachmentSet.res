/**
The host contract of the attachment-set trait: an ordered set of stored files on
an entity, with a primary and a caption per member. Unlike the geocoding trait this
one writes nothing back — the graft *is* a StateChangeSlice of the host — so the
contract is over that slice. The rules live in `FileAttachmentSet_Rules` and are asserted
through a host by `FileAttachmentSet_Conformance`; the spec surface the host maps onto
them is scaffolded from `spec-fragments/`.
*/

/** One host, bound. `ref` is the stored file's reference (a `StorageRef` today),
    abstract so a richer attachment identity is a re-instantiation, not a break. */
module type Binding = {
  type ref
  /** Two refs that differ. */
  let refA: ref
  let refB: ref

  module Spec: ReventlessGwt.Behavior_GWT.BehaviorSpec
  module Behavior: ReventlessGwt.Behavior_GWT.Behavior with module Spec = Spec

  /** History that brings the entity into existence with an empty set. */
  let created: array<Spec.consumedEvent>
  /** The set's own facts, as the slice consumes them. */
  let attachedC: ref => Spec.consumedEvent
  let removedC: ref => Spec.consumedEvent
  let primarySetC: ref => Spec.consumedEvent
  let altTextSetC: (ref, string) => Spec.consumedEvent

  let attach: ref => Spec.command
  let remove: ref => Spec.command
  let setPrimary: ref => Spec.command
  let setAltText: (ref, string) => Spec.command

  /** The set's facts, as the slice emits them. */
  let attached: ref => Spec.event
  let removed: ref => Spec.event
  let primarySet: ref => Spec.event
  let altTextSet: (ref, string) => Spec.event
  /** The refusal for a primary or caption on a ref that is not in the set. */
  let notAttached: Spec.error
}
