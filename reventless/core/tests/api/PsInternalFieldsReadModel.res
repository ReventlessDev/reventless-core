// Fixture for `@internal`: a state record whose storage shape and API shape
// differ. `eventCollector` and `extensionNames` are projected and stored and
// belong on no generated surface; everything else is ordinary.
//
// A spec file rather than a module inside the test, and named `*ReadModel*`
// deliberately: the annotation machinery runs under `@@reventless.spec` AND only
// for a file the PPX recognises as a read model or state view. That is also the
// honest scope for `@internal` — it describes a read model's state.

@@reventless.spec("InternalFieldsReadModel")

@schema
type consumedEvent = ItemRecorded({itemId: string, name: string})

@schema
type state = {
  @id itemId: string,
  name: string,
  @internal eventCollector: string,
  @internal extensionNames: array<string>,
}
