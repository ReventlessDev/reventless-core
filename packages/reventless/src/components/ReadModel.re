let componentType = ComponentType.ReadModel;

type update('id, 'event) = Message.eventsHandler('id, 'event);

type functions('id, 'event) = {. "update": update('id, 'event)};

type outputs = {. "queryDb": QueryDb.outputs};
external toOutputs: functions('id, 'event) => outputs = "%identity";

type t('id, 'event) = functions('id, 'event);

type maker('id, 'event) =
  option(Pulumi.ComponentResource.Options.t) => t('id, 'event);

module type T = {
  module Spec: View.Spec;
  module View: View.T with module Spec := Spec;

  let update:
    (
      QueryDb.load(Spec.Id.t, View.state),
      QueryDb.save(Spec.Id.t, View.state),
      QueryDb.delete(Spec.Id.t)
    ) =>
    update(Spec.Id.t, Spec.event);

  let make: maker(Spec.Id.t, Spec.event);
};

module Make =
       (
         Spec: View.Spec,
         View: View.T with module Spec := Spec,
         QueryDb: QueryDb.T with module Spec := Spec and module View := View,
       )
       : (T with module Spec = Spec and module View = View) => {
  module Spec = Spec;
  module View = View;

  type queryDb = QueryDb.t;

  type update = Message.eventsHandler(Spec.Id.t, Spec.event);

  type nonrec t = t(Spec.Id.t, Spec.event);

  type constructed;
  type construct = (t, string) => constructed;

  [@bs.module "./Component"] [@bs.new]
  external make:
    (
      ~componentType: string,
      ~name: string,
      ~construct: construct,
      ~opts: option(Pulumi.ComponentResource.Options.t)
    ) =>
    t =
    "default";

  [@bs.obj] external makeOutputs: (~queryDb: queryDb) => outputs = "";
  [@bs.send]
  external registerOutputs: (t, outputs) => constructed = "registerOutputs";
  [@bs.send] external setOutputs: (t, outputs) => unit = "setOutputs";
  let setOutputs = (self, outputs) => {
    self->setOutputs(outputs);
    self->registerOutputs(outputs);
  };

  [@bs.set] external setUpdate: (t, update) => unit = "update";

  open Reventless.View;

  let applyEvent = (states, event, context) =>
    switch (states) {
    | [] =>
      let newStates = View.init(. event, context);
      newStates |> List.map(state => Create(state));
    | [oldState] => View.apply(. oldState, event, context)
    | oldStates => View.applyMulti(. oldStates, event, context)
    };

  let applyAction = action =>
    switch (action) {
    | Create(state) => [state]
    | Update(newState) => [newState]
    | Delete(_) => []
    | Unchanged(state) => [state]
    };

  open Belt.Result;

  let update = (load, save, delete): update =>
    (. id, event's) =>
      Js.Promise.(
        {
          let handleAction =
            fun
            | Create(state) => save(. id, state, Reventless.QueryDb.Init)
            | Update(state) =>
              save(. id, state, Reventless.QueryDb.Overwrite)
            | Delete(state) =>
              delete(.
                id,
                View.sortConfig->Belt.Option.map(config =>
                  (config.sortField, config.getSortKey(state))
                ),
              )
            | Unchanged(_) => Ok()->resolve;

          let rec handleActions =
            fun
            | [] => Ok()->resolve
            | [action, ...unhandledActions] as actions =>
              action->handleAction
              |> then_(
                   fun
                   | Error(Reventless.QueryDb.StaleState) =>
                     Error([])->resolve
                   | Error(_) => Error(actions)->resolve
                   | Ok () => handleActions(unhandledActions),
                 );

          let rec handleEvents =
                  (
                    states,
                    event's: list(Message.event'(Spec.Id.t, Spec.event)),
                    unhandledActions,
                  ) => {
            switch (event's) {
            | [] => Ok()->resolve
            | [event', ...unhandledEvent's] =>
              let context = {
                Message.meta: event'.meta,
                id: event'.id |> Spec.Id.toString,
              };
              let actions =
                switch (unhandledActions) {
                | [] => states->applyEvent(event'.event, context)
                | _ => unhandledActions
                };
              handleActions(actions)
              |> then_(
                   fun
                   | Ok () => {
                       let newStates =
                         actions |> List.map(applyAction) |> List.flatten;
                       handleEvents(newStates, unhandledEvent's, []);
                     }
                   | Error(unhandledActions) =>
                     Error((event's, unhandledActions))->resolve,
                 );
            };
          };

          let rec process = (event's, unhandledActions) =>
            load(. id)
            |> then_(
                 fun
                 | Ok(states) =>
                   handleEvents(states, event's, unhandledActions)
                   |> then_(
                        fun
                        | Ok () => resolve()
                        | Error((unhandledEvent's, unhandledActions)) =>
                          process(unhandledEvent's, unhandledActions),
                      )
                 | Error(_) => process(event's, []),
               );
          process(event's |> Array.to_list, []);
        }
      );

  let construct = (self, _) => {
    let opts =
      Pulumi.ComponentResource.Options.make(
        ~parent=self->Pulumi.Resource.makeFromJs,
        (),
      );
    let queryDb = QueryDb.make(~opts, ());

    update(queryDb##load, queryDb##save, queryDb##delete) |> self->setUpdate;

    makeOutputs(~queryDb) |> self->setOutputs;
  };

  let make = opts => {
    make(
      ~componentType=componentType->ComponentType.toString,
      ~name=View.name |> Js.Option.getWithDefault(Spec.name),
      ~construct,
      ~opts,
    );
  };
};
