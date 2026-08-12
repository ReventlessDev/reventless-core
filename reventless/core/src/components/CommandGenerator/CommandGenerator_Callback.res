type interceptResult = Allow | Deny(string)

type commandComponentKind = Aggregate | StateChangeSlice

type commandInterceptor = (
  ~identity: Reventless.Identity.t,
  ~componentName: string,
  ~componentKind: commandComponentKind,
  ~tag: string,
  ~args: JSON.t,
) => promise<interceptResult>

/** Module-level interceptor hook. None = passthrough (default). */
let commandInterceptorHook: ref<option<commandInterceptor>> = ref(None)

let registerCommandInterceptor = (interceptor: commandInterceptor) => {
  commandInterceptorHook.contents = Some(interceptor)
}

let clearCommandInterceptor = () => {
  commandInterceptorHook.contents = None
}

module type Spec = {
  let publishJsons: CommandGenerator.publishJsons
  let publishJsonsAndWait: option<CommandTopic.publishJsonsAndWait>
}

module type T = {
  let generateCommand: CommandGenerator.commandGenerator
}

/**
Overwrite every `@owner`-marked field of the command being issued with the
authenticated caller's id.

Deliberately here rather than in a transport's resolver. The local GraphQL
resolver and the AppSync mutation template build the same `payload` and both
hand it to `makeGenerateCommand`, so this is the only place a single edit is
true on both — and a rule enforced on one transport and not the other is worse
than no rule, because it reads as enforced.

**Overwrite, not fill-if-absent.** A caller who omits the field and a caller who
sends someone else's id must produce the same row. Filling only the absent case
passes every test that does not forge the field, and forging it is the whole
attack.

An exempt caller — the platform's own service traffic, or an operator — is left
alone, so acting on another principal's behalf stays possible for those who may.
A caller that cannot be identified is refused outright, but only for commands
that actually carry an owner: an anonymous caller invoking an `AllowAnonymous`
command with no owner field has nothing to prove and is not this rule's business.
*/
let stampOwnerFields = (
  obj: dict<JSON.t>,
  ~commandSchema: S.t<unknown>,
  ~command: string,
  ~identity: Reventless.Identity.t,
  ~serviceName: string,
) =>
  switch Reventless.Owner.variantFieldNames(commandSchema, ~variant=command) {
  | [] => ()
  | ownerFields =>
    switch identity->Reventless.OwnerScope.resolve {
    | System | Elevated(_) => ()
    | Owned({userId}) =>
      ownerFields->Array.forEach(field => obj->Dict.set(field, JSON.Encode.string(userId)))
    | Unidentified(why) =>
      JsError.throwWithMessage(
        `Forbidden: ${serviceName}.${command} records an owner, but the caller could not be identified (${why})`,
      )
    }
  }

let makeGenerateCommand = (
  ~publishJsons: CommandGenerator.publishJsons,
  ~publishJsonsAndWait: option<CommandTopic.publishJsonsAndWait>=?,
  ~serviceName: string,
  ~commandSchema: S.t<unknown>,
  ~componentKind: commandComponentKind,
  ~stripIdFromParams: bool=true,
): CommandGenerator.commandGenerator => {
  (payload: CommandGenerator.payload) =>
    Effect.sync(() => {
      let msgId = Message.uuid()
      let meta = {
        {
          Message.service: serviceName,
          ip: payload.meta.ip->Array.shift->Option.getOr(""),
          user: payload.meta.user,
          time: Message.nowAsISOString(),
          msgId,
          correlationId: msgId,
        }
      }
      let params = switch payload.arguments
      ->JSON.stringifyAny
      ->Option.flatMap(jsonString => jsonString->JSON.parseOrThrow->JSON.Decode.object) {
      | Some(obj) => {
          if stripIdFromParams {
            obj->Dict.delete("id")
          }
          obj->stampOwnerFields(
            ~commandSchema,
            ~command=payload.command,
            ~identity=payload.identity,
            ~serviceName,
          )
          obj->Dict.toArray
        }
      | None =>
        JsError.throwWithMessage(
          "Couldn't decode:" ++
          payload.arguments
          ->JSON.stringifyAny
          ->Option.getOr("<payload.arguments>"),
        )
      }
      let commandStr = JSON.Encode.string(payload.command)
      let commandJson = switch params->Array.length {
      | 0 => commandStr
      | _ => [("TAG", commandStr)]->Array.concat(params)->Dict.fromArray->JSON.Encode.object
      }
      // Resolve the envelope id.
      // - Aggregates always rely on the resolver-supplied id (id: ID! arg in SDL).
      // - DCB StateChangeSlices fall back to deriving the id from the command's
      //   partition tag(s) when the resolver didn't supply one — this is what makes
      //   @compositePartitionTag work end-to-end without per-call-site id stuffing.
      let suppliedId = payload.arguments.id
      let id = switch componentKind {
      | Aggregate => suppliedId
      | StateChangeSlice =>
        switch (suppliedId->Obj.magic: Nullable.t<string>)->Nullable.toOption {
        | Some(idValue) => idValue
        | None =>
          try {
            let derived = Reventless.DcbTag.derivePartitionTag([
              (serviceName, "", commandSchema),
            ])
            switch derived {
            | Simple(pt) =>
              let tags = Reventless.DcbTag.extractTagsFromJson(commandSchema, commandJson)
              Reventless.DcbTag.getPartitionTagValue([{tags: tags}], pt)->Option.getOr("")
            | Composite(spec) =>
              let tags = Reventless.DcbTag.extractTagsFromJson(commandSchema, commandJson)
              Reventless.DcbTag.getCompositePartitionKeyValue(tags, spec)
            }
          } catch {
          // Permissive schemas (e.g. S.json on the AppSync direct-invocation path)
          // have no tagged fields — derivePartitionTag throws. Fall back to "" so
          // existing transports keep their pre-fix behavior; the slice decoder
          // surfaces the missing id downstream as it did before.
          | _ => ""
          }
        }
      }
      (meta, commandJson, id)
    })
    ->Effect.tap(((_, commandJson, _id)) =>
      // Render `Name({fields})` without the standalone id: it's the command's
      // partition-tag value, already shown among the fields, so a leading
      // `(id)` would just duplicate it.
      EffectLogger.logInfo(
        ~comp=`CommandGenerator(${serviceName})`,
        ~detail=commandJson,
        `generated command: ${commandJson->LogFormat.cmdLabelOfJson}`,
      )
    )
    ->Effect.flatMap(((meta, commandJson, id)) => {
      switch commandJson->Message.decode(commandSchema) {
      | _ =>
        let interceptEffect = switch commandInterceptorHook.contents {
        | Some(interceptor) =>
          Effect.promise(() =>
            interceptor(
              ~identity=payload.identity,
              ~componentName=serviceName,
              ~componentKind,
              ~tag=payload.command,
              ~args=payload.arguments->Obj.magic,
            )
          )
        | None => Effect.succeed(Allow)
        }
        interceptEffect->Effect.flatMap(interceptResult =>
          switch interceptResult {
          | Allow =>
            switch publishJsonsAndWait {
            | Some(publishAndWait) =>
              Effect.promise(() => publishAndWait([{id, meta, commandJson}]))
              ->Effect.map(outcomes => {
                // For aggregates, entityId comes from the envelope id.
                // DCB slices populate entityId via the side-channel; don't override it.
                switch outcomes->Array.getUnsafe(0) {
                | CommandTopic.Accepted(payload) when payload.entityId->Option.isNone =>
                  CommandTopic.Accepted({...payload, entityId: id})
                | outcome => outcome
                }
              })
            | None =>
              Effect.promise(() => publishJsons([{id, meta, commandJson}]))
              ->Effect.map(_ => CommandTopic.Pending({msgId: meta.msgId}))
            }
          | Deny(msg) =>
            JsError.throwWithMessage(msg)
          }
        )
      | exception err =>
        switch Plugin_ResolverError.onResolverErrorHook.contents {
        | Some(hook) =>
          hook({
            pluginName: "",
            componentName: serviceName,
            attemptedCommandType: commandJson->Message.variantNameOfJson,
            timestamp: Message.nowAsISOString(),
          })
        | None => ()
        }
        JsError.throwWithMessage(
          `Error: Couldn't decode ${commandJson->JSON.stringify}: ${err
            ->JSON.stringifyAny
            ->Option.getOrThrow}`,
        )
      }
    })
}

module Make = (
  Spec: Spec,
  AggregateSpec: Reventless.Aggregate.Spec,
): T => {
  let generateCommand = makeGenerateCommand(
    ~publishJsons=Spec.publishJsons,
    ~publishJsonsAndWait=?Spec.publishJsonsAndWait,
    ~serviceName=AggregateSpec.name,
    ~commandSchema=AggregateSpec.commandSchema->S.castToUnknown,
    ~componentKind=Aggregate,
  )
}
