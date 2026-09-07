// Phase 4 fixture: state-view slice with structural annotations.
// Used to verify Plugin_Structure.make ships x-reventless-* extension
// properties through queryableDef.schema after swapping S.toJSONSchema
// for SuryToJsonSchema.deriveObjectSchema.

@@reventless.spec("AnnotatedView")

@schema
type consumedEvent =
  | ItemRecorded({
      itemId: string,
      ownerId: string,
      version: string,
      name: string,
      total: float,
      // On the event, not just the state: a renderer composes from an event
      // payload, so this is the case the marker has to reach.
      @sensitive contact: string,
    })

@live(false)
@schema
type state = {
  @id itemId: string,
  @subId version: string,
  @index("byOwner") ownerId: string,
  name: string,
  @semantic("currency") @metric({aggregate: "sum", label: "Revenue"}) total: float,
  @sensitive contact: string,
}

let project = ({event}: Reventless.StateViewSlice.consumed<consumedEvent>) =>
  switch event {
  | ItemRecorded({itemId, ownerId, version, name, total, contact}) =>
    [Set(itemId, {itemId, ownerId, version, name, total, contact})]
  }
