// A slice whose partition cannot be inferred, for `DcbColdStartPartitionTest`.
// It writes two ids and reads both off an event nothing in its boundary writes,
// so neither can be told apart from a reference.
//
// Explicit `@s.matches(...)` form: reventless-ppx is not wired into this package.

@schema
type consumedEvent = GadgetImported({gadgetId: string, supplierId: string})

@schema
type command =
  | LinkGadget({
      gadgetId: @s.matches(Reventless.DcbTag.string) string,
      supplierId: @s.matches(Reventless.DcbTag.string) string,
    })

@schema
type error = AlreadyLinked

@schema
type event =
  | GadgetLinked({
      gadgetId: @s.matches(Reventless.DcbTag.string) string,
      supplierId: @s.matches(Reventless.DcbTag.string) string,
    })

let name = "LinkGadget"
let moduleUrl = "cold-start-test://LinkGadget"
