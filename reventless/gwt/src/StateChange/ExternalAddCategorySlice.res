// Production-shaped StateChangeSlice Spec used by the external-Spec
// verification test at [tests/StateChange/ExternalAddCategorySlice_GWT.res].
// Mirrors the worked-example AddCategory slice shape: DCB-tagged categoryId
// on command + event, payload-less consumed events.
//
// Spec half (Plan 02 Phase 6) — types, schemas, name. The matching impl
// half lives in [ExternalAddCategorySlice_Behavior.res].

let name = "ExternalAddCategory"

@schema
type consumedEvent =
  | CategoryAdded
  | CategoryArchived

@schema
type command = AddCategory({categoryId: @s.matches(Reventless.DcbTag.string) string, name: string})

@schema
type error = CategoryAlreadyExists

@schema
type event = CategoryAdded({categoryId: @s.matches(Reventless.DcbTag.string) string, name: string})

// What `@@reventless.spec` injects into a real spec: the default rule.
type role = Reventless.Role.name
let commandAuthorization = (_: command): Reventless.Authorization.rule<role> =>
  Reventless.Authorization.AllowAuthenticated
