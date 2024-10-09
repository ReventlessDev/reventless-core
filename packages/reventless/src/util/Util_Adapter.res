open ReventlessSpec.Adapter

let filterSupportedResources: (
  array<resource>,
  array<string>,
) => Pulumi.Output.t<array<resource>> = (resources, supportedServices) =>
  resources
  ->Belt.Array.map(resource => resource.service)
  ->Pulumi.Output.all
  ->Pulumi.Output.apply(services =>
    resources
    ->Belt.Array.zip(services)
    ->Belt.Array.keep(((_resource, service)) =>
      supportedServices->Belt.Array.some(supportedService => service == supportedService)
    )
    ->Belt.Array.map(((resource, _)) => resource)
  )

let filterSupportedUnwrappedResources: (
  array<Adapter.unwrappedResource>,
  array<string>,
) => array<Adapter.unwrappedResource> = (resources, supportedServices) =>
  resources->Belt.Array.keep(resource =>
    supportedServices->Belt.Array.some(supportedService => resource.service == supportedService)
  )

let findResource = (resources, service) =>
  resources
  ->filterSupportedResources([service])
  ->Pulumi.Output.apply(resources =>
    switch resources {
    | [] =>
      let err = `Util.Adapter.findResource: Couldn't find service ${service} in resources: ${resources
        ->Belt.Array.map(resource => resource->Js.Json.stringifyAny->Belt.Option.getExn)
        ->Js.Array2.joinWith(", ")}`
      Js.log(err)
      Js.Exn.raiseError(err)
    | matching => matching->Array.getUnsafe(0)
    }
  )

let findUnwrappedResource = (resources, service) =>
  switch resources->filterSupportedUnwrappedResources([service]) {
  | [] =>
    let err = `Util.Adapter.findUnwrappedResource: Couldn't find service ${service} in resources: ${resources
      ->Belt.Array.map(resource => resource->Js.Json.stringifyAny->Belt.Option.getExn)
      ->Js.Array2.joinWith(", ")}`
    Js.log(err)
    Js.Exn.raiseError(err)

  | resources => resources->Array.getUnsafe(0)
  }

let findResourceInOutput = (resourcesOutput, service) =>
  resourcesOutput->Pulumi.Output.flatMap(resources =>
    resources->filterSupportedResources([service])
  )

type component = {resources: array<ReventlessSpec.Adapter.resource>}

let partitionSupportedResources = (adapters, supportedServices) => {
  let (names, resourceOutputs) =
    adapters
    ->Js.Dict.entries
    ->Belt.Array.map(((name, adapter)) => (
      name,
      (adapter :> component).resources->filterSupportedResources(supportedServices),
    ))
    ->Belt.Array.unzip

  resourceOutputs // TODO: Avoid waiting for all resourceOutputs, call apply only on needed Outputs
  ->Pulumi.Output.all // Outputs are unwrapped within Pulumi.Output.all !
  ->Pulumi.Output.apply(resources => {
    let (supported, unsupported) =
      names
      ->Belt.Array.zip(resources)
      ->Belt.Array.partition(((_, resources)) => resources->Belt.Array.length > 0)
    (
      supported->Belt.Array.map(((name, resources)) => (
        name,
        resources->Belt.Array.map(AdapterDeploytime.unsafeUnwrapResource),
      )),
      unsupported->Belt.Array.map(((name, _)) => name),
    )
  })
}

type unwrappedResources = array<(string, array<Adapter.unwrappedResource>)>

let partitionUnwrappedResourcesByService: (
  unwrappedResources,
  string,
) => (unwrappedResources, unwrappedResources) = (resources, supportedService) =>
  resources->Belt.Array.partition(((_, resources)) =>
    resources->Belt.Array.some(resource => resource.service == supportedService)
  )
