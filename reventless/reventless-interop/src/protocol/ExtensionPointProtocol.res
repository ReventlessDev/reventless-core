// Schema version declarations for an extension point's command and event message types.
// Each version follows SemVer (MAJOR.MINOR.PATCH).
//
// Compatibility rule (checked by Compat.validateProtocol):
//   host.MAJOR == extension.MAJOR
//   AND host.MINOR >= extension.MINOR
//   AND (if MINOR equal) host.PATCH >= extension.PATCH
//
// Version policy:
//   Add a variant or optional field to command/event  → MINOR bump
//   Remove / rename a variant or field                → MAJOR bump
//   Add a required field to an existing variant       → MAJOR bump
//
// Built-in extension point versions are declared in CompatMatrix.res.
// Custom extension points declare their own schemaVersions alongside their Spec module
// (see `module type Versioned` below and the architecture docs for the full pattern).
type schemaVersions = {
  commandVersion: string,
  eventVersion: string,
}

// Module type for custom extension points that carry protocol version declarations.
//
// Application developers who define their own extension points implement this pattern
// by pairing a `schemaVersions` value with the extension point name. This keeps
// the version co-located with the Spec module that owns the command/event types.
//
// Example (in your plugin package):
//
//   // MyExtensionPoint.res
//   let name = "MyPlugin.MyExtensionPoint"
//
//   module Spec: ReventlessSpec.ExtensionPointMapping.Spec = {
//     @schema type command = | DoThing(string) | DoOtherThing
//     @schema type event   = | ThingDone(string)
//     @schema type directive = | NoOp
//   }
//
//   // Declare the current schema versions. Bump according to the version policy above.
//   let schemaVersions: ReventlessInterop.ExtensionPointProtocol.schemaVersions = {
//     commandVersion: "1.0.0",
//     eventVersion: "1.0.0",
//   }
//
// In your ConnectPlugin handler, validate incoming extensions with:
//
//   ReventlessInterop.Compat.validateProtocol(
//     ~host=MyExtensionPoint.schemaVersions,
//     ~extensionPointName=proto.extensionPointName,
//     ~commandVersion=proto.commandVersion,
//     ~eventVersion=proto.eventVersion,
//   )
//
// See architecture/extension-point-protocol-versioning for a full walkthrough.
module type Versioned = {
  // Name of this extension point — must match the value returned by ExtensionPointSpec.name.
  let name: string
  // Protocol schema versions for this extension point's command and event types.
  let schemaVersions: schemaVersions
}
