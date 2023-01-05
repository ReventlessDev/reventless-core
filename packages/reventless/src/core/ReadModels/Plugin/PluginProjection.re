module Target = PluginReadModelSpec;

module Util = {
  let extractExtensionPointNames =
    Belt.Array.map(_, (extensionPoint: PluginSpec.extensionPointDefinition) =>
      extensionPoint.name
    );
  let extractExtensionNames =
    Belt.Array.map(_, (extension: PluginSpec.extensionDefinition) =>
      extension.extensionPointName
    );
};

module PluginMapping = {
  module Source = PluginSpec;

  let map = (event, {ReventlessSpec.Message.id, meta: {time, user}}) =>
    switch (event) {
    | PluginSpec.UnknownPluginDetected => ReventlessSpec.Projection.Spec.Ignore
    | Connected({name, version, eventCollector, extensionPoints, extensions}) =>
      Set(
        id,
        {
          PluginReadModelSpec.name,
          version,
          eventCollector,
          extensionPoints,
          extensionPointNames:
            extensionPoints->Util.extractExtensionPointNames,
          extensionNames: extensions->Util.extractExtensionNames,
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

module type Mapping =
  ReventlessSpec.Projection.Mapping with module Target := Target;

let mappings: array(module Mapping) = [|(module PluginMapping)|];
