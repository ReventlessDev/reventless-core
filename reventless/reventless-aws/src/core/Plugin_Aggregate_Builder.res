include Aggregate_Builder_Single.Make(
  Reventless.PluginSpec,
  Reventless.PluginBehavior,
  ReventlessSpec.NoEventMappings.Make(Reventless.PluginSpec),
)
