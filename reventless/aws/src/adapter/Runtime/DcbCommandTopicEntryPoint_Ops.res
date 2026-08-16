// Typed cold-start core for the DCB CommandTopic Lambda entry point.
//
// The "typed core, thin shell" split (docs/plans/done/minimize-lambda-entrypoint-mjs-shell.md).
// The `.mjs` shell owns the one boundary that is inherently untyped: reading
// `HANDLER_CONFIG` and dynamically `import()`-ing user Spec/Behavior modules at
// cold start, whose types are unknowable here. Everything below is compiler-
// checked against the *real* framework signatures, so the invariants that used
// to live only in `.mjs` comments are now enforced by the build:
//
//   * decision-read scope derivation — re-deriving from annotations alone once
//     dropped inferred cross-partition reference reads and rejected every
//     reference-guarded command in prod. See
//     docs/analysis/dcb-runtime-scope-annotation-drift.md.
//   * storage `partitionTag` derivation + threading — dropping it collapsed the
//     composite fence and produced TransactionConflict bursts in prod. See
//     docs/plans/done/dcb-composite-fence-residual-burst-contention.md.
//   * the storage-ops calls take *labeled* args; the `.mjs` called them
//     positionally and relied on a comment to stay aligned with the compiled
//     signature. Here a signature change is a compile error, not a silent
//     runtime regression.

// A user StateChangeSlice spec module, dynamically imported and id-patched by the
// `.mjs` shell. Opaque here; only the fields the derivations read are projected
// out through typed getters — the single sanctioned coercion point for specs.
type specModule

@get external specName: specModule => string = "name"
@get external specModuleUrl: specModule => Nullable.t<string> = "moduleUrl"
@get external specCommandSchema: specModule => S.t<unknown> = "commandSchema"
@get external specConsumedEventSchema: specModule => S.t<unknown> = "consumedEventSchema"
@get external specEventSchema: specModule => S.t<unknown> = "eventSchema"

// The `pgConnection` object as it arrives in `HANDLER_CONFIG` — the
// `PgConnection.connectionConfig` fields plus `lockStrategy`. Present iff this
// DcbEventLog is Postgres-backed.
type pgConnectionJson
@get external pgLockStrategy: pgConnectionJson => Nullable.t<string> = "lockStrategy"
external asConnectionConfig: pgConnectionJson => PgConnection.connectionConfig = "%identity"

// The decision-read scope + storage partition tag for one consistency boundary,
// derived exactly the way the deploy-time `Dcb_Builder` does (both call the same
// `Reventless.DcbTag` functions — the single source of truth), so the runtime
// query can't diverge from the storage/GSI scope.
type derivedScope = {
  crossPartitionTagKeys: array<string>,
  tagKeysByEventType: dict<array<string>>,
  partitionTag: option<Reventless.DcbTag.derivedPartitionTag>,
}

let deriveScope = (specs: array<specModule>): derivedScope => {
  let scope = Reventless.DcbTag.deriveEffectiveScope(
    specs->Array.map(s => {
      Reventless.DcbTag.name: specName(s),
      commandSchema: specCommandSchema(s),
      consumedEventSchema: specConsumedEventSchema(s),
      eventSchema: specEventSchema(s),
    }),
  )

  // `derivePartitionTag` throws only on a misconfigured spec, which the deploy
  // would already have rejected; degrade to untagged fences rather than crash
  // cold start (matches the shell's prior defensive behaviour).
  let partitionTag = try Some(
    Reventless.DcbTag.derivePartitionTag(
      specs->Array.map(s => (
        specName(s),
        specModuleUrl(s)->Nullable.toOption->Option.getOr(specName(s)),
        specEventSchema(s),
      )),
    ),
  ) catch {
  | _ => None
  }

  {
    crossPartitionTagKeys: scope.crossPartitionTagKeys,
    tagKeysByEventType: scope.tagKeysByEventType,
    partitionTag,
  }
}

// The command TAG names this slice handles — used by the shell to build its
// `handlersByType` routing map.
let commandTypeNames = (spec: specModule): array<string> =>
  Reventless.DcbTag.extractVariantNames(specCommandSchema(spec))

// DynamoDB storage ops for the shared DcbEventLog, threading the derived scope.
// Mirrors `DcbEventLogStorage_DynamoDb.res`'s deploy-time wiring minus the
// Pulumi.Output layer (the table name is already resolved at runtime).
let makeDynamoStorageOps = (
  ~tableName: string,
  scope: derivedScope,
): ReventlessCore.DcbEventLog_Adapter.operations => {
  let table: Util_DynamoDb_Runtime.resolvedTable = {
    id: "",
    name: tableName,
    arn: "",
    hashKey: "id",
  }
  {
    ReventlessCore.DcbEventLog_Adapter.read: DcbEventLogStorage_DynamoDb_Runtime.read(
      table,
      ~crossPartitionTagKeys=scope.crossPartitionTagKeys,
    ),
    append: DcbEventLogStorage_DynamoDb_Runtime.append(
      table,
      ~partitionTag=?scope.partitionTag,
      ~crossPartitionTagKeys=scope.crossPartitionTagKeys,
    ),
    readStream: DcbEventLogStorage_DynamoDb_Runtime.readStream(
      table,
      ~crossPartitionTagKeys=scope.crossPartitionTagKeys,
    ),
  }
}

// Postgres storage ops. `logName` is the `dcbEventLogTableName` (Postgres
// evaluates the DCB query atomically, so scope/GSI routing doesn't apply).
let makePostgresStorageOps = (
  ~pgConnection: pgConnectionJson,
  ~logName: string,
): ReventlessCore.DcbEventLog_Adapter.operations => {
  let lockStrategy = switch pgConnection->pgLockStrategy->Nullable.toOption {
  | Some("RowLocks") => #RowLocks
  | _ => #AdvisoryLocks
  }
  DcbEventLogStorage_Postgres_Runtime.opsFor(
    pgConnection->asConnectionConfig,
    ~logName,
    ~lockStrategy,
  )
}

// Storage-backend selection: Postgres when `pgConnection` is present, else
// DynamoDB. One entry point for the shell.
let makeStorageOps = (
  ~tableName: string,
  ~pgConnection: option<pgConnectionJson>,
  scope: derivedScope,
): ReventlessCore.DcbEventLog_Adapter.operations =>
  switch pgConnection {
  | Some(pg) => makePostgresStorageOps(~pgConnection=pg, ~logName=tableName)
  | None => makeDynamoStorageOps(~tableName, scope)
  }

// ── Tier 2.5: typed slice-handler wiring ────────────────────────────────────
// The shell previously invoked the compiled `StateChangeSlice_Callback.Make`
// functor and its `handleCommands` result POSITIONALLY — the exact call the
// line-146 comment flagged, and the 2026-06-21 incident's regression class
// (a labelled arg added before the positional ones shifts `stream` to
// undefined, crashing inside `Stream.mapEffect`). Moving the functor call, the
// JSON→command decode, and the `handleCommands` invocation here makes all three
// compiler-checked. The loaded Spec/Behavior modules enter opaque (a clean
// pass-through to the functor — not poked at); `dcbEventLog` enters as a
// boundary-typed parameter (the shell still builds it).

// The loaded slice's `command` type — opaque; flows from the decode straight
// into `handleCommands`, so decode and consume share one abstract type.
type command
type behaviorModule

@get external specCommandSchemaTyped: specModule => S.t<command> = "commandSchema"

// `StateChangeSlice_Callback.Make(Spec)(Behavior)` — curried in compiled form.
type sliceCallback = {
  handleCommands: (
    ~tagKeysByEventType: dict<array<string>>=?,
    ~crossPartitionTagKeys: array<string>=?,
    ReventlessInfra.DcbEventLog.operations,
    Stream.t<
      ReventlessInfra.CommandTopic.topicItem<
        ReventlessCore.Message.command'<Reventless.Id.String.t, command>,
      >,
      string,
      unit,
    >,
  ) => Effect.t<array<result<string, string>>, string, unit>,
}
@module("@reventlessdev/reventless-core/src/components/StateChangeSlice/StateChangeSlice_Callback.res.mjs")
external makeSliceCallback: specModule => behaviorModule => sliceCallback = "Make"

// Builds the per-slice JSON-command handler: decode each topic item's JSON
// command against the slice's schema (dropping undecodable ones), then dispatch
// the decoded stream through the slice callback. Returns the same
// `Stream.t<topicItem<JSON>> => Effect` the shell's routing map keys on.
let buildSliceHandler = (
  spec: specModule,
  behavior: behaviorModule,
  ~tagKeysByEventType: dict<array<string>>,
  ~crossPartitionTagKeys: array<string>,
  dcbEventLog: ReventlessInfra.DcbEventLog.operations,
) => {
  let callback = makeSliceCallback(spec)(behavior)
  let commandSchema = spec->specCommandSchemaTyped
  (
    jsonStream: Stream.t<ReventlessInfra.CommandTopic.topicItem<JSON.t>, string, unit>,
  ): Effect.t<array<result<string, string>>, string, unit> => {
    let decodedStream =
      jsonStream
      ->Stream.mapEffect(topicItem =>
        Effect.sync(() =>
          switch ReventlessCore.Message.decodeCommand'(
            topicItem.command,
            Reventless.Id.String.schema,
            commandSchema,
          ) {
          | decoded =>
            Some({ReventlessInfra.CommandTopic.command: decoded, reference: topicItem.reference})
          | exception _ => None
          }
        )
      )
      ->Stream.flatMap(opt =>
        switch opt {
        | Some(item) => Stream.fromIterable([item])
        | None => Stream.empty
        }
      )
    callback.handleCommands(~tagKeysByEventType, ~crossPartitionTagKeys, dcbEventLog, decodedStream)
  }
}

// ── Inbound translation receiver wiring (Route 0) ───────────────────────────
// The DCB command Lambda is also the target of every InboundTranslationSlice
// mutation on the plugin's API — its AppSync resolver invokes this Lambda with an
// `{__inboundTranslation, fieldName, arguments}` payload. Building the per-field
// `receive` here keeps the curried `InboundTranslationSlice_Callback.Make` functor
// call compiler-checked (same rationale as `buildSliceHandler`) and mirrors the
// in-process composite handler in `Dcb_Builder.res`, so the deployed surface and
// the local surface encode the same `commandOutcome`.

// The dynamically-imported Translation module — opaque; a clean pass-through to
// the functor (only `translate` is read, inside the compiled callback).
type translationModule

type inboundCallback = {
  receive: (
    ReventlessInfra.CommandTopic.publishJsons,
    JSON.t,
  ) => promise<ReventlessInfra.InboundTranslationSlice.receiveResult>,
  auditLog: dict<ReventlessCore.InboundTranslationSlice_Callback.auditRow>,
}
@module("@reventlessdev/reventless-core/src/components/InboundTranslationSlice/InboundTranslationSlice_Callback.res.mjs")
external makeInboundCallback: specModule => translationModule => inboundCallback = "Make"

// Builds the inbound receive handler: run the slice's `receive` (which validates
// the external input against the spec schema, translates, and publishes the mapped
// commands via `publishJsons`), then — when an audit table name was threaded —
// drain the in-memory audit log to that table (best-effort, matching
// `InboundTranslationSlice_Builder`'s inline `syncToQueryDb`). Returns the
// `commandOutcome` JSON, byte-compatible with the AppSync direct-invocation route.
let buildInboundReceiver = (
  spec: specModule,
  translation: translationModule,
  ~publishJsons: ReventlessInfra.CommandTopic.publishJsons,
  ~auditQueryDbOps: option<ReventlessCore.QueryDb_Adapter.operations>,
) => {
  let callback = makeInboundCallback(spec)(translation)
  async (args: JSON.t): JSON.t => {
    let result = await callback.receive(publishJsons, args)
    switch auditQueryDbOps {
    | Some(ops) =>
      let id = result->ReventlessCore.InboundTranslationSlice_Callback.requestIdOf
      switch callback.auditLog->ReventlessCore.InboundTranslationSlice_Callback.takeAuditRow(id) {
      | Some(row) =>
        let json = row->S.reverseConvertToJsonOrThrow(
          ReventlessCore.InboundTranslationSlice_Callback.auditRowSchema,
        )
        // A failed audit write must not fail the mutation (the command was
        // already published), but it must not vanish either. `save` RESOLVES
        // with `Error(_)` on a storage failure (it does not throw), so the
        // result must be inspected — a bare `let _ = await ops.save(...)` would
        // swallow the failure and leave the audit view permanently, silently
        // empty. `try` still guards an unexpected reject.
        try {
          switch await ops.save(id, json, ReventlessCore.QueryDb.Overwrite, None) {
          | Ok() => ()
          | Error(err) =>
            ReventlessCore.EffectLogger.logError(
              ~comp="InboundTranslationSlice.audit",
              `failed to persist audit row ${id}: ${err
                ->ReventlessCore.QueryDb.storageErrorToString}`,
            )->Effect.runSync
          }
        } catch {
        | exn =>
          let detail =
            exn->JsExn.fromException->Option.flatMap(JsExn.message)->Option.getOr("unknown error")
          ReventlessCore.EffectLogger.logError(
            ~comp="InboundTranslationSlice.audit",
            `failed to persist audit row ${id}: ${detail}`,
          )->Effect.runSync
        }
      | None => ()
      }
    | None => ()
    }
    result
    ->ReventlessCore.InboundTranslationSlice_Callback.receiveResultToOutcome
    // `CommandTopic_Helpers`, not `CommandTopic`: the latter imports `Adapter`
    // (→ `@pulumi/pulumi`) for a deploy-time helper, which would crash this
    // runtime Lambda's cold start. The encoder itself lives in the pure Helpers.
    ->ReventlessCore.CommandTopic_Helpers.commandOutcomeToJson
  }
}
