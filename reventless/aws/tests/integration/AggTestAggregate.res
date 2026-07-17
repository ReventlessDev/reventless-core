// Tiny aggregate spec exercised by `AggregateEntryPoint_IntegrationTest`.
// Standalone schema — does not depend on the example apps — so the test is
// self-contained and the fixture's shape can drift independently of any shipped
// aggregate. Hand-written (no `@@reventless.spec` PPX: reventless-ppx is only
// wired into reventless-core's rescript.json, not reventless-aws's), exposing
// exactly the fields the compiled `@@reventless.spec` output would: name, Id
// (patched in at runtime by patchSpecId), commandSchema/eventSchema/errorSchema
// (via sury-ppx), moduleUrl, commandAuthorization.

@schema
type command = Add({name: string})

@schema
type event = Added({name: string})

@schema
type error = AlreadyExists

let name = "AggTestAggregate"
let moduleUrl = "agg-test://AggTestAggregate"
let commandAuthorization = (_: command): Reventless.Authorization.permission => AllowAnonymous
