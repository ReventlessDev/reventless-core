// Worked examples for Mapping_GWT — one for each producer/consumer combination
// (Aggr→Aggr, Aggr→DCB, DCB→Aggr, DCB→DCB). See
// `docs/plans/done/reventless-gwt.md` Stage 5 for the plan context.
//
// Each test exercises the full source-command → mapping → target-command →
// target-decide pipeline end-to-end against the unified `GwtSource`/`GwtTarget`
// module types.

S.enableJson()

// ---------------------------------------------------------------------------
// Shared Aggregate specs + behaviours used by the Aggr→* cases below.
// ---------------------------------------------------------------------------

module CategorySpec = {
  module Id = Reventless.Id.StringPure
  let name = "Category"

  @schema
  type command = AddCategory({categoryId: string, name: string})

  @schema
  type event = CategoryAdded({categoryId: string, name: string})

  @schema
  type error = CategoryAlreadyExists

  let moduleUrl = ""
}

module CategoryBehavior = {
  module Spec = CategorySpec
  type state = NotCreated | Created
  let initialState = NotCreated
  let snapshot = None

  let evolve = (_state, event: CategorySpec.event) =>
    switch event {
    | CategoryAdded(_) => Created
    }

  let decide = (state, cmd: CategorySpec.command) =>
    switch (state, cmd) {
    | (NotCreated, AddCategory({categoryId, name})) =>
      Ok([CategorySpec.CategoryAdded({categoryId, name})])
    | (Created, AddCategory(_)) => Error(CategorySpec.CategoryAlreadyExists)
    }

  let moduleUrl = ""
}

// Target aggregate for Aggr→Aggr and DCB→Aggr cases.
module ProductSpec = {
  module Id = Reventless.Id.StringPure
  let name = "Product"

  @schema
  type command = MirrorCategory({productId: string, categoryId: string, name: string})

  @schema
  type event = ProductCategoryMirrored({productId: string, categoryId: string, name: string})

  @schema
  type error = ProductAlreadyMirrored

  let moduleUrl = ""
}

module ProductBehavior = {
  module Spec = ProductSpec
  type state = Pristine | Mirrored
  let initialState = Pristine
  let snapshot = None

  let evolve = (_state, event: ProductSpec.event) =>
    switch event {
    | ProductCategoryMirrored(_) => Mirrored
    }

  let decide = (state, cmd: ProductSpec.command) =>
    switch (state, cmd) {
    | (Pristine, MirrorCategory({productId, categoryId, name})) =>
      Ok([ProductSpec.ProductCategoryMirrored({productId, categoryId, name})])
    | (Mirrored, MirrorCategory(_)) => Error(ProductSpec.ProductAlreadyMirrored)
    }

  let moduleUrl = ""
}

// ---------------------------------------------------------------------------
// Shared StateChangeSlice specs used by the *→DCB and DCB→* cases.
// ---------------------------------------------------------------------------

module NotificationSlice = {
  let name = "Notification"

  type state = {sent: bool}
  let initialState = {sent: false}

  @schema
  type consumedEvent =
    | NotificationSent({
        notificationId: @s.matches(Reventless.DcbTag.string) string,
      })

  let evolve = (_state, event) =>
    switch event {
    | NotificationSent(_) => {sent: true}
    }

  @schema
  type command =
    | SendNotification({
        notificationId: @s.matches(Reventless.DcbTag.string) string,
        message: string,
      })

  @schema
  type error = NotificationAlreadySent

  @schema
  type event =
    | NotificationSent({
        notificationId: @s.matches(Reventless.DcbTag.string) string,
        message: string,
      })

  let decide = (state, command) =>
    switch command {
    | SendNotification({notificationId, message}) =>
      state.sent
        ? Error(NotificationAlreadySent)
        : Ok([NotificationSent({notificationId, message})])
    }
}

module InventorySlice = {
  let name = "Inventory"

  type state = {reserved: bool}
  let initialState = {reserved: false}

  @schema
  type consumedEvent =
    | StockReserved({itemId: @s.matches(Reventless.DcbTag.string) string})

  let evolve = (_state, event) =>
    switch event {
    | StockReserved(_) => {reserved: true}
    }

  @schema
  type command =
    | ReserveStock({
        itemId: @s.matches(Reventless.DcbTag.string) string,
        quantity: int,
      })

  @schema
  type error = OutOfStock

  @schema
  type event =
    | StockReserved({
        itemId: @s.matches(Reventless.DcbTag.string) string,
        quantity: int,
      })

  let decide = (state, command) =>
    switch command {
    | ReserveStock({itemId, quantity}) =>
      state.reserved ? Error(OutOfStock) : Ok([StockReserved({itemId, quantity})])
    }
}

// ---------------------------------------------------------------------------
// Adapter aliases — built once, shared across mappings.
// ---------------------------------------------------------------------------

module CategorySource = Mapping_GWT.FromBehavior(CategorySpec, CategoryBehavior)
module ProductTarget = Mapping_GWT.FromBehavior(ProductSpec, ProductBehavior)
module NotificationSource = Mapping_GWT.FromStateChangeSlice(NotificationSlice)
module NotificationTarget = Mapping_GWT.FromStateChangeSlice(NotificationSlice)
module InventoryTarget = Mapping_GWT.FromStateChangeSlice(InventorySlice)

// ---------------------------------------------------------------------------
// Case 1 — Aggr → Aggr: CategoryAdded triggers MirrorCategory on Product.
// ---------------------------------------------------------------------------

module AggrToAggrMapping = {
  module Source = CategorySource
  module Target = ProductTarget

  let map = (_sourceId, event: CategorySpec.event, _q) =>
    switch event {
    | CategoryAdded({categoryId, name}) => [
        Reventless.EventMapping.Publish(
          ("prod-for-" ++ categoryId)->ProductSpec.Id.makeFromString,
          ProductSpec.MirrorCategory({productId: "prod-for-" ++ categoryId, categoryId, name}),
        ),
      ]
    }
}

module AggrToAggrGwt = Mapping_GWT.Make(AggrToAggrMapping)

AggrToAggrGwt.describe("Category → Product (Aggr → Aggr)", () =>
  AggrToAggrGwt.test("AddCategory produces ProductCategoryMirrored on product", () =>
    AggrToAggrGwt.givenSourceEvents([])
    ->AggrToAggrGwt.andTargetEvents([])
    ->AggrToAggrGwt.whenSourceCmd("c1", AddCategory({categoryId: "c1", name: "Books"}))
    ->AggrToAggrGwt.thenTargetEvent(
      "prod-for-c1",
      ProductCategoryMirrored({productId: "prod-for-c1", categoryId: "c1", name: "Books"}),
    )
  )
)

// ---------------------------------------------------------------------------
// Case 2 — Aggr → DCB: CategoryAdded triggers SendNotification on Notification slice.
// ---------------------------------------------------------------------------

module AggrToDcbMapping = {
  module Source = CategorySource
  module Target = NotificationTarget

  let map = (_sourceId, event: CategorySpec.event, _q) =>
    switch event {
    | CategoryAdded({categoryId, name}) => [
        Reventless.EventMapping.Publish(
          ("notif-" ++ categoryId)->NotificationTarget.Id.makeFromString,
          NotificationSlice.SendNotification({
            notificationId: "notif-" ++ categoryId,
            message: `Category ${name} was created`,
          }),
        ),
      ]
    }
}

module AggrToDcbGwt = Mapping_GWT.Make(AggrToDcbMapping)

AggrToDcbGwt.describe("Category → Notification (Aggr → DCB)", () =>
  AggrToDcbGwt.test("AddCategory triggers NotificationSent on the DCB slice", () =>
    AggrToDcbGwt.givenSourceEvents([])
    ->AggrToDcbGwt.andTargetEvents([])
    ->AggrToDcbGwt.whenSourceCmd("c2", AddCategory({categoryId: "c2", name: "Media"}))
    ->AggrToDcbGwt.thenTargetEvent(
      "notif-c2",
      NotificationSlice.NotificationSent({
        notificationId: "notif-c2",
        message: "Category Media was created",
      }),
    )
  )
)

// ---------------------------------------------------------------------------
// Case 3 — DCB → Aggr: Inventory StockReserved triggers MirrorCategory on Product.
// ---------------------------------------------------------------------------

module InventorySource = Mapping_GWT.FromStateChangeSlice(InventorySlice)

module DcbToAggrMapping = {
  module Source = InventorySource
  module Target = ProductTarget

  let map = (_sourceId, event: InventorySlice.event, _q) =>
    switch event {
    | StockReserved({itemId, quantity: _}) => [
        Reventless.EventMapping.Publish(
          ("prod-" ++ itemId)->ProductSpec.Id.makeFromString,
          ProductSpec.MirrorCategory({
            productId: "prod-" ++ itemId,
            categoryId: itemId,
            name: itemId,
          }),
        ),
      ]
    }
}

module DcbToAggrGwt = Mapping_GWT.Make(DcbToAggrMapping)

DcbToAggrGwt.describe("Inventory → Product (DCB → Aggr)", () =>
  DcbToAggrGwt.test("ReserveStock triggers ProductCategoryMirrored", () =>
    DcbToAggrGwt.givenSourceEvents([])
    ->DcbToAggrGwt.andTargetEvents([])
    ->DcbToAggrGwt.whenSourceCmd("i1", ReserveStock({itemId: "i1", quantity: 5}))
    ->DcbToAggrGwt.thenTargetEvent(
      "prod-i1",
      ProductCategoryMirrored({productId: "prod-i1", categoryId: "i1", name: "i1"}),
    )
  )
)

// ---------------------------------------------------------------------------
// Case 4 — DCB → DCB: Inventory StockReserved triggers SendNotification on Notification slice.
// ---------------------------------------------------------------------------

module DcbToDcbMapping = {
  module Source = InventorySource
  module Target = NotificationTarget

  let map = (_sourceId, event: InventorySlice.event, _q) =>
    switch event {
    | StockReserved({itemId, quantity}) => [
        Reventless.EventMapping.Publish(
          ("reserved-" ++ itemId)->NotificationTarget.Id.makeFromString,
          NotificationSlice.SendNotification({
            notificationId: "reserved-" ++ itemId,
            message: `Reserved ${quantity->Int.toString} of ${itemId}`,
          }),
        ),
      ]
    }
}

module DcbToDcbGwt = Mapping_GWT.Make(DcbToDcbMapping)

DcbToDcbGwt.describe("Inventory → Notification (DCB → DCB)", () => {
  DcbToDcbGwt.test("ReserveStock triggers NotificationSent", () =>
    DcbToDcbGwt.givenSourceEvents([])
    ->DcbToDcbGwt.andTargetEvents([])
    ->DcbToDcbGwt.whenSourceCmd("i7", ReserveStock({itemId: "i7", quantity: 2}))
    ->DcbToDcbGwt.thenTargetEvent(
      "reserved-i7",
      NotificationSlice.NotificationSent({
        notificationId: "reserved-i7",
        message: "Reserved 2 of i7",
      }),
    )
  )

  // Target-error coverage: if the notification was already sent, SendNotification
  // fails with `NotificationAlreadySent`. `thenTargetError` surfaces the target's
  // decide error without requiring the source to produce no events.
  DcbToDcbGwt.test("existing NotificationSent causes target decide to reject", () =>
    DcbToDcbGwt.givenSourceEvents([])
    ->DcbToDcbGwt.andTargetEvents([
      (
        "reserved-i7",
        [NotificationSlice.NotificationSent({notificationId: "reserved-i7"})],
      ),
    ])
    ->DcbToDcbGwt.whenSourceCmd("i7", ReserveStock({itemId: "i7", quantity: 2}))
    ->DcbToDcbGwt.thenTargetError(NotificationAlreadySent)
  )
})
