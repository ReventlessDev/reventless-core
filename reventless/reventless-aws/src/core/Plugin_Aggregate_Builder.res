include Aggregate_Builder_Single.Make(
  Reventless.PluginSpec,
  Reventless.PluginBehavior,
  Reventless.NoEventMappings.Make(Reventless.PluginSpec),
)
