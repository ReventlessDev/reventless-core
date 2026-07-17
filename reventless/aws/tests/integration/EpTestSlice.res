// Tiny slice spec exercised by `DcbCommandTopicEntryPoint_IntegrationTest`.
// Standalone schema — does not depend on the example apps — so the test is
// self-contained and the fixture's shape can drift independently of any
// shipped slice.
//
// Hand-written explicit `@s.matches(...)` form rather than the
// `@@reventless.spec` / `@partitionTag` PPX shorthand: the reventless-ppx
// is only wired into reventless-core's rescript.json, not reventless-aws's.

@schema
type consumedEvent = WidgetAdded({widgetId: string})

@schema
type command = AddWidget({widgetId: @s.matches(Reventless.DcbTag.partition) string})

@schema
type error = AlreadyAdded

@schema
type event = WidgetAdded({widgetId: @s.matches(Reventless.DcbTag.partition) string})

let name = "EpTestSlice"
let moduleUrl = "ep-test://EpTestSlice"
let commandAuthorization = (_: command): Reventless.Authorization.permission => AllowAnonymous
let readConsistency = Reventless.ReadConsistency.EscalateOnRetry

// `module Id = Reventless.Id.String` — patched in by `patchSpecId` at runtime,
// so we don't need to expose it from this module.
