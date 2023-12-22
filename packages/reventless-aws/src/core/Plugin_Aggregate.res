module Make = (Config: Config.T) => Aggregate.Make(
  Config,
  Reventless.PluginSpec,
  Reventless.PluginBehaviour,
  Reventless.NoEventMappings.Make(Reventless.PluginSpec),
)
