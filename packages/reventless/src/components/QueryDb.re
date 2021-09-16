open ReventlessSpec.Adapter;

let componentType = ComponentType.QueryDb;

type resolversResourcesMaker = resources => array(resource);

type outputs = {
  .
  "storage": resource,
  "resolvers": resource,
  "resolversMaker": resolversResourcesMaker,
};

type saveMode =
  | Init
  | Overwrite;

type storageError =
  | NotSavedToStorage(Js.Promise.error)
  | NotLoadedFromStorage(Js.Promise.error)
  | NotCountedOnStorage(Js.Promise.error)
  | NotDeletedFromStorage(Js.Promise.error)
  | StaleState;

type load('id, 'state) =
  (. 'id) => Js.Promise.t(Belt.Result.t(list('state), storageError));
type save('id, 'state) =
  (. 'id, 'state, saveMode) =>
  Js.Promise.t(Belt.Result.t(unit, storageError));
type count('id) =
  (. 'id, string, int) => Js.Promise.t(Belt.Result.t(int, storageError));
type delete('id) =
  (. 'id, option((string, string))) =>
  Js.Promise.t(Belt.Result.t(unit, storageError));

module type T = {
  module Spec: View.Spec;
  module View: View.T with module Spec := Spec;

  type t;
  type nonrec load = load(Spec.Id.t, View.state);
  type nonrec save = save(Spec.Id.t, View.state);
  type nonrec count = count(Spec.Id.t);
  type nonrec delete = delete(Spec.Id.t);

  let make:
    (
      ~ttl: int=?,
      ~opts: Pulumi.ComponentResource.Options.t=?,
      ~resources: resources,
      unit
    ) =>
    Component.t(t, outputs);

  let load: Component.t(t, outputs) => load;
  let save: Component.t(t, outputs) => save;
  let count: Component.t(t, outputs) => count;
  let delete: Component.t(t, outputs) => delete;

  let outputs: Component.t(t, outputs) => outputs;
};

module Adapter = {
  type storage = {
    resource,
    dataSourceName: Pulumi.Output.t(string), // TODO create in API
    load: load(string, Js.Json.t),
    save: save(string, Js.Json.t),
    count: count(string),
    delete: delete(string),
  };
  type storageMaker('api, 'role) =
    (
      ~name: string,
      ~indexes: list(View.index),
      ~sortField: option(string),
      ~ttl: option(int),
      ~api: 'api,
      ~apiRole: 'role,
      ~opts: Pulumi.CustomResourceOptions.t,
      ~resources: resources
    ) =>
    storage;

  module type Storage = {
    type api;
    type role;

    let make: storageMaker(api, role);
  };

  type queryEngineMaker = resources => ReventlessSpec.QueryEngine.t;

  module type QueryEngineAdapter = {let make: queryEngineMaker;};

  type resolvers = {
    resources: array(resource),
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
};

module Make =
       (
         Config: Config.T,
         Spec: View.Spec,
         View: View.T with module Spec := Spec,
         Storage:
           Adapter.Storage with
             type api = Config.api and type role = Config.role,
         Resolvers:
           Adapter.Resolvers with
             type api = Config.api and type role = Config.role,
       )
       : (T with module Spec = Spec and module View = View) => {
  module Spec = Spec;
  module View = View;

  type api = Config.api;
  type role = Config.role;

  type t;

  type nonrec load = load(Spec.Id.t, View.state);
  type nonrec save = save(Spec.Id.t, View.state);
  type nonrec count = count(Spec.Id.t);
  type nonrec delete = delete(Spec.Id.t);

  type constructed;
  type construct =
    (Component.t(t, outputs), string, api, role, resources) => constructed;

  [@bs.module "./Component"] [@bs.new]
  external make:
    (
      ~componentType: string,
      ~name: string,
      ~construct: construct,
      ~opts: option(Pulumi.ComponentResource.Options.t),
      ~api: api,
      ~apiRole: role,
      ~resources: resources
    ) =>
    Component.t(t, outputs) =
    "default";

  [@bs.obj]
  external makeOutputs:
    (
      ~storage: resource,
      ~resolvers: array(resource),
      ~resolversMaker: resolversResourcesMaker
    ) =>
    outputs =
    "";

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
  external setLoad: (Component.t(t, outputs), load) => unit = "load";
  [@bs.set]
  external setSave: (Component.t(t, outputs), save) => unit = "save";
  [@bs.set]
  external setCount: (Component.t(t, outputs), count) => unit = "count";
  [@bs.set]
  external setDelete: (Component.t(t, outputs), delete) => unit = "delete";

  [@bs.get] external load: Component.t(t, outputs) => load = "load";
  [@bs.get] external save: Component.t(t, outputs) => save = "save";
  [@bs.get] external count: Component.t(t, outputs) => count = "count";
  [@bs.get] external delete: Component.t(t, outputs) => delete = "delete";

  let decode = (id, item) =>
    switch (View.state_decode(item)) {
    | Ok(state) => [state]
    | Error(err) =>
      Js.log({j|QueryDb: Error: Couldn't decode state for $id: $err|j});
      [];
    };

  let loadFn = storage =>
    (. id) =>
      storage.Adapter.load(. id->Spec.Id.toString)
      |> Js.Promise.then_(result =>
           result
           ->Belt.Result.map(states =>
               states->Belt.List.map(decode(id))->Belt.List.flatten
             )
           ->Js.Promise.resolve
         );

  let saveFn = storage =>
    (. id, state, saveMode) => {
      switch (state->View.state_encode->Js.Json.decodeObject) {
      | Some(dict) =>
        dict->Js.Dict.set("id", Spec.Id.t_encode(id));
        let json = Js.Json.object_(dict);
        storage.Adapter.save(. id->Spec.Id.toString, json, saveMode);
      | None =>
        Js.log("QueryDB.save: Error: Couldn't decodeObject");
        Belt.Result.Error(
          NotSavedToStorage("Couldn't decodeObject"->Obj.magic),
        )
        ->Js.Promise.resolve;
      };
    };

  let countFn = storage =>
    (. id, fieldName, value) => {
      storage.Adapter.count(. id->Spec.Id.toString, fieldName, value);
    };

  let deleteFn = storage =>
    (. id, sort) => {
      storage.Adapter.delete(. id->Spec.Id.toString, sort);
    };

  let outputs: Component.t(t, outputs) => outputs =
    component => Component.extractOutputs(component);

  let construct = (~ttl, self, name, api, apiRole, resources) => {
    let opts =
      Pulumi.CustomResourceOptions.make(
        ~parent=self->Component.toPulumiResource,
        (),
      );

    let sortField =
      View.sortConfig->Belt.Option.map(config => config.sortField);
    let storageName = name->ComponentType.name(componentType);
    let storage =
      Storage.make(
        ~name=storageName,
        ~indexes=View.indexes,
        ~sortField,
        ~ttl,
        ~api,
        ~apiRole,
        ~opts,
        ~resources,
      );
    resources->Util_QueryDb.setStorageResource(storage.resource, storageName);

    self->setLoad(storage->loadFn);
    self->setSave(storage->saveFn);
    self->setCount(storage->countFn);
    self->setDelete(storage->deleteFn);

    /*
     let load: Component.t(t, outputs) => load = _component => load(storage);
     let save: Component.t(t, outputs) => save  = _component => save(storage);
     let delete: Component.t(t, outputs) => delete  = _component => delete(storage);
     */

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

  let make:
    (
      ~ttl: int=?,
      ~opts: Pulumi.ComponentResource.Options.t=?,
      ~resources: resources,
      unit
    ) =>
    Component.t(t, outputs) =
    (~ttl=?, ~opts=?, ~resources, _) => {
      make(
        ~componentType=componentType->ComponentType.toString,
        ~name=View.name->Belt.Option.getWithDefault(Spec.name),
        ~construct=construct(~ttl),
        ~opts,
        ~api=Config.api,
        ~apiRole=Config.apiRole,
        ~resources,
      );
    };
};
