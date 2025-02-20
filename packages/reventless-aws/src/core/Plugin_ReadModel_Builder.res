module MappingsType = Reventless.Projection.Mappings.Make(Reventless.PluginReadModelSpec)

module Mappings = {
  module type Mapping = MappingsType.Mapping

  let mappings: array<module(Mapping)> = [module(Reventless.PluginProjection.PluginMapping)]
}

module Make = (Config: Config.T) => ReadModel_Builder.Make(
  Config,
  Reventless.PluginReadModelSpec,
  Mappings,
)
