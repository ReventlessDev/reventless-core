include Aggregate_Builder_Single.Make(
  ReventlessCore.PluginSpec,
  ReventlessCore.PluginBehavior,
  Reventless.NoEventMappings.Make(ReventlessCore.PluginSpec),
)
