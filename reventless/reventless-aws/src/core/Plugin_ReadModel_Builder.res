module MappingsType = Reventless.Projection.Mappings.Make(ReventlessCore.PluginReadModelSpec)

module Mappings = {
  module type Mapping = MappingsType.Mapping

  let mappings: array<module(Mapping)> = [module(ReventlessCore.PluginProjection.PluginMapping)]
}

include ReadModel_Builder_Single.Make(
  ReventlessCore.PluginReadModelSpec,
  Mappings,
)
