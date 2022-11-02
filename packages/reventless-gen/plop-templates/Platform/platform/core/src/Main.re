module Core = ReventlessAws.Core.Make(Config);

let core =
  Core.make(
    ~version=Config.version,
    ~extensionPoints=[|(module PluginExtensionPoint)|],
    ~aggregates=[|(module PluginAggregate)|],
    ~readModels=[|(module PluginReadModel)|],
    ~scheduler=Config.scheduler,
  );

let apiUrl =
  Config.api
  ->Pulumi.Output.flatMap(api => api##uris)
  ->Pulumi.Output.apply(uris => uris##_GRAPHQL);
