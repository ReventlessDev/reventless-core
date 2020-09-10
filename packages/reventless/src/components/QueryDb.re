let componentType = ComponentType.QueryDb;

type saveMode =
  | Init
  | Overwrite;

type storageError =
  | NotSavedToStorage(Js.Promise.error)
  | NotLoadedFromStorage(Js.Promise.error)
  | NotDeletedFromStorage(Js.Promise.error)
  | StaleState;

type load('id, 'state) =
  (. 'id) => Js.Promise.t(Belt.Result.t(list('state), storageError));
type save('id, 'state) =
  (. 'id, 'state, saveMode) =>
  Js.Promise.t(Belt.Result.t(unit, storageError));
type delete('id) =
  (. 'id, option((string, string))) =>
  Js.Promise.t(Belt.Result.t(unit, storageError));

type resolversResourcesMaker =
  InterstackResourceQuery.deploytimeQueryExn => array(Adapter.resource);

type functions('id, 'state) = {
  .
  "load": load('id, 'state),
  "save": save('id, 'state),
  "delete": delete('id),
};

type outputs = {
  .
  "storage": Adapter.resource,
  "resolvers": Adapter.resource,
  "resolversMaker": resolversResourcesMaker,
};
external toOutputs: functions('id, 'command) => outputs = "%identity";

type t('id, 'state) = functions('id, 'state);

module type T = {
  module Spec: View.Spec;
  module View: View.T with module Spec := Spec;

  type nonrec t = t(Spec.Id.t, View.state);

  let make: (~opts: Pulumi.ComponentResource.Options.t=?, unit) => t;
};

type storage = {
  resource: Adapter.resource,
  dataSourceName: Pulumi.Output.t(string), // TODO create in API
  load: load(string, Js.Json.t),
  save: save(string, Js.Json.t),
  delete: delete(string),
};
type storageMaker('api, 'role) =
  (
    ~name: string,
    ~indexes: list(View.index),
    ~sortField: option(string),
    ~api: 'api,
    ~apiRole: 'role,
    ~opts: Pulumi.CustomResourceOptions.t
  ) =>
  storage;

module type Storage = {
  type api;
  type role;

  let make: storageMaker(api, role);
};

type resolvers = {
  resources: array(Adapter.resource),
  resourcesMaker: resolversResourcesMaker,
};
type resolversMaker('api, 'role) =
  (
    ~name: string,
    ~api: 'api,
    ~apiRole: 'role,
    ~dataSourceName: Pulumi.Output.t(string),
    ~indexes: list(View.index),
    ~sortField: option(string),
    ~resolveIdConfigs: list(View.resolveIdConfig),
    ~resolveIdsConfigs: list(View.resolveIdsConfig),
    ~opts: Pulumi.CustomResourceOptions.t
  ) =>
  resolvers;

module type Resolvers = {
  type api;
  type role;

  let make: resolversMaker(api, role);
};

module Make =
       (
         Config: Config.T,
         Spec: View.Spec,
         View: View.T with module Spec := Spec,
         Storage:
           Storage with type api = Config.api and type role = Config.role,
         Resolvers:
           Resolvers with type api = Config.api and type role = Config.role,
       )
       : (T with module Spec = Spec and module View = View) => {
  module Spec = Spec;
  module View = View;

  type api = Config.api;
  type role = Config.role;

  type nonrec load = load(Spec.Id.t, View.state);
  type nonrec save = save(Spec.Id.t, View.state);
  type nonrec delete = delete(Spec.Id.t);

  type nonrec t = t(Spec.Id.t, View.state);

  type constructed;
  type construct = (t, string, api, role) => constructed;

  [@bs.module "./Component"] [@bs.new]
  external make:
    (
      ~componentType: string,
      ~name: string,
      ~construct: construct,
      ~opts: option(Pulumi.ComponentResource.Options.t),
      ~api: api,
      ~apiRole: role
    ) =>
    t =
    "default";

  [@bs.obj]
  external makeOutputs:
    (
      ~storage: Adapter.resource,
      ~resolvers: array(Adapter.resource),
      ~resolversMaker: resolversResourcesMaker
    ) =>
    outputs =
    "";

  [@bs.send]
  external registerOutputs: (t, outputs) => constructed = "registerOutputs";
  [@bs.send] external setOutputs: (t, outputs) => unit = "setOutputs";
  let setOutputs = (self, outputs) => {
    self->setOutputs(outputs);
    self->registerOutputs(outputs);
  };

  [@bs.set] external setLoad: (t, load) => unit = "load";
  [@bs.set] external setSave: (t, save) => unit = "save";
  [@bs.set] external setDelete: (t, delete) => unit = "delete";

  let decode = (id, item) =>
    switch (View.state_decode(item)) {
    | Ok(state) => [state]
    | Error(err) =>
      Js.log({j|QueryDb: Error: Couldn't decode state for $id: $err|j});
      [];
    };

  let load = storage =>
    (. id) =>
      storage.load(. id |> Spec.Id.toString)
      |> Js.Promise.then_(result =>
           result
           ->Belt.Result.map(states =>
               states->Belt.List.map(decode(id))->Belt.List.flatten
             )
           ->Js.Promise.resolve
         );

  let save = storage =>
    (. id, state, saveMode) => {
      switch (state |> View.state_encode |> Js.Json.decodeObject) {
      | Some(dict) =>
        dict->Js.Dict.set("id", Spec.Id.t_encode(id));
        let json = Js.Json.object_(dict);
        storage.save(. id |> Spec.Id.toString, json, saveMode);
      | None =>
        Js.log("QueryDB.save: Error: Couldn't decodeObject");
        Belt.Result.Error(
          NotSavedToStorage("Couldn't decodeObject"->Obj.magic),
        )
        |> Js.Promise.resolve;
      };
    };

  let delete = storage =>
    (. id, sort) => {
      storage.delete(. id |> Spec.Id.toString, sort);
    };

  let construct = (self, name, api, apiRole) => {
    let opts =
      Pulumi.CustomResourceOptions.make(
        ~parent=self->Pulumi.Resource.makeFromJs,
        (),
      );

    let sortField =
      View.sortConfig->Belt.Option.map(config => config.sortField);
    let storage =
      Storage.make(
        ~name=name->ComponentType.name(componentType),
        ~indexes=View.indexes,
        ~sortField,
        ~api,
        ~apiRole,
        ~opts,
      );

    self->setLoad(storage->load);
    self->setSave(storage->save);
    self->setDelete(storage->delete);

    let resolvers =
      Resolvers.make(
        ~name,
        ~api,
        ~apiRole,
        ~dataSourceName=storage.dataSourceName,
        ~indexes=View.indexes,
        ~sortField,
        ~resolveIdConfigs=View.resolveIdConfigs,
        ~resolveIdsConfigs=View.resolveIdsConfigs,
        ~opts,
      );

    makeOutputs(
      ~storage=storage.resource,
      ~resolvers=resolvers.resources,
      ~resolversMaker=resolvers.resourcesMaker,
    )
    |> self->setOutputs;
  };

  let make: (~opts: Pulumi.ComponentResource.Options.t=?, unit) => t =
    (~opts=?, _) => {
      make(
        ~componentType=componentType->ComponentType.toString,
        ~name=View.name |> Js.Option.getWithDefault(Spec.name),
        ~construct,
        ~opts,
        ~api=Config.api,
        ~apiRole=Config.apiRole,
      );
    };
};
