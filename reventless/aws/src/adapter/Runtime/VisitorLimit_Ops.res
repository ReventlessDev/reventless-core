// The limit on the doors and views for visitors, as the command function applies
// it: per door and source address, from the deployment's configuration.
//
// Read per call from the function's environment: the table the deploy made for
// the counts (`ANONYMOUS_LIMIT_TABLE`), the limits for doors
// (`REVENTLESS_ANONYMOUS_REQUEST_LIMIT`) and for views
// (`REVENTLESS_ANONYMOUS_VIEW_LIMIT`), each its default when unset, and the
// fingerprint key the source address is stored under.

let tableVariable = "ANONYMOUS_LIMIT_TABLE"

/** What a source's address is fingerprinted for, so the same address counted here
    is not the same value as a fingerprint taken for anything else. */
let purpose = "anonymous-request-source"

let limit = (~kind: Reventless.AnonymousRequestLimit.kind): Reventless.AnonymousRequestLimit.t =>
  switch Reventless.AnonymousRequestLimit.fromSetting(
    ~kind,
    NodeProcess.env->Dict.get(Reventless.AnonymousRequestLimit.envKeyOf(kind)),
  ) {
  | Ok(limit) => limit
  | Error(message) => JsError.throwWithMessage(message)
  }

/** The first address of a forwarded-for header: the caller's, as the API saw it. */
let sourceOf = (forwardedFor: Nullable.t<string>): string =>
  switch forwardedFor->Nullable.toOption->Option.map(String.trim) {
  | None | Some("") => "unknown"
  | Some(list) => list->String.split(",")->Array.get(0)->Option.mapOr("unknown", String.trim)
  }

/** Whether one more request from `source` reaches `door`, under the limit of its
    kind. A function handed no table has nothing to count in, and admits nobody: a
    door for visitors is not deployed without one. */
let admitsAs = async (~kind, door: string, source: Nullable.t<string>): bool =>
  switch NodeProcess.env->Dict.get(tableVariable) {
  | None | Some("") => false
  | Some(tableName) =>
    await AnonymousLimiter_DynamoDb.admit(
      ~store=AnonymousLimiter_DynamoDb.dynamoDb(~tableName),
      ~limit=limit(~kind),
      ~fingerprint=address =>
        ReventlessCore.Secrets_Node_Backend.provider.fingerprint(~purpose, address),
      ~door,
      ~source=sourceOf(source),
    )
  }

/** A door's check, for the entry point. */
let admitsDoor = (door, source) => admitsAs(~kind=Door, door, source)

/** A view's check, asked before it reads. */
let admitsView = (view, source) => admitsAs(~kind=View, view, source)

/** What a door answers a source past its limit: the rejection the local platform
    gives, so a client reads one answer on both. */
let throttled = (door: string): JSON.t =>
  ReventlessCore.CommandTopic_Helpers.commandOutcomeToJson(
    Rejected({
      msgId: ReventlessCore.Message.uuid(),
      errorCode: Reventless.CommandOutcome.code(Throttled),
      errorDetail: Some(`Mutation.${door}: too many requests from this source; retry later`),
      cause: InfrastructureFailure,
    }),
  )
