S.enableJson()

// --- Test Event Log Spec (events with DCB tags) ---

module TestEventLogSpec = {
  let moduleUrl: string = %raw(`import.meta.url`)
  @schema
  type event =
    | ItemCreated({itemId: @s.matches(Reventless.DcbTag.string) string, name: string})
    | ItemRenamed({itemId: @s.matches(Reventless.DcbTag.string) string, newName: string})
    | CountUpdated({
        category: @s.matches(Reventless.DcbTag.string) string,
        amount: @s.matches(Reventless.DcbTag.int) int,
      })
    | SimpleEvent
}

// --- Untagged Event Spec (for negative tests) ---

module UntaggedEventSpec = {
  @schema
  type event =
    | PlainEvent({name: string, value: int})
    | EmptyEvent
}

// --- Object event type (for testing extractTags with Object schema) ---

@schema
type objectEvent = {
  tenantId: @s.matches(Reventless.DcbTag.string) string,
  data: string,
}

// --- Test Command Spec ---

module TestCommandSpec = {
  let name = "TestStateChangeSlice"
  module Id = Reventless.Id.String
  let moduleUrl: string = %raw(`import.meta.url`)

  @schema
  type event =
    | ItemCreated({itemId: @s.matches(Reventless.DcbTag.string) string, name: string})
    | ItemRenamed({itemId: @s.matches(Reventless.DcbTag.string) string, newName: string})

  @schema
  type consumedEvent =
    | ItemCreated({itemId: @s.matches(Reventless.DcbTag.string) string, name: string})
    | ItemRenamed({itemId: @s.matches(Reventless.DcbTag.string) string, newName: string})

  @schema
  type command =
    | CreateItem({itemId: @s.matches(Reventless.DcbTag.string) string, name: string})
    | RenameItem({itemId: @s.matches(Reventless.DcbTag.string) string, newName: string})
    | NoOp

  @schema
  type error =
    | ItemAlreadyExists
    | ItemNotFound

  type state = {exists: bool, currentName: option<string>}
  let initialState = {exists: false, currentName: None}

  let evolve = (state, event) =>
    switch event {
    | ItemCreated({name}) => {exists: true, currentName: Some(name)}
    | ItemRenamed({newName}) => {...state, currentName: Some(newName)}
    }

  let decide = (state, command): result<array<event>, error> =>
    switch command {
    | CreateItem({itemId, name}) =>
      if state.exists {
        Error(ItemAlreadyExists)
      } else {
        Ok([ItemCreated({itemId, name})])
      }
    | RenameItem({itemId, newName}) =>
      if !state.exists {
        Error(ItemNotFound)
      } else {
        Ok([ItemRenamed({itemId, newName})])
      }
    | NoOp => Ok([])
    }
}

// --- Mock Storage ---

type publishedEvent = {
  service: string,
  meta: Message.meta,
  json: JSON.t,
}

type mockStorage = {
  operations: DcbEventLog_Adapter.operations,
  getEvents: unit => array<DcbEventLog_Adapter.rawSequencedEvent>,
  publishedEvents: ref<array<publishedEvent>>,
  mockPublishJson: EventTopic.publishJson,
  failNextAppends: ref<int>,
  // The `~after` cursor passed to each `read`/`readStream` call, in order.
  // `Some(_)` marks a delta read (projection-cache hit); `None` a full read.
  readAfters: ref<array<option<string>>>,
  // The `~strongConsistency` passed to each `readStream` call, in order
  // (eventual-first, strong-on-retry).
  readStrongConsistency: ref<array<bool>>,
  reset: unit => unit,
}

let posToInt = (pos: string) => pos->Int.fromString->Option.getOr(0)

let makeMockStorage = (): mockStorage => {
  let events: ref<array<DcbEventLog_Adapter.rawSequencedEvent>> = ref([])
  let position = ref(0)
  let publishedEventsRef: ref<array<publishedEvent>> = ref([])
  let failNextAppendsRef = ref(0)
  let readAftersRef: ref<array<option<string>>> = ref([])
  // Records the ~strongConsistency passed to each readStream call (one entry per
  // attempt) so tests can assert eventual-first / strong-on-retry escalation.
  let readStrongConsistencyRef: ref<array<bool>> = ref([])

  let matchesQuery = (
    event: DcbEventLog_Adapter.rawSequencedEvent,
    query: Reventless.DcbTag.query,
  ) =>
    if query->Array.length == 0 {
      true
    } else {
      query->Array.some(queryItem => {
        let typeMatch = switch queryItem.eventTypes {
        | Some(types) => types->Array.includes(event.eventType)
        | None => true
        }
        let tagMatch = switch queryItem.tags {
        | Some(tags) =>
          tags->Array.every(tag =>
            event.tags->Array.some(et => et.key == tag.key && et.value == tag.value)
          )
        | None => true
        }
        typeMatch && tagMatch
      })
    }

  let read = async (~query, ~after=?) => {
    readAftersRef := readAftersRef.contents->Array.concat([after])
    let filtered = events.contents->Array.filter(event => {
      let afterMatch = switch after {
      | Some(afterPos) => event.position->posToInt > afterPos->posToInt
      | None => true
      }
      afterMatch && matchesQuery(event, query)
    })
    let headPosition =
      events.contents
      ->Array.get(events.contents->Array.length - 1)
      ->Option.map(e => e.position)
    {
      DcbEventLog_Adapter.events: filtered,
      ?headPosition,
    }
  }

  let append = async (newEvents, ~condition=?) => {
    if failNextAppendsRef.contents > 0 {
      failNextAppendsRef := failNextAppendsRef.contents - 1
      Error(ReventlessInfra.DcbEventLog.Conflict)
    } else {
      let conflictDetected = switch condition {
      | Some(cond: Reventless.DcbTag.appendCondition) =>
        events.contents->Array.some(event => {
          let afterMatch = switch cond.after {
          | Some(pos) => event.position->posToInt > pos->posToInt
          | None => true
          }
          afterMatch && matchesQuery(event, cond.query)
        })
      | None => false
      }
      if conflictDetected {
        Error(ReventlessInfra.DcbEventLog.Conflict)
      } else {
        let storedEvents = newEvents->Array.map((event: DcbEventLog_Adapter.rawStoredEvent) => {
          position := position.contents + 1
          let pos = position.contents->Int.toString
          {
            DcbEventLog_Adapter.position: pos,
            eventType: event.eventType,
            data: event.data,
            tags: event.tags,
            meta: event.meta,
            recordedAt: Message.nowAsISOString(),
          }
        })
        events := events.contents->Array.concat(storedEvents)
        Ok(position.contents->Int.toString)
      }
    }
  }

  let readStream = (~query, ~after=?, ~strongConsistency=false) => {
    readStrongConsistencyRef := readStrongConsistencyRef.contents->Array.concat([strongConsistency])
    Effect.promise(() => read(~query, ~after?))
    ->Effect.map(result => result.events)
    ->Stream.fromEffect
    ->Stream.flatMap(arr => Stream.fromIterable(arr))
  }

  let mockPublishJson: EventTopic.publishJson = async (service, meta, json) => {
    publishedEventsRef := publishedEventsRef.contents->Array.concat([{service, meta, json}])
  }

  let reset = () => {
    events := []
    position := 0
    publishedEventsRef := []
    failNextAppendsRef := 0
    readAftersRef := []
    readStrongConsistencyRef := []
  }

  {
    operations: {read, append, readStream},
    getEvents: () => events.contents,
    publishedEvents: publishedEventsRef,
    mockPublishJson,
    failNextAppends: failNextAppendsRef,
    readAfters: readAftersRef,
    readStrongConsistency: readStrongConsistencyRef,
    reset,
  }
}

let testMeta: Message.meta = {
  service: "test",
  time: "2024-01-01T00:00:00Z",
  ip: "127.0.0.1",
  user: "test-user",
  msgId: "msg-1",
  correlationId: "corr-1",
}

// --- Test schemas for extractTaggedFields tests ---

@schema
type plainRecord = {
  name: string,
  value: int,
}

@schema
type multiTagRecord = {
  userId: @s.matches(Reventless.DcbTag.string) string,
  tenantId: @s.matches(Reventless.DcbTag.string) string,
  data: string,
}

@schema
type emptyVariant = Empty

@schema
type intTagEvent = CountEvent({count: @s.matches(Reventless.DcbTag.int) int})

@schema
type mixedEvent =
  | EventA({id: @s.matches(Reventless.DcbTag.string) string, name: string})
  | EventB({id: @s.matches(Reventless.DcbTag.string) string, count: int})
  | EventC({untaggedField: string})

@schema
type complexEvent =
  | UserCreated({userId: @s.matches(Reventless.DcbTag.string) string, name: string})
  | UserUpdated({userId: @s.matches(Reventless.DcbTag.string) string, email: string})
  | OrderPlaced({
      orderId: @s.matches(Reventless.DcbTag.string) string,
      userId: @s.matches(Reventless.DcbTag.string) string,
      amount: float,
    })
  | OrderShipped({
      orderId: @s.matches(Reventless.DcbTag.string) string,
      trackingId: @s.matches(Reventless.DcbTag.string) string,
    })
  | PaymentProcessed({paymentId: @s.matches(Reventless.DcbTag.string) string, amount: float})

@schema
type multiFieldEvent =
  | EventWithMultipleTags({
      userId: @s.matches(Reventless.DcbTag.string) string,
      tenantId: @s.matches(Reventless.DcbTag.string) string,
      sessionId: @s.matches(Reventless.DcbTag.string) string,
    })

// --- Cross-entity test schemas (for extractTagsExpanded / buildQuery tests) ---

@schema
type crossEntityCommand =
  | PlaceOrder({
      orderId: @s.matches(Reventless.DcbTag.string) string,
      customerId: string,
      productId: array<@s.matches(Reventless.DcbTag.string) string>,
    })

@schema
type singleTagCommand =
  CreateItem({itemId: @s.matches(Reventless.DcbTag.string) string, name: string})

// --- Produced event-log schema for vacuous-clause narrowing (Issue 14) ---
// Models the analysis example: OrderPlaced partitions by orderId but carries
// productId as a *secondary* tag; CatalogProductSynced carries only productId.
// extractTagKeysByEventType ⇒ {OrderPlaced: [orderId, customerId, productId],
//                              CatalogProductSynced: [productId]}.
@schema
type orderEventLog =
  | OrderPlaced({
      orderId: @s.matches(Reventless.DcbTag.string) string,
      customerId: @s.matches(Reventless.DcbTag.string) string,
      productId: @s.matches(Reventless.DcbTag.string) string,
    })
  | CatalogProductSynced({productId: @s.matches(Reventless.DcbTag.string) string})

// --- Tag-key override fixtures ---

// Producer using the singular field name (the default convention).
@schema
type singleProductEvent =
  CatalogProductSynced({productId: @s.matches(Reventless.DcbTag.string) string})

// Consumer using the plural field name with stringForKey override; both producer
// and consumer must serialize tags under the same key ("productId") to interoperate.
@schema
type multiProductCommand =
  | PlaceOrderWithMany({
      orderId: @s.matches(Reventless.DcbTag.string) string,
      productIds: array<@s.matches(Reventless.DcbTag.stringForKey(~key="productId")) string>,
    })

// Scalar field override — non-Id name remapped via @dcbTag("explicitKey") at the PPX
// level; the runtime side is exercised here directly with stringForKey.
@schema
type customKeyEvent = ProductLabelled({
  sku: @s.matches(Reventless.DcbTag.stringForKey(~key="productSku")) string,
})

// --- Composite partition tag test schemas ---

@schema
type compositeEvent =
  | SyncPlugin({
      environment: @s.matches(Reventless.DcbTag.compositePartitionMember(~position=0)) string,
      platformName: @s.matches(Reventless.DcbTag.compositePartitionMember(~position=1)) string,
      pluginName: @s.matches(Reventless.DcbTag.compositePartitionMember(~position=2)) string,
      version: string,
    })

@schema
type compositeEventCustomSep =
  | ConfigUpdated({
      tenantId: @s.matches(Reventless.DcbTag.compositePartitionMember(~position=0, ~sep=":")) string,
      region: @s.matches(Reventless.DcbTag.compositePartitionMember(~position=1, ~sep="/")) string,
      service: @s.matches(Reventless.DcbTag.compositePartitionMember(~position=2)) string,
      value: string,
    })

@schema
type compositeMultiVariant =
  | VariantA({
      env: @s.matches(Reventless.DcbTag.compositePartitionMember(~position=0)) string,
      name: @s.matches(Reventless.DcbTag.compositePartitionMember(~position=1)) string,
      data: string,
    })
  | VariantB({
      env: @s.matches(Reventless.DcbTag.compositePartitionMember(~position=0)) string,
      name: @s.matches(Reventless.DcbTag.compositePartitionMember(~position=1)) string,
      count: int,
    })

// Schema with @partitionTag (simple) for derivePartitionTagV2 fallback test
@schema
type simplePartitionEvent =
  | OrderPlaced({
      orderId: @s.matches(Reventless.DcbTag.partition) string,
      customerId: @s.matches(Reventless.DcbTag.string) string,
    })

// Schema that mixes composite and simple partition (should throw)
@schema
type mixedStrategyEvent =
  | BadEvent({
      env: @s.matches(Reventless.DcbTag.compositePartitionMember(~position=0)) string,
      name: @s.matches(Reventless.DcbTag.compositePartitionMember(~position=1)) string,
      orderId: @s.matches(Reventless.DcbTag.partition) string,
    })

// Schema with only 1 composite field (should throw)
@schema
type singleCompositeEvent =
  | OnlyOne({
      env: @s.matches(Reventless.DcbTag.compositePartitionMember(~position=0)) string,
      data: string,
    })

// --- Cross-partition (secondary-tag) read fixtures (Issue 13 / Phase 7) ---
// The textbook M:N shape: StudentSubscribed ties two entities. It is partitioned
// by courseId; studentId is declared @crossPartition so a single-tag decision
// read of studentId returns every one of the student's subscriptions across all
// course partitions. extractCrossPartitionTagKeys ⇒ ["studentId"].
@schema
type subscriptionEvent =
  | StudentSubscribed({
      courseId: @s.matches(Reventless.DcbTag.partition) string,
      studentId: @s.matches(Reventless.DcbTag.crossPartition) string,
    })

@schema
type subscribeCommand =
  | SubscribeStudent({
      courseId: @s.matches(Reventless.DcbTag.partition) string,
      studentId: @s.matches(Reventless.DcbTag.crossPartition) string,
    })
