open ReventlessSpec.Adapter

let componentType = ComponentType.EventLog

type outputs = {"resources": array<resource>, "eventTopic": ReventlessSpec.EventTopic.outputs}

type t
type component = ReventlessSpec.Component.t<t, outputs>

exception ReplayError(string)

type append<'id, 'event> = (. int, 'id, array<'event>) => promise<Belt.Result.t<unit, string>>
type replay<'id, 'event> = (. 'id) => promise<array<'event>>

module type Spec = {
  module Id: ReventlessSpec.Id.T

  let name: string

  @decco
  type event
}

module type T = {
  module Spec: Spec

  let make: (~name: string, ~opts: Pulumi.ComponentResource.Options.t=?, unit) => component

  let append: component => append<Spec.Id.t, Message.event'<Spec.Id.t, Spec.event>>
  let replay: component => replay<Spec.Id.t, Spec.event>
}

module Adapter = {
  type storage = {
    resources: array<resource>,
    append: append<string, Js.Json.t>,
    replay: replay<string, Js.Json.t>,
  }
  type storageMaker = (~name: string, ~opts: Pulumi.CustomResourceOptions.t) => storage

  module type Storage = {
    let make: storageMaker
  }
}

module AppendUtil = {
  let eventToJson: (
    'specId => Js.Json.t,
    'specEvent => Js.Json.t,
    'specId,
    Message.event'<'specId, 'specEvent>,
  ) => Js.Json.t = (specIdEncode, specEventEncode, id, event') =>
    [
      ("id", specIdEncode(id)),
      (
        "sequenceNr",
        Js.Json.string(Message.hrtimeToString(~hrtime=Message.hrtime(), ~now=Message.now())),
      ),
      ("event", event'.event->specEventEncode),
    ]
    ->Belt.Array.concat(event'.meta->Message.decomposeMeta)
    ->Js.Dict.fromArray
    ->Js.Json.object_

  let eventsToJson: (
    array<Reventless.Message.event'<'specId, 'specEvent>>,
    'specId => Js.Json.t,
    'specEvent => Js.Json.t,
    'specId,
  ) => array<Js.Json.t> = (events', specIdEncode, specEventEncode, id) =>
    events'->Belt.Array.map(eventToJson(specIdEncode, specEventEncode, id))

  let storageAppendErrorHandler: (
    string,
    'specId => string,
    'specId,
    Js.Exn.t,
  ) => result<unit, string> = (specName, specIdToString, id, err) => {
    let errMsg =
      `EventLog: Error: Couldn't append for ${specName}(${id->specIdToString}):` ++
      err->Js.Exn.message->Belt.Option.getWithDefault("no error message given")
    Js.log(errMsg)
    errMsg->Belt.Result.Error
  }

  let publishToEventTopic: (
    EventTopic.publish<'specId, 'specEvent>,
    'specId => string,
    'specId,
    array<Reventless.Message.event'<'specId, 'specEvent>>,
  ) => promise<unit> = async (eventTopicPublish, specIdToString, id, events') => {
    try await eventTopicPublish(. events') catch {
    | Js.Exn.Error(err) =>
      let msg = `EventLog.appendFn(${id->specIdToString}): EventTopic.publish Error: `
      Js.log2(msg, err)
      Js.Exn.raiseError(
        msg ++ err->Js.Exn.message->Belt.Option.getWithDefault("no error message given"),
      )
    }
  }

  let catchErrorHandler = exn => {
    Js.log2("EventLog.append: Error:", exn)
    raise(exn)
  }

  // FIXME: appendFn is supposed to return result<unit, string/*errorMessage*/>, but at the same moment, we throw errors
  //        We should use result everywhere instead of throwing errors / exceptions
  let appendFn = (
    storageAppend: append<string, Js.Json.t>,
    specIdToString: 'specId => string,
    specIdEncode: 'specId => Js.Json.t,
    specEventEncode: 'specEvent => Js.Json.t,
    eventTopicPublish: EventTopic.publish<'specId, 'specEvent>,
    specName: string,
  ) =>
    async (.
      sequenceNr: int,
      id: 'specId,
      events': array<Reventless.Message.event'<'specId, 'specEvent>>,
    ) => {
      try {
        let eventsJson = events'->eventsToJson(specIdEncode, specEventEncode, id)

        switch await storageAppend(. sequenceNr, id->specIdToString, eventsJson) {
        | appendResult =>
          await publishToEventTopic(eventTopicPublish, specIdToString, id, events')
          appendResult
        | exception Js.Exn.Error(err) =>
          storageAppendErrorHandler(specName, specIdToString, id, err)
        }
      } catch {
      | exn => catchErrorHandler(exn)
      }
    }
}

module ReplayUtil = {
  let decodeEvent = (specEventDecode, json) =>
    Js.Json.decodeObject(json)
    ->Belt.Option.flatMap(dict => dict->Js.Dict.get("event"))
    ->Belt.Option.map(json => (json, specEventDecode(json)))
    ->Belt.Option.map(x =>
      switch x {
      | (_, Belt.Result.Ok(event)) => event
      | (json, Error(err: Decco.decodeError)) =>
        let eventStr = json->Js.Json.stringify
        let message = err.message
        Js.Exn.raiseError(`EventLog.replay: Error: Couldn't decode ${eventStr}: ${message}`)
      }
    )
    ->(
      x =>
        switch x {
        | Some(event) => event
        | None =>
          let eventStr = json->Js.Json.stringify
          Js.Exn.raiseError(`EventLog.replay: Error: Couldn't decodeObject ${eventStr}`)
        }
    )

  let decodeEvents = (jsons, specEventDecode) => jsons->Belt.Array.map(decodeEvent(specEventDecode))

  let decodeEventsToPromise: (
    Js.Json.t => result<'a, Decco.decodeError>,
    array<Js.Json.t>,
  ) => promise<array<'a>> = (specEventDecode, jsons) =>
    decodeEvents(jsons, specEventDecode)->Js.Promise2.resolve

  let replayFn: (
    replay<string, Js.Json.t>,
    'specId => string,
    Js.Json.t => result<'specEvent, Decco.decodeError>,
  ) => (. 'specId) => promise<array<'specEvent>> = (
    storageReplay,
    specIdToString,
    specEventDecode,
  ) =>
    async (. id) => {
      let jsonEvents = await storageReplay(. id->specIdToString)
      await decodeEventsToPromise(specEventDecode, jsonEvents)
    }
}

module Make = (
  Spec: Spec,
  Storage: Adapter.Storage,
  EventTopicPublisher: EventTopic.Adapter.Publisher,
): (T with module Spec = Spec) => {
  module Spec = Spec

  type constructed
  type construct = (component, string) => constructed

  type append = append<Spec.Id.t, Message.event'<Spec.Id.t, Spec.event>>
  type replay = replay<Spec.Id.t, Spec.event>

  @module("./Component") @new
  external make: (
    ~componentType: string,
    ~name: string,
    ~construct: construct,
    ~opts: option<Pulumi.ComponentResource.Options.t>,
  ) => component = "default"

  @obj
  external makeOutputs: (~resources: array<resource>, ~eventTopic: ReventlessSpec.EventTopic.outputs) => outputs =
    ""

  @send
  external registerOutputs: (component, outputs) => constructed = "registerOutputs"
  @send external setOutputs: (component, outputs) => unit = "setOutputs"
  let setOutputs = (self, outputs) => {
    self->setOutputs(outputs)
    self->registerOutputs(outputs)
  }

  @set external setAppend: (component, append) => unit = "append"
  @set external setReplay: (component, replay) => unit = "replay"
  @get external append: component => append = "append"
  @get external replay: component => replay = "replay"

  module EventTopic = EventTopic.Make(Spec, EventTopicPublisher)

  let construct = (self, name) => {
    let opts = Pulumi.CustomResourceOptions.make(~parent=self->Component.toPulumiResource, ())

    let storage = Storage.make(~name=name->ComponentType.name(componentType), ~opts)

    let eventTopic = EventTopic.make(
      ~name,
      ~storageResources=storage.resources,
      ~opts=opts->Util.Pulumi.ComponentResourceOptions.ofCustomResourceOptions,
      (),
    )

    self->setAppend(
      AppendUtil.appendFn(
        storage.Adapter.append,
        Spec.Id.toString,
        Spec.Id.t_encode,
        Spec.event_encode,
        eventTopic->EventTopic.publish,
        Spec.name,
      ),
    )
    self->setReplay(
      ReplayUtil.replayFn(storage.Adapter.replay, Spec.Id.toString, Spec.event_decode),
    )

    makeOutputs(
      ~resources=storage.resources,
      ~eventTopic=eventTopic->Component.extractOutputs,
    )->setOutputs(self, _)
  }

  let make = (~name, ~opts=?, _) =>
    make(~componentType=componentType->ComponentType.toString, ~name, ~construct, ~opts)
}
