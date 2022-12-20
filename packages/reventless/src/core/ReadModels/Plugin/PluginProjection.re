open PluginSpec;
open PluginReadModelSpec;
open ReventlessSpec.ProjectionSpec;
open ReventlessSpec.Mapper;

let extractExtensionPointNames =
  Belt.Array.map(_, (extensionPoint: extensionPointDefinition) =>
    extensionPoint.name
  );
let extractExtensionNames =
  Belt.Array.map(_, (extension: extensionDefinition) =>
    extension.extensionPointName
  );

module Impl = {
  module Source = MakeGenericSourceFromEventSource(PluginSpec);
  module Target = MakeGenericTargetFromStateTarget(PluginReadModelSpec);

  let map = (event, {ReventlessSpec.Message.id, meta: {time, user}}) =>
    switch (event) {
    | UnknownPluginDetected => Ignore
    | Connected({name, version, eventCollector, extensionPoints, extensions}) =>
      Set(
        id,
        {
          name,
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

module Mapping =
  MapperNto1.Mapping(
    ReventlessSpec.ProjectionSpec,
    // PluginSpec,
    // PluginReadModelSpec,
    Impl,
  );

module Mapppings:
  ReventlessSpec.MapperNto1.Mappings with
    module Spec := ReventlessSpec.ProjectionSpec and
    module Target := Impl.Target = {
  module type Mapping =
    ReventlessSpec.MapperNto1.Mapping with
      module Spec := ReventlessSpec.ProjectionSpec and
      module Target := Impl.Target;

  let mappings: array(module Mapping) = [|(module Mapping)|];
};
