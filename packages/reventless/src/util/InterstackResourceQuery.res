type runtimeQueryExn = ResourceQuery.runtimeQueryExn

type deploytimeQueryExn = string => Pulumi.Output.t<ReventlessSpec.Adapter.resource>

let unwrapResource = ResourceQuery.unwrapResource
