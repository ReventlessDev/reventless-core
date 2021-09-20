open ReventlessSpec.Adapter;

let componentType = ComponentType.ReadModel;

type outputs = {. "queryDb": QueryDb.outputs};

type update('id, 'event) = Message.eventsHandler('id, 'event);

// type functions('id, 'event) = {. "update": update('id, 'event)};

// external toOutputs: functions('id, 'event) => outputs = "%identity";

// type t('id, 'event) = functions('id, 'event);

module type T = {
  module Spec: View.Spec;
  module View: View.T with module Spec := Spec;
  type t;

  /* Is this necessary? For test?
     let update:
       (
         QueryDb.load(Spec.Id.t, View.state),
         QueryDb.save(Spec.Id.t, View.state),
         QueryDb.delete(Spec.Id.t)
       ) =>
       update(Spec.Id.t, Spec.event);
       */
  let update: Component.t(t, outputs) => update(Spec.Id.t, Spec.event);

  let make:
    (
      ~opts: Pulumi.ComponentResource.Options.t=?,
      ~resources: resources,
      unit
    ) =>
    Component.t(t, outputs);
};

module Make =
       (
         Config: Config.T,
         Spec: View.Spec,
         View: View.T with module Spec := Spec,
         QueryDbStorage:
           QueryDb.Adapter.Storage with
             type api = Config.api and type role = Config.role,
         QueryDbResolvers:
           QueryDb.Adapter.Resolvers with
             type api = Config.api and type role = Config.role,
       )
       : (T with module Spec = Spec and module View = View) => {
  module Spec = Spec;
  module View = View;
  type t;

  type update = Message.eventsHandler(Spec.Id.t, Spec.event);

  type constructed;
  type construct =
    (Component.t(t, outputs), string, resources) => constructed;

  [@bs.module "./Component"] [@bs.new]
  external make:
    (
      ~componentType: string,
      ~name: string,
      ~construct: construct,
      ~opts: option(Pulumi.ComponentResource.Options.t),
      ~resources: resources
    ) =>
    Component.t(t, outputs) =
    "default";

  module QueryDb =
    QueryDb.Make(Config, Spec, View, QueryDbStorage, QueryDbResolvers);

  [@bs.obj]
  external makeOutputs: (~queryDb: Reventless.QueryDb.outputs) => outputs = "";
  [@bs.send]
  external registerOutputs: (Component.t(t, outputs), outputs) => constructed =
    "registerOutputs";
  [@bs.send]
  external setOutputs: (Component.t(t, outputs), outputs) => unit =
    "setOutputs";
  let setOutputs = (self, outputs) => {
    self->setOutputs(outputs);
    self->registerOutputs(outputs);
  };

  [@bs.set]
  external setUpdate: (Component.t(t, outputs), update) => unit = "update";
  [@bs.get] external update: Component.t(t, outputs) => update = "update";

  open Reventless.View;

  let applyEvent = (states, event, context) =>
    switch (states) {
    | [] =>
      let newStates = View.init(. event, context);
      newStates->Belt.List.map(state => Create(state));
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

  let updateFn = (load, save, delete): update =>
    (. id, event's) =>
      Js.Promise.(
        {
          let handleAction =
            fun
            | Create(state) =>
              save(. id, state, Reventless.QueryDb.Init, None)
            | Update(state) =>
              save(. id, state, Reventless.QueryDb.Overwrite, None)
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
                   | Error(Reventless.QueryDb.StaleState) => {
                       Js.log(
                         "ReadModel.handleActions: retrying due to StaleState",
                       );
                       Error([])->resolve;
                     }
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
                         actions
                         ->Belt.List.map(applyAction)
                         ->Belt.List.flatten;
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
          process(event's->Belt.List.fromArray, []);
        }
      );

  let construct = (self, _, resources) => {
    let opts =
      Pulumi.ComponentResource.Options.make(
        ~parent=self->Component.toPulumiResource,
        (),
      );

    let queryDb = QueryDb.make(~opts, ~resources, ());

    updateFn(
      queryDb->QueryDb.load,
      queryDb->QueryDb.save,
      queryDb->QueryDb.delete,
    )
    |> self->setUpdate;

    makeOutputs(~queryDb=queryDb->Component.extractOutputs)
    |> self->setOutputs;
  };

  let make = (~opts=?, ~resources, _) => {
    make(
      ~componentType=componentType->ComponentType.toString,
      ~name=View.name |> Js.Option.getWithDefault(Spec.name),
      ~construct,
      ~opts,
      ~resources,
    );
  };
};
