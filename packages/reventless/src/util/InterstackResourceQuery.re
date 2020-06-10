type runtimeQueryExn = ResourceQuery.runtimeQueryExn;
type deploytimeQueryExn = string => Pulumi.Output.t(Adapter.resource);

let unwrapResource = ResourceQuery.unwrapResource;
