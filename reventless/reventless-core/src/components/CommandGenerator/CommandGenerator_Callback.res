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
      let id = payload.arguments.id
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
      (meta, commandJson, id)
    })
    ->Effect.tap(((_, commandJson, id)) => {
      let name = commandJson->Message.variantNameOfJson->LogFormat.bold
      EffectLogger.logInfo(
        ~comp=`CommandGenerator(${serviceName})`,
        ~detail=commandJson,
        `generated command: ${name}(${id}${LogFormat.variantFields(commandJson)})`,
      )
    })
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
