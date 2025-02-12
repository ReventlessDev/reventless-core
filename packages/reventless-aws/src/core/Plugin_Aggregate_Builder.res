module Make = (Config: Config.T) => Aggregate_Builder.Make(
  Config,
  Reventless.PluginSpec,
  Reventless.PluginBehaviour,
  Reventless.NoEventMappings.Make(Reventless.PluginSpec),
)
