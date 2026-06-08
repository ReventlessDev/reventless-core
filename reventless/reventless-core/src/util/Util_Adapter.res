open ReventlessInfra.Adapter

let log = Logger.fromEnv()

let filterSupportedResources: (
  array<resource>,
  array<string>,
) => Pulumi.Output.t<array<resource>> = (resources, supportedServices) =>
  resources
  ->Array.map(resource => resource.service)
  ->Pulumi.Output.all
  ->Pulumi.Output.apply(services =>
    resources
    ->Array.zip(services)
    ->Array.filter(((_resource, service)) =>
      supportedServices->Array.some(supportedService => service == supportedService)
    )
    ->Array.map(((resource, _)) => resource)
  )

let filterSupportedResolvedResources: (
  array<Adapter.resolvedResource>,
  array<string>,
) => array<Adapter.resolvedResource> = (resources, supportedServices) =>
  resources->Array.filter(resource =>
    supportedServices->Array.some(supportedService => resource.service == supportedService)
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
        ->Array.map(Adapter.resourceToResolvedOutput)
        ->Pulumi.Output.all
        ->Pulumi.Output.apply(resources => {
          let resourcesStr = resources->Adapter.resolvedToString
          log.error(~comp="Util_Adapter", ~data=JSON.Encode.string(resourcesStr), err)
        })
      JsError.throwWithMessage(err)
    | matching => matching->Array.getUnsafe(0)
    }
  )
  ->Adapter.outputToResource

let findResolvedResource = (resources, service) =>
  switch resources->filterSupportedResolvedResources([service]) {
  | [] =>
    let err = `Util.Adapter.findResolvedResource: Couldn't find service ${service} in resources: ${resources->Adapter.resolvedToString}`
    log.error(~comp="Util_Adapter", err)
    JsError.throwWithMessage(err)
  | matching => matching->Array.getUnsafe(0)
  }

let findResourceInOutput = (resourcesOutput, service) =>
  resourcesOutput->Pulumi.Output.apply(resources => resources->findResource(service))

let partitionSupportedResources = (allResources, supportedServices) => {
  let (names, resourceOutputs) =
    allResources
    ->Dict.toArray
    ->Array.map(((name, resources)) => (
      name,
      resources->filterSupportedResources(supportedServices),
    ))
    ->Array.unzip

  resourceOutputs // TODO: Avoid waiting for all resourceOutputs, call apply only on needed Outputs
  ->Pulumi.Output.all // Outputs are unwrapped within Pulumi.Output.all !
  ->Pulumi.Output.apply(resources => {
    let (supported, unsupported) =
      names
      ->Array.zip(resources)
      ->Array.partition(((_, resources)) => resources->Array.length > 0)
    (
      supported->Array.map(((name, resources)) => (
        name,
        resources->Array.map(AdapterDeploytime.unsafeUnwrapResource),
      )),
      unsupported->Array.map(((name, _)) => name),
    )
  })
}

type resolvedResources = array<(string, array<Adapter.resolvedResource>)>

let partitionResolvedResourcesByService: (
  resolvedResources,
  string,
) => (resolvedResources, resolvedResources) = (resources, supportedService) =>
  resources->Array.partition(((_, resources)) =>
    resources->Array.some(resource => resource.service == supportedService)
  )
