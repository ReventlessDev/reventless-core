open ReventlessSpec.Adapter;

let componentType = ComponentType.QueryDb;

type resolversResourcesMaker = Js.Dict.t(outputs) => array(resource)
and outputs = {
  .
  "resources": array(resource),
  "resolversMaker": resolversResourcesMaker,
};
type allOutputs = Js.Dict.t(outputs);

type t;
type component = Component.t(t, outputs);

module type AggregateSpec = {
  module Id: ReventlessSpec.Id.T;
  let name: string;
};

type saveMode =
  | Init
  | Overwrite
  | Any;

[@decco]
type storageError =
  | NotSavedToStorage(string)
  | NotLoadedFromStorage(string)
  | NotCountedOnStorage(string)
  | NotDeletedFromStorage(string)
  | BatchNotFullyWrittenToStorage(string)
  | StaleState
  | MissingSubIdConfig;

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
type deleteBatch('id) =
  (. array(('id, option((string, string))))) =>
  Js.Promise.t(Belt.Result.t(unit, storageError));

module type T = {
  module Spec: ReventlessSpec.ReadModelSpec.T;

  type nonrec load = load(Spec.Id.t, Spec.state);
  type nonrec save = save(Spec.Id.t, Spec.state);
  type nonrec saveBatch = saveBatch(Spec.Id.t, Spec.state);
  type nonrec count = count(Spec.Id.t);
  type nonrec delete = delete(Spec.Id.t);
  type nonrec deleteBatch = deleteBatch(Spec.Id.t);

  let make:
    (~ttl: int=?, ~opts: Pulumi.ComponentResource.Options.t=?, unit) =>
    component;

  let load: component => load;
  let save: component => save;
  let saveBatch: component => saveBatch;
  let count: component => count;
  let delete: component => delete;
  let deleteBatch: component => deleteBatch;

  let outputs: component => outputs;
};

module Adapter = {
  type storage = {
    resources: array(resource),
    dataSourceName: Pulumi.Output.t(string), // TODO create in API
    load: load(string, Js.Json.t),
    save: save(string, Js.Json.t),
    saveBatch: saveBatch(string, Js.Json.t),
    count: count(string),
    delete: delete(string),
    deleteBatch: deleteBatch(string),
  };
  type storageMaker('api, 'role) =
    (
      ~name: string,
      ~indexes: list(ReventlessSpec.ReadModelSpec.index),
      ~sortField: string=?,
      ~ttl: int=?,
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

  type queryEngineMaker = Js.Dict.t(outputs) => ReventlessSpec.QueryEngine.t;

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
      ~indexes: list(ReventlessSpec.ReadModelSpec.index),
      ~sortField: option(string),
      ~resolveIdConfigs: list(ReventlessSpec.ReadModelSpec.resolveIdConfig),
      ~resolveIdsConfigs: list(ReventlessSpec.ReadModelSpec.resolveIdsConfig),
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
        ~indexes as _: list(ReventlessSpec.ReadModelSpec.index),
        ~sortField as _,
        ~resolveIdConfigs as
          _: list(ReventlessSpec.ReadModelSpec.resolveIdConfig),
        ~resolveIdsConfigs as
          _: list(ReventlessSpec.ReadModelSpec.resolveIdsConfig),
        ~opts as _,
      ) => {
        {resources: [||], resourcesMaker: _ => [||]};
      };
  };
};

module Make =
       (
         Config: Config.T,
         Spec: ReventlessSpec.ReadModelSpec.T,
         Storage:
           Adapter.Storage with
             type api = Config.api and type role = Config.role,
         Resolvers:
           Adapter.Resolvers with
             type api = Config.api and type role = Config.role,
       )
       : (T with module Spec = Spec) => {
  module Spec = Spec;

  type api = Config.api;
  type role = Config.role;

  type nonrec load = load(Spec.Id.t, Spec.state);
  type nonrec save = save(Spec.Id.t, Spec.state);
  type nonrec saveBatch = saveBatch(Spec.Id.t, Spec.state);
  type nonrec count = count(Spec.Id.t);
  type nonrec delete = delete(Spec.Id.t);
  type nonrec deleteBatch = deleteBatch(Spec.Id.t);

  type constructed;
  type construct = (component, string, api, role) => constructed;

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
    component =
    "default";

  [@bs.obj]
  external makeOutputs:
    (~resources: array(resource), ~resolversMaker: resolversResourcesMaker) =>
    outputs =
    "";

  [@bs.send]
  external registerOutputs: (component, outputs) => constructed =
    "registerOutputs";
  [@bs.send] external setOutputs: (component, outputs) => unit = "setOutputs";
  let setOutputs = (self, outputs) => {
    self->setOutputs(outputs);
    self->registerOutputs(outputs);
  };

  [@bs.set] external setLoad: (component, load) => unit = "load";
  [@bs.set] external setSave: (component, save) => unit = "save";
  [@bs.set]
  external setSaveBatch: (component, saveBatch) => unit = "saveBatch";
  [@bs.set] external setCount: (component, count) => unit = "count";
  [@bs.set] external setDelete: (component, delete) => unit = "delete";

  [@bs.get] external load: component => load = "load";
  [@bs.get] external save: component => save = "save";
  [@bs.get] external saveBatch: component => saveBatch = "saveBatch";
  [@bs.get] external count: component => count = "count";
  [@bs.get] external delete: component => delete = "delete";
  [@bs.get] external deleteBatch: component => deleteBatch = "deleteBatch";

  let decode = (id, item) =>
    switch (Spec.state_decode(item)) {
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
      switch (state->Spec.state_encode->Js.Json.decodeObject) {
      | Some(dict) =>
        dict->Js.Dict.set("id", Spec.Id.t_encode(id));
        let json = Js.Json.object_(dict);
        storage.Adapter.save(. id->Spec.Id.toString, json, saveMode, ttl);
      | None =>
        Js.log2(
          "QueryDB.save: Error: Couldn't decodeObject:",
          state->Js.Json.stringifyAny,
        );
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
          switch (state->Spec.state_encode->Js.Json.decodeObject) {
          | Some(dict) =>
            dict->Js.Dict.set("id", Spec.Id.t_encode(id));
            let json = Js.Json.object_(dict);
            Some((id->Spec.Id.toString, json, ttl));
          | None =>
            Js.log2(
              "QueryDB.saveBatch: Error: Couldn't decodeObject:",
              state->Js.Json.stringifyAny,
            );
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
    (. id, subId) => {
      storage.Adapter.delete(. id->Spec.Id.toString, subId);
    };

  let outputs: component => outputs =
    component => Component.extractOutputs(component);

  let construct = (~ttl=?, self, name, api, apiRole) => {
    let opts =
      Pulumi.CustomResourceOptions.make(
        ~parent=self->Component.toPulumiResource,
        (),
      );

    let sortField =
      Spec.subIdConfig->Belt.Option.map(config => config.subIdField);
    let storageName = name->ComponentType.name(componentType);
    let storage =
      Storage.make(
        ~name=storageName,
        ~indexes=Spec.indexes,
        ~sortField?,
        ~ttl?,
        ~api,
        ~apiRole,
        ~opts,
      );

    self->setLoad(storage->loadFn);
    self->setSave(storage->saveFn);
    self->setSaveBatch(storage->saveBatchFn);
    self->setCount(storage->countFn);
    self->setDelete(storage->deleteFn);

    let resolvers =
      Resolvers.make(
        ~name,
        ~api,
        ~apiRole,
        ~dataSourceName=storage.dataSourceName,
        ~indexes=Spec.indexes,
        ~sortField,
        ~resolveIdConfigs=Spec.resolveIdConfigs,
        ~resolveIdsConfigs=Spec.resolveIdsConfigs,
        ~opts,
      );

    makeOutputs(
      ~resources=storage.resources->Belt.Array.concat(resolvers.resources),
      ~resolversMaker=resolvers.resourcesMaker,
    )
    |> self->setOutputs;
  };

  let make = (~ttl=?, ~opts=?, _) => {
    make(
      ~componentType=componentType->ComponentType.toString,
      ~name=Spec.name,
      ~construct=construct(~ttl?),
      ~opts,
      ~api=Config.api,
      ~apiRole=Config.apiRole,
    );
  };
};
