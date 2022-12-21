open PluginSpec;
open ReventlessSpec.ProjectionSpec;

let extractExtensionPointNames =
  Belt.Array.map(_, (extensionPoint: extensionPointDefinition) =>
    extensionPoint.name
  );
let extractExtensionNames =
  Belt.Array.map(_, (extension: extensionDefinition) =>
    extension.extensionPointName
  );

module Target = PluginReadModelSpec;

module PluginMapping = {
  module Source = PluginSpec;

  let map = (event, {ReventlessSpec.Message.id, meta: {time, user}}) =>
    switch (event) {
    | UnknownPluginDetected => Ignore
    | Connected({name, version, eventCollector, extensionPoints, extensions}) =>
      Set(
        id,
        {
          PluginReadModelSpec.name,
          version,
          eventCollector,
          extensionPoints,
          extensionPointNames: extensionPoints->extractExtensionPointNames,
          extensionNames: extensions->extractExtensionNames,
          extensions,
          status: Connected,
          statusChange: {
            at: time,
            by: user,
          },
        },
      )
    | Reconnected(_) =>
      Update(
        id,
        state =>
          {
            ...state,
            status: Connected,
            statusChange: {
              at: time,
              by: user,
            },
          },
      )
    | Disconnected(_)
    | Activated(_) =>
      Update(
        id,
        state =>
          {
            ...state,
            status: Disconnected,
            statusChange: {
              at: time,
              by: user,
            },
          },
      )
    | Deactivated(_) =>
      Update(
        id,
        state =>
          {
            ...state,
            status: Inactive,
            statusChange: {
              at: time,
              by: user,
            },
          },
      )
    };
};

//module Mapping = ProjectionMapping.Make(Impl);

module type Mapping =
  Reventless.ProjectionMapping.ProjectionImpl with
    module Spec := ReventlessSpec.ProjectionSpec and
    type target := Target.state;

let mappings: array(module Mapping) = [|(module PluginMapping)|];
