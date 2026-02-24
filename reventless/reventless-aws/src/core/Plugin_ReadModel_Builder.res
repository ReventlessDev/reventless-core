module MappingsType = ReventlessSpec.Projection.Mappings.Make(Reventless.PluginReadModelSpec)

module Mappings = {
  module type Mapping = MappingsType.Mapping

  let mappings: array<module(Mapping)> = [module(Reventless.PluginProjection.PluginMapping)]
}

include ReadModel_Builder_Single.Make(
  Reventless.PluginReadModelSpec,
  Mappings,
)
