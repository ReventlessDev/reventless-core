include ReventlessAws.Aggregate.Make(
          Config,
          Reventless.PluginSpec,
          Reventless.PluginBehaviour,
          (Reventless.NoEventMappings.Make(Reventless.PluginSpec)),
        );
