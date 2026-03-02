/** The logical name of a plugin (serializable as JSON). */
@schema
type name = string

/** The semantic version string of a plugin release. */
@schema
type version = string

/**
Describes an extension point exported by a plugin.
Included in the plugin's `pluginDefinition` for use by the gateway / host.
*/
@schema
type extensionPointDefinition = {
  name: string,
  commandTopic: string,
  eventTopic: string,
}

/**
Describes an extension imported by a plugin (i.e. a connection to a host plugin's
extension point).
Included in the plugin's `pluginDefinition` for use by the host.
*/
@schema
type extensionDefinition = {
  name: string,
  extensionPointName: string,
}

/**
Protocol version declaration for a single extension point connection.

Carried in the `ConnectPlugin` handshake so the host can validate schema
compatibility before accepting the extension. Use `[]` when version
negotiation is not needed.
*/
// Protocol version declaration for a single extension point connection.
// Carried in the ConnectPlugin handshake so the host can validate compatibility.
@schema
type extensionProtocol = {
  extensionPointName: string,
  /** SemVer of the command schema the extension was compiled against. */
  commandVersion: string,
  /** SemVer of the event schema the extension was compiled against. */
  eventVersion: string,
}

/**
The self-description of a deployed plugin, persisted in the plugin's event store.

Used by the gateway to discover extension points, extensions, and protocol versions.
The `eventCollector` field is mutable so it can be set after the heartbeat lambda
registers its own ARN.
*/
@schema
type pluginDefinition = {
  id: string,
  name: name,
  version: version,
  extensionPoints: array<extensionPointDefinition>,
  extensions: array<extensionDefinition>,
  mutable eventCollector: string,
  // Protocol version declarations for each extension point this plugin connects to.
  // Use [] when the plugin does not need version negotiation.
  extensionProtocols: array<extensionProtocol>,
}

