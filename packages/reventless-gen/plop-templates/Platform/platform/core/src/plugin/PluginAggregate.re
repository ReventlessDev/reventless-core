include ReventlessAws.Aggregate.Make(
          Config,
          Reventless.PluginSpec,
          Reventless.PluginBehavior,
          (Reventless.NoEventMappings.Make(Reventless.PluginSpec)),
        );
