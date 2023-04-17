@decco
type name = string
@decco
type version = string

@decco
type extensionPointDefinition = {
  name: string,
  commandTopic: string,
  eventTopic: string,
}

@decco
type extensionDefinition = {
  name: string,
  extensionPointName: string,
}

@decco
type pluginDefinition = {
  id: string,
  name: name,
  version: version,
  extensionPoints: array<extensionPointDefinition>,
  extensions: array<extensionDefinition>,
  eventCollector: string,
}
