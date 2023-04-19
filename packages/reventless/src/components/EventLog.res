open ReventlessSpec.Adapter

let componentType = ComponentType.EventLog

type outputs = {"resources": array<resource>, "eventTopic": EventTopic.outputs}

type t
type component = Component.t<t, outputs>

exception ReplayError(string)

type append<'id, 'event> = (. int, 'id, array<'event>) => Js.Promise.t<Belt.Result.t<unit, string>>
type replay<'id, 'event> = (. 'id) => Js.Promise.t<array<'event>>

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

  let eventsToJson = (events', specIdEncode, specEventEncode, id) =>
    events'->Belt.Array.map(eventToJson(specIdEncode, specEventEncode, id))

  let storageAppendErrorHandler = (aggregateName, specIdToString, id, err) => {
    let errMsg =
      `EventLog: Error: Couldn't append for ${aggregateName}(${id->specIdToString}):` ++
      (err->Util.Error.ofPromise).message
    Js.log(errMsg)
    errMsg->Belt.Result.Error->Js.Promise2.resolve
  }

  let publishToEventTopic = (eventTopicPublish, specIdToString, id, events', result) => {
    let _publishResult = eventTopicPublish(. events')->Js.Promise2.catch(err => {
      let msg = `EventLog.appendFn(${id->specIdToString}): EventTopic.publish Error: `
      Js.log2(msg, err)
      Js.Exn.raiseError(msg ++ (err->Reventless.Util.Error.ofPromise).message)
    })

    result->Js.Promise2.resolve
  }

  let catchErrorHandler = exn => {
    Js.log2("EventLog.append: Couldn't decode:", exn)
    raise(exn)
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
  ) => Js.Promise2.t<array<'a>> = (specEventDecode, jsons) =>
    decodeEvents(jsons, specEventDecode)->Js.Promise2.resolve

  let replayFn: (
    replay<string, Js.Json.t>,
    'specId => string,
    Js.Json.t => result<'specEvent, Decco.decodeError>,
  ) => (. 'specId) => Js.Promise2.t<array<'specEvent>> = (
    storageReplay,
    specIdToString,
    specEventDecode,
  ) =>
    (. id) => {
      storageReplay(. id->specIdToString)->Js.Promise2.then(decodeEventsToPromise(specEventDecode))
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
  external makeOutputs: (~resources: array<resource>, ~eventTopic: EventTopic.outputs) => outputs =
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

  let appendFn = (storage, eventTopic) =>
    (. sequenceNr, id, events') => {
      open AppendUtil
      try {
        events'
        ->eventsToJson(Spec.Id.t_encode, Spec.event_encode, id)
        ->storage.Adapter.append(. sequenceNr, id->Spec.Id.toString, _)
        ->Js.Promise2.catch(storageAppendErrorHandler(Spec.name, Spec.Id.toString, id))
        ->Js.Promise2.then(
          publishToEventTopic(eventTopic->EventTopic.publish, Spec.Id.toString, id, events'),
        )
      } catch {
      | exn => catchErrorHandler(exn)
      }
    }

  let construct = (self, name) => {
    let opts = Pulumi.CustomResourceOptions.make(~parent=self->Component.toPulumiResource, ())

    let storage = Storage.make(~name=name->ComponentType.name(componentType), ~opts)

    let eventTopic = EventTopic.make(
      ~name,
      ~storageResources=storage.resources,
      ~opts=opts->Util.Pulumi.ComponentResourceOptions.ofCustomResourceOptions,
      (),
    )

    self->setAppend(appendFn(storage, eventTopic))
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
