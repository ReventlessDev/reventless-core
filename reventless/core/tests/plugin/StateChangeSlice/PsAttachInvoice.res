// Test fixture spec for declared-object-store collection.
//
// Carries `@storageRef` on a command field, on an event field, and once in the
// qualified `"<plugin>.<store>"` form — the three shapes Plugin_Structure has to
// resolve into one qualified identity per store. `documents` is declared twice
// on purpose so the deduplication is exercised by data rather than asserted in
// the abstract.

@@reventless.spec("AttachInvoice")

type state = bool
let initialState = false

@schema
type consumedEvent = OrderPlaced

let evolve = (_state, _event) => true

// Note the attribute position: `@storageRef(…)` precedes the field NAME. Placed
// after the colon it attaches to the type expression instead of the field, and
// the ppx ignores it silently — a declaration that compiles, deploys green, and
// provisions nothing.
@schema
type command =
  | AttachInvoice({
      orderId: string,
      @storageRef("documents") documentUrl: string,
      // Another plugin's store — qualified, so it must NOT resolve to this
      // plugin.
      @storageRef("branding.logos") logoUrl: string,
    })

@schema
type error = OrderNotFound

@schema
type event = InvoiceAttached({orderId: string, @storageRef("documents") documentUrl: string})

let decide = (_state, _command): result<array<event>, error> => Ok([])
