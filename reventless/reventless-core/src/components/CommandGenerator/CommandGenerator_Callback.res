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

module type Spec = {
  let publishJsons: CommandGenerator.publishJsons
}

module type T = {
  let generateCommand: CommandGenerator.commandGenerator
}

let makeGenerateCommand = (
  ~publishJsons: CommandGenerator.publishJsons,
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
    ->Effect.tap(((_, commandJson, _)) =>
      Effect.logInfo(
        "CommandGenerator: generated command: " ++ commandJson->JSON.stringify,
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
            Effect.promise(() => publishJsons([{id, meta, commandJson}]))
            ->Effect.map(_ => meta.msgId)
          | Deny(msg) =>
            JsError.throwWithMessage(msg)
          }
        )
      | exception err =>
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
    ~serviceName=AggregateSpec.name,
    ~commandSchema=AggregateSpec.commandSchema->S.castToUnknown,
    ~componentKind=Aggregate,
  )
}
