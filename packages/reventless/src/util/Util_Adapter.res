open ReventlessSpec.Adapter

let filterSupportedResources: (
  array<resource>,
  array<string>,
) => Pulumi.Output.t<array<resource>> = (resources, supportedServices) =>
  resources
  ->Array.map(resource => resource.service)
  ->Pulumi.Output.all
  ->Pulumi.Output.apply(services =>
    resources
    ->Belt.Array.zip(services)
    ->Array.filter(((_resource, service)) =>
      supportedServices->Belt.Array.some(supportedService => service == supportedService)
    )
    ->Array.map(((resource, _)) => resource)
  )

let filterSupportedUnwrappedResources: (
  array<Adapter.unwrappedResource>,
  array<string>,
) => array<Adapter.unwrappedResource> = (resources, supportedServices) =>
  resources->Array.filter(resource =>
    supportedServices->Belt.Array.some(supportedService => resource.service == supportedService)
  )

let findResource = (resources, service) =>
  resources
  ->filterSupportedResources([service])
  ->Pulumi.Output.apply(resources =>
    switch resources {
    | [] =>
      let err = `Util.Adapter.findResource: Couldn't find service ${service} in resources`
      let _ =
        resources
        ->Array.map(Adapter.resourceToUnwrappedOutput)
        ->Pulumi.Output.all
        ->Pulumi.Output.apply(resources => {
          let resourcesStr = resources->Adapter.unwrappedToString
          Js.log2(err, resourcesStr)
        })
      Js.Exn.raiseError(err)
    | matching => matching->Array.getUnsafe(0)
    }
  )
  ->Adapter.outputToResource

let findUnwrappedResource = (resources, service) =>
  switch resources->filterSupportedUnwrappedResources([service]) {
  | [] =>
    let err = `Util.Adapter.findUnwrappedResource: Couldn't find service ${service} in resources: ${resources->Adapter.unwrappedToString}`
    Js.log(err)
    Js.Exn.raiseError(err)
  | matching => matching->Array.getUnsafe(0)
  }

let findResourceInOutput = (resourcesOutput, service) =>
  resourcesOutput->Pulumi.Output.apply(resources => resources->findResource(service))

let partitionSupportedResources = (allResources, supportedServices) => {
  let (names, resourceOutputs) =
    allResources
    ->Js.Dict.entries
    ->Array.map(((name, resources)) => (
      name,
      resources->filterSupportedResources(supportedServices),
    ))
    ->Belt.Array.unzip

  resourceOutputs // TODO: Avoid waiting for all resourceOutputs, call apply only on needed Outputs
  ->Pulumi.Output.all // Outputs are unwrapped within Pulumi.Output.all !
  ->Pulumi.Output.apply(resources => {
    let (supported, unsupported) =
      names
      ->Belt.Array.zip(resources)
      ->Belt.Array.partition(((_, resources)) => resources->Array.length > 0)
    (
      supported->Array.map(((name, resources)) => (
        name,
        resources->Array.map(AdapterDeploytime.unsafeUnwrapResource),
      )),
      unsupported->Array.map(((name, _)) => name),
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
