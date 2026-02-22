---
sidebar_position: 3
---

# Extension Point Protocol Versioning

When two plugins communicate through an extension point, Plugin B (the extension) sends
`command` messages to Plugin A's extension point, and Plugin A sends `event` messages back.
These messages are encoded using `@schema`-generated JSON codecs.

If Plugin A and Plugin B are deployed with different versions of the extension point's
message types, codec mismatches can cause messages to fail silently. The
`reventless-interop` package provides **protocol version declarations** to catch these
mismatches at connection time, before any messages are exchanged.

---

## How It Works

### 1. The host declares its schema versions

Plugin A (the host) stores the current SemVer of each built-in extension point's
`command` and `event` schemas in `ReventlessInterop.CompatMatrix`:

```rescript
// reventless-interop/src/protocol/CompatMatrix.res
let corePlugin: ExtensionPointProtocol.schemaVersions = {
  commandVersion: "1.0.0",
  eventVersion: "1.0.0",
}
```

For custom extension points, Plugin A declares its own `schemaVersions` value
co-located with the extension point's `Spec` module (see [Custom Extension Points](#custom-extension-points) below).

### 2. The extension declares the versions it was compiled with

Plugin B declares which schema versions it was compiled against inside its
`pluginDefinition.extensionProtocols` array, which is sent in the `ConnectPlugin` command:

```rescript
let pluginDef: ReventlessSpec.Plugin.pluginDefinition = {
  id: "my-plugin",
  name: "My Plugin",
  version: "2.0.0",
  extensionPoints: [],
  extensions: [{ name: "my-ext", extensionPointName: "Core.Plugin" }],
  eventCollector: "",
  extensionProtocols: [
    {
      extensionPointName: "Core.Plugin",
      commandVersion: "1.0.0",  // SemVer compiled into this plugin
      eventVersion: "1.0.0",
    },
  ],
}
```

### 3. The ConnectPlugin handler validates compatibility

Plugin A's `ConnectPlugin` handler calls `Compat.validateProtocol` for each declared
protocol. On a mismatch it emits an `IncompatiblePlugin` event so operators have
visibility, but the connection still proceeds:

```rescript
let protocolErrors =
  pluginDefinition.extensionProtocols
  ->Array.flatMap(proto =>
    ReventlessInterop.Compat.validateProtocol(
      ~host=ReventlessInterop.CompatMatrix.corePlugin,
      ~extensionPointName=proto.extensionPointName,
      ~commandVersion=proto.commandVersion,
      ~eventVersion=proto.eventVersion,
    )
  )
```

---

## Compatibility Rule

```
host.MAJOR == extension.MAJOR
AND host.MINOR >= extension.MINOR
AND (if MINOR equal) host.PATCH >= extension.PATCH
```

In plain terms: an extension compiled against an _older_ MINOR or PATCH version of the
same MAJOR is always compatible (the host is a superset). An extension compiled against
a _newer_ MINOR or PATCH may use message variants the host cannot decode, so it is
flagged as incompatible. A MAJOR mismatch is always incompatible.

---

## SemVer Policy for Message Schemas

Because runtime codecs must handle unknown data gracefully, the version policy for
`@schema` message types differs from library API SemVer:

| Change | Version bump | Runtime behaviour |
|--------|-------------|------------------|
| Add a new variant to `command`/`event` | MINOR | Old decoders skip unknown variants |
| Add an optional field to a variant payload | MINOR | Old decoders ignore extra fields |
| Remove a variant or field | MAJOR | Old publishers send undecodable messages |
| Rename a variant | MAJOR | Equivalent to remove + add |
| Add a required field to an existing variant | MAJOR | Old publishers omit the field |

:::tip Required catch-all pattern
`@schema`-generated decoders for `command`/`event`/`directive` types must use a
catch-all branch for unknown variants (returning a `Result.Error` or skipping) rather
than throwing. This prevents a single new variant from crashing a deployed Lambda that
has not yet been redeployed.
:::

---

## Built-in Extension Points

### Core.Plugin

The single built-in extension point. All plugins that participate in the Reventless
lifecycle (connect, heartbeat, disconnect) connect through `Core.Plugin`.

| Schema | Current version |
|--------|----------------|
| `command` | `1.0.0` |
| `event` | `1.0.0` |

Command variants: `Heartbeat`, `ConnectPlugin`, `DisconnectPlugin`, `ForwardCommand`

Event variants: `UnknownPluginDetected`, `IncompatiblePlugin`, `PluginConnected`,
`PluginReconnected`, `PluginDisconnected`, `PluginDeactivated`, `PluginActivated`

---

## Custom Extension Points

Application plugins that define their own extension points should declare schema
versions co-located with the extension point's `Spec` module. There is no central
registry — each plugin validates incoming connections using its own declared versions.

### Declaring versions

```rescript
// MyExtensionPoint.res  (in your plugin package)
let name = "MyPlugin.MyExtensionPoint"

module Spec: ReventlessSpec.ExtensionPointMapping.Spec = {
  @schema type command  = | DoThing(string) | DoOtherThing
  @schema type event    = | ThingDone(string)
  @schema type directive = | NoOp
}

// Bump according to the version policy above whenever command or event changes.
let schemaVersions: ReventlessInterop.ExtensionPointProtocol.schemaVersions = {
  commandVersion: "1.0.0",
  eventVersion: "1.0.0",
}
```

This satisfies the `ExtensionPointProtocol.Versioned` module type, which you can use
to enforce the pattern at compile time if desired:

```rescript
module MyExtensionPoint: ReventlessInterop.ExtensionPointProtocol.Versioned = {
  let name = "MyPlugin.MyExtensionPoint"
  let schemaVersions = { commandVersion: "1.0.0", eventVersion: "1.0.0" }
}
```

### Validating incoming connections

In your `ConnectPlugin` handler, validate the connecting plugin's declared versions
against yours:

```rescript
let protocolErrors =
  pluginDefinition.extensionProtocols
  ->Array.filter(p => p.extensionPointName == MyExtensionPoint.name)
  ->Array.flatMap(proto =>
    ReventlessInterop.Compat.validateProtocol(
      ~host=MyExtensionPoint.schemaVersions,
      ~extensionPointName=proto.extensionPointName,
      ~commandVersion=proto.commandVersion,
      ~eventVersion=proto.eventVersion,
    )
  )
```

`validateProtocol` returns an `array<Compat.protocolError>`. An empty array means the
versions are compatible.

### Connecting to a custom extension point (from Plugin B)

Plugin B declares its compiled-against versions in `extensionProtocols`:

```rescript
extensionProtocols: [
  {
    extensionPointName: "MyPlugin.MyExtensionPoint",
    commandVersion: "1.0.0",
    eventVersion: "1.0.0",
  },
],
```

### Bumping the version after a schema change

1. Change the `command` or `event` type in your `Spec` module.
2. Bump `schemaVersions.commandVersion` or `schemaVersions.eventVersion`
   following the policy table above.
3. Redeploy Plugin A (the host). Plugin B will be flagged incompatible on its
   next `ConnectPlugin` until it is also redeployed with updated version declarations.
