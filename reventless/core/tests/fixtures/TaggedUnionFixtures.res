// A queryable whose state carries a tagged union, which no view in the
// repository does yet.
//
// The mechanism has to be provable before anything adopts it: the SDL emitter,
// the JSON-Schema walk, the write-time `__typename` stamp and the storage
// round-trip all assert against this fixture. Pointing those assertions at a real
// view instead would make the mechanism own that view's breaking retype, its
// golden refresh and its client pin — which is the coupling the mechanism was cut
// away from.
//
// The union is spelled the way an adopter's would be: every arm an inline record
// declaring at least one named field of its own, because a bare arm is a string
// on the wire and an empty one implies a member type with no fields — neither of
// which GraphQL admits.

@schema
type geolocation =
  | Pending({requestedFor: string})
  | Located({point: Reventless.GeoPoint.t})
  | Unresolvable({reason: string})

// The name the type is emitted and stamped under. Written here by hand because
// this fixture is not a `@@reventless.spec` file; in one, the ppx writes exactly
// this line.
let geolocationSchema = Reventless.TaggedUnion.named(~name="Geolocation", geolocationSchema)

/** A required union field, the plain case. */
module CustomersSpec = {
  module Id = Reventless.Id.StringPure
  let name = "TaggedUnionCustomers"
  let moduleUrl: string = %raw(`import.meta.url`)

  @schema
  type state = {customerId: string, geolocation: geolocation}

  let config = Reventless.ReadModel.config()
  let subIdConfig = None
}

/** The wrapped cases: an optional union, and an array of them. */
module SightingsSpec = {
  module Id = Reventless.Id.StringPure
  let name = "TaggedUnionSightings"
  let moduleUrl: string = %raw(`import.meta.url`)

  @schema
  type state = {
    sightingId: string,
    lastSeen: option<geolocation>,
    history: array<geolocation>,
  }

  let config = Reventless.ReadModel.config()
  let subIdConfig = None
}

/** The same three arms with no name on the schema — the shape the emitter must
    decline to emit rather than emit under a name it made up. */
module UnnamedSpec = {
  module Id = Reventless.Id.StringPure
  let name = "TaggedUnionUnnamed"
  let moduleUrl: string = %raw(`import.meta.url`)

  @schema
  type verdict =
    | Approved({by: string})
    | Rejected({reason: string})

  @schema
  type state = {caseId: string, verdict: verdict}

  let config = Reventless.ReadModel.config()
  let subIdConfig = None
}

let queryEntryFor = (
  ~returnTypeName: string,
  ~specName: string,
  stateSchema: S.t<'a>,
): ReventlessInfra.Api.querySchemaEntry => {
  singleFieldName: returnTypeName,
  listFieldName: returnTypeName ++ "s",
  returnTypeName,
  specName,
  stateSchema: stateSchema->S.castToUnknown,
  authorization: None,
  connectionSpec: true,
}
