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
  | NotSavedToStorage(string)
  | NotLoadedFromStorage(string)
  | NotCountedOnStorage(string)
  | NotDeletedFromStorage(string)
  | StaleState;

type load('id, 'state) =
  (. 'id) => Js.Promise.t(Belt.Result.t(list('state), storageError));
type save('id, 'state) =
  (. 'id, 'state, saveMode, option(int)) =>
  Js.Promise.t(Belt.Result.t(unit, storageError));
type saveBatch('id, 'state) =
  (. array(('id, 'state, option(int)))) =>
  Js.Promise.t(Belt.Result.t(unit, storageError));
type count('id) =
  (. 'id, string, int) => Js.Promise.t(Belt.Result.t(int, storageError));
type delete('id) =
  (. 'id, option((string, string))) =>
  Js.Promise.t(Belt.Result.t(unit, storageError));

module type AggregateSpec = {
  module Id: ReventlessSpec.Id.T;
  let name: string;
};

module type ViewSpec = {
  let name: option(string);

  [@decco]
  type state;

  let resolveIdConfigs: list(View.resolveIdConfig);
  let resolveIdsConfigs: list(View.resolveIdsConfig);

  let sortConfig: option(View.sortConfig(state));

  let indexes: list(View.index);
};

module type T = {
  module Spec: AggregateSpec;
  module ViewSpec: ViewSpec;

  type t;
  type nonrec load = load(Spec.Id.t, ViewSpec.state);
  type nonrec save = save(Spec.Id.t, ViewSpec.state);
  type nonrec saveBatch = saveBatch(Spec.Id.t, ViewSpec.state);
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
  let saveBatch: Component.t(t, outputs) => saveBatch;
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
    saveBatch: saveBatch(string, Js.Json.t),
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

  module NoResolvers = (Config: Config.T) => {
    type api = Config.api;
    type role = Config.role;

    let make: resolversMaker(api, role) =
      (
        ~name as _: string,
        ~api as _: api,
        ~apiRole as _: role,
        ~dataSourceName as _,
        ~indexes as _: list(View.index),
        ~sortField as _,
        ~resolveIdConfigs as _: list(View.resolveIdConfig),
        ~resolveIdsConfigs as _: list(View.resolveIdsConfig),
        ~opts as _,
      ) => {
        {resources: [||], resourcesMaker: _ => [||]};
      };
  };
};

module Make =
       (
         Config: Config.T,
         Spec: AggregateSpec,
         ViewSpec: ViewSpec,
         Storage:
           Adapter.Storage with
             type api = Config.api and type role = Config.role,
         Resolvers:
           Adapter.Resolvers with
             type api = Config.api and type role = Config.role,
       )
       : (T with module Spec = Spec and module ViewSpec := ViewSpec) => {
  module Spec = Spec;

  type api = Config.api;
  type role = Config.role;

  type t;

  type nonrec load = load(Spec.Id.t, ViewSpec.state);
  type nonrec save = save(Spec.Id.t, ViewSpec.state);
  type nonrec saveBatch = saveBatch(Spec.Id.t, ViewSpec.state);
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
  external setSaveBatch: (Component.t(t, outputs), saveBatch) => unit =
    "saveBatch";
  [@bs.set]
  external setCount: (Component.t(t, outputs), count) => unit = "count";
  [@bs.set]
  external setDelete: (Component.t(t, outputs), delete) => unit = "delete";

  [@bs.get] external load: Component.t(t, outputs) => load = "load";
  [@bs.get] external save: Component.t(t, outputs) => save = "save";
  [@bs.get]
  external saveBatch: Component.t(t, outputs) => saveBatch = "saveBatch";
  [@bs.get] external count: Component.t(t, outputs) => count = "count";
  [@bs.get] external delete: Component.t(t, outputs) => delete = "delete";

  let decode = (id, item) =>
    switch (ViewSpec.state_decode(item)) {
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
    (. id, state, saveMode, ttl) => {
      switch (state->ViewSpec.state_encode->Js.Json.decodeObject) {
      | Some(dict) =>
        dict->Js.Dict.set("id", Spec.Id.t_encode(id));
        let json = Js.Json.object_(dict);
        storage.Adapter.save(. id->Spec.Id.toString, json, saveMode, ttl);
      | None =>
        Js.log("QueryDB.save: Error: Couldn't decodeObject");
        Belt.Result.Error(
          NotSavedToStorage("Couldn't decodeObject"->Obj.magic),
        )
        ->Js.Promise.resolve;
      };
    };

  let saveBatchFn = storage =>
    (. items) => {
      let batch =
        items->Belt.Array.keepMap(((id, state, ttl)) =>
          switch (state->ViewSpec.state_encode->Js.Json.decodeObject) {
          | Some(dict) =>
            dict->Js.Dict.set("id", Spec.Id.t_encode(id));
            let json = Js.Json.object_(dict);
            Some((id->Spec.Id.toString, json, ttl));
          | None =>
            Js.log("QueryDB.save: Error: Couldn't decodeObject");
            None;
          }
        );
      storage.Adapter.saveBatch(. batch);
    };

  let countFn = storage =>
    (. id, fieldName, inc) => {
      storage.Adapter.count(. id->Spec.Id.toString, fieldName, inc);
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
      ViewSpec.sortConfig->Belt.Option.map(config => config.sortField);
    let storageName = name->ComponentType.name(componentType);
    let storage =
      Storage.make(
        ~name=storageName,
        ~indexes=ViewSpec.indexes,
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
    self->setSaveBatch(storage->saveBatchFn);
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
        ~indexes=ViewSpec.indexes,
        ~sortField,
        ~resolveIdConfigs=ViewSpec.resolveIdConfigs,
        ~resolveIdsConfigs=ViewSpec.resolveIdsConfigs,
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
        ~name=ViewSpec.name->Belt.Option.getWithDefault(Spec.name),
        ~construct=construct(~ttl),
        ~opts,
        ~api=Config.api,
        ~apiRole=Config.apiRole,
        ~resources,
      );
    };
};
