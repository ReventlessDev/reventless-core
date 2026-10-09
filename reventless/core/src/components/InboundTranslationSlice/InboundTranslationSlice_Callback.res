// InboundTranslationSlice callback: parses external input, translates it into
// commands, checks each against its own rule, and publishes them. Runtime-pure,
// since the deployed DCB command Lambda imports it.

@schema
type auditStatus =
  | Success
  | Failure

@schema
type auditRow = {
  input: string,
  status: auditStatus,
  targetIds?: array<string>,
  commandCount?: int,
  error?: string,
  receivedAt: string,
}

/** The `CommandResult` a `receive` outcome answers with: the first target as
    `entityId` (omitted when nothing was produced), the fan-out as `eventCount`. */
let receiveResultToOutcome = (
  result: ReventlessInfra.InboundTranslationSlice.receiveResult,
): CommandTopic.commandOutcome =>
  switch result {
  | Ok({requestId, targetIds, commandCount}) =>
    switch targetIds->Array.get(0) {
    | Some(entityId) => Accepted({msgId: requestId, entityId, eventCount: commandCount})
    | None => Accepted({msgId: requestId, eventCount: commandCount})
    }
  | Error({requestId, error, ?errorCode}) =>
    Rejected({
      msgId: requestId,
      errorCode: errorCode->Option.getOr("TranslationFailed"),
      errorDetail: Some(error),
    })
  }

/** The request a `receive` outcome belongs to, from either arm. */
let requestIdOf = (result: ReventlessInfra.InboundTranslationSlice.receiveResult): string =>
  switch result {
  | Ok({requestId}) | Error({requestId}) => requestId
  }

/** Remove one request's audit row from the in-memory log and hand it back. The
    log outlives a request in a warm process, so draining all of it would rewrite
    every row it ever held. */
let takeAuditRow = (auditLog: Dict.t<auditRow>, requestId: string): option<auditRow> => {
  let row = auditLog->Dict.get(requestId)
  auditLog->Dict.delete(requestId)
  row
}

/** Whether `caller` may send a command under `rule`. No caller, or a system
    (IAM) caller, is the platform acting for itself and passes every rule. */
let callerAdmits = (rule: Reventless.Authorization.permission, caller) =>
  switch caller {
  | None => true
  | Some(identity) =>
    switch Reventless.OwnerScope.classify(identity, ~elevated=[]) {
    | System => true
    | _ => Reventless.Authorization.isAllowed(rule, identity)
    }
  }

/** What an inbound mutation's resolver sends a deployed handler. `identity` is
    built by the resolver, and is null where the transport identified nobody. */
type doorInvocation = {
  fieldName: string,
  arguments: JSON.t,
  identity: Nullable.t<Reventless.Identity.t>,
}

/** The caller a door hands on: what its transport identified, else anonymous, so
    a door that lost the identity refuses rather than acts as the platform. */
let doorCaller = (identity: Nullable.t<Reventless.Identity.t>): Reventless.Identity.t =>
  identity->Nullable.toOption->Option.getOr(Reventless.Identity.anonymous)

module type T = {
  module Spec: Reventless.InboundTranslationSlice.Spec
  module Translation: Reventless.InboundTranslationSlice.Translation with module Spec := Spec

  /** The audit log -- maps request ID to audit row. */
  let auditLog: Dict.t<auditRow>

  /** Receive external input, translate it, and publish commands. */
  let receive: (
    ReventlessInfra.CommandTopic.publishJsons,
    JSON.t,
    ~caller: Reventless.Identity.t=?,
  ) => promise<ReventlessInfra.InboundTranslationSlice.receiveResult>
}

module Make = (
  Spec: Reventless.InboundTranslationSlice.Spec,
  Translation: Reventless.InboundTranslationSlice.Translation with module Spec := Spec,
): (T with module Spec = Spec and module Translation := Translation) => {
  module Spec = Spec
  module Translation = Translation

  let auditLog: Dict.t<auditRow> = Dict.make()

  let now = () => Date.make()->Date.toISOString

  // External input has no upstream meta, so each command starts a correlation
  // chain. `service` names the command's target, on which its events dispatch.
  let makeMeta = (): Reventless.Message.meta => Message.generateMeta(~service=Spec.targetName)

  let messageOf = (exn, fallback) =>
    exn->JsExn.fromException->Option.flatMap(JsExn.message)->Option.getOr(fallback)

  // One audit row per request, whatever the outcome.
  let failWith = (~requestId, ~inputJson, ~errorCode=?, error) => {
    auditLog->Dict.set(
      requestId,
      {input: inputJson->JSON.stringify, status: Failure, error, receivedAt: now()},
    )
    Error({ReventlessInfra.InboundTranslationSlice.requestId, error, ?errorCode})
  }

  let succeed = (~requestId, ~inputJson, targetIds) => {
    let commandCount = targetIds->Array.length
    auditLog->Dict.set(
      requestId,
      {
        input: inputJson->JSON.stringify,
        status: Success,
        targetIds,
        commandCount,
        receivedAt: now(),
      },
    )
    Ok({ReventlessInfra.InboundTranslationSlice.requestId, targetIds, commandCount})
  }

  // Encoded with the command's schema, the one its target decodes with.
  let encode = ((targetId, cmd): (string, Spec.command)): result<
    Reventless.Message.commandJson,
    string,
  > =>
    try Ok({
      id: targetId,
      meta: makeMeta(),
      commandJson: cmd->Reventless.Util_Sury.toJson(Spec.commandSchema),
    }) catch {
    | exn =>
      EffectLogger.logError(
        ~comp=`InboundTranslationSlice(${Spec.name})`,
        `failed to encode command: ${messageOf(exn, "unknown")}`,
      )->Effect.runSync
      Error("failed to encode command")
    }

  let receive = async (
    publishJsons: ReventlessInfra.CommandTopic.publishJsons,
    inputJson: JSON.t,
    ~caller: option<Reventless.Identity.t>=?,
  ): ReventlessInfra.InboundTranslationSlice.receiveResult => {
    let requestId = Uuid.v4()
    let fail = (~errorCode=?, error) => failWith(~requestId, ~inputJson, ~errorCode?, error)
    let parsed = try Ok(inputJson->S.parseOrThrow(~to=Spec.externalInputSchema)) catch {
    | exn => Error(messageOf(exn, "invalid input"))
    }

    switch parsed {
    | Error(msg) => fail(msg)
    | Ok(input) =>
      switch Translation.translate(input) {
      | Error(msg) => fail(msg)
      | Ok(pairs) =>
        // Each command against its own rule; one refused refuses the message.
        let refused =
          pairs->Array.find(((_, cmd)) =>
            !callerAdmits(Spec.commandAuthorization(cmd)->Reventless.Authorization.named, caller)
          )
        switch refused {
        | Some(_) =>
          fail(
            ~errorCode="Forbidden",
            `${Spec.name}: the caller is not authorized for every command this input translates into`,
          )
        | None =>
          switch pairs->Array.reduce(Ok([]), (acc, pair) =>
            switch (acc, encode(pair)) {
            | (Ok(msgs), Ok(msg)) => Ok(msgs->Array.concat([msg]))
            | (Error(_) as failed, _) => failed
            | (_, Error(msg)) => Error(msg)
            }
          ) {
          | Error(msg) => fail(msg)
          | Ok([]) => succeed(~requestId, ~inputJson, [])
          | Ok(msgs) =>
            try {
              await publishJsons(msgs)
              succeed(~requestId, ~inputJson, pairs->Array.map(((targetId, _)) => targetId))
            } catch {
            | exn => fail(messageOf(exn, "publish failed"))
            }
          }
        }
      }
    }
  }
}
