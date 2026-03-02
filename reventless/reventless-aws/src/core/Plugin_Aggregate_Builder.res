include Aggregate_Builder_Single.Make(
  ReventlessCore.PluginSpec,
  ReventlessCore.PluginBehavior,
  ReventlessInfra.NoEventMappings.Make(ReventlessCore.PluginSpec),
)
