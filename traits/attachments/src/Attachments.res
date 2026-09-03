/**
The host contract of the attachments trait: an ordered set of stored files on
an entity, with a primary and a caption per member. Unlike the geocoding trait this
one writes nothing back — the graft *is* a StateChangeSlice of the host — so the
contract is over that slice. The rules live in `Attachments_Rules` and are asserted
through a host by `Attachments_Conformance`; the spec surface the host maps onto
them is written by `Attachments_Scaffold`.
*/

/**
This trait's own account of itself — see `AddressGeocoding.declaration` for why the
version is read rather than written.

`WritesBack`: the graft's commands append this trait's facts onto the host's own
slice, which is what a host grafting it is asking for.
*/
let declaration: Reventless.Trait.t = {
  trait: "@reventlessdev/trait-attachments",
  version: Reventless.PackageVersion.fromModuleUrl(%raw(`import.meta.url`)),
  posture: WritesBack,
}

/**
The platform capabilities a host of this trait needs: **none**.

Not an oversight and not a placeholder. What this trait needs is an object
*store*, and a store need is declared by the field that carries `@storageRef` —
it travels as `pluginStructure.requiredStores`, keyed by `(plugin, store)`, and
`CapabilityNeed` deliberately excludes it. So the empty list is the true answer,
and stating it lets a listing distinguish "needs nothing brokered" from "nobody
has said".
*/
let capabilityNeeds: array<Reventless.CapabilityNeed.t> = []

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

/**
One host of the **bounded** cardinality, bound.

A separate contract rather than optional members on {!Binding}, because what
`Attachments_Rules.Single` changes is the host's command surface and not just a
rule: there is no primary to choose between one member, so the graft declares no
such command, and there is no ref for a remove to name, so it declares none.
Both absences are facts a module type states better than a test does — a
`Single` graft that grew a `SetPrimary` command would fail to satisfy this
signature, which is the check, and it happens at compile time.

Everything the two contracts share is spelled identically on purpose: a reader
comparing them should find the difference in what is missing, not in how the
common half is phrased.
*/
module type SingleBinding = {
  type ref
  /** Two refs that differ — the second is what replaces the first. */
  let refA: ref
  let refB: ref

  module Spec: ReventlessGwt.Behavior_GWT.BehaviorSpec
  module Behavior: ReventlessGwt.Behavior_GWT.Behavior with module Spec = Spec

  /** History that brings the entity into existence with an empty set. */
  let created: array<Spec.consumedEvent>
  /** The set's own facts, as the slice consumes them. No `primarySetC`: nothing
      emits one. */
  let attachedC: ref => Spec.consumedEvent
  let removedC: ref => Spec.consumedEvent
  let altTextSetC: (ref, string) => Spec.consumedEvent

  let attach: ref => Spec.command
  /** Remove whatever is held. Takes no ref — there is only one, and asking the
      caller to name it is asking them to repeat what the row already says. */
  let clear: Spec.command
  /** Caption whatever is held. Ref-less for `clear`'s reason, and there is a
      second one here: a bounded host's view carries the reference as a scalar
      and no collection at all, so there is no field for a selection to be a
      member *of*. */
  let setAltText: string => Spec.command

  /** The set's facts, as the slice emits them. */
  let attached: ref => Spec.event
  let removed: ref => Spec.event
  let altTextSet: (ref, string) => Spec.event
  /** The refusal for a caption on a ref that is not held. */
  let notAttached: Spec.error
}
