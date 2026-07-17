module Namespace = {
  type namespace
  @module("uuid") @scope("v3")
  external dns: namespace = "DNS"
  @module("uuid") @scope("v3")
  external url: namespace = "URL"
  external custom: string => namespace = "%identity"
}

@module("uuid")
external v1: unit => string = "v1"

@module("uuid")
external v3: (~name: string, ~namespace: Namespace.namespace) => string = "v3"

@module("uuid")
external v4: unit => string = "v4"

@module("uuid")
external v5: (~name: string, ~namespace: Namespace.namespace) => string = "v5"
