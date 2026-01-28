module Make = (Config: Config.T) => Aggregate_Builder_Single.Make(
  Config,
  Reventless.PluginSpec,
  Reventless.PluginBehavior,
  Reventless.NoEventMappings.Make(Reventless.PluginSpec),
)
