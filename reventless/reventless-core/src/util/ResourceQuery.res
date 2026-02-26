open ReventlessSpec.Adapter

type runtimeQueryExn = string => resource

type deploytimeQueryExn = string => resource

let unwrapResource = (resource, resourceType, name) =>
  switch resource {
  | Some(resource) => resource
  | None =>
    JsError.throwWithMessage(
      `ResourceQuery: Couldn't find ${resourceType} for Service/Task ${name}.`,
    )
  }
