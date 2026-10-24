/**
The codes the platform itself puts on a rejected command, as opposed to the
error names a spec declares.

A spec may not name an error like one of these: the PPX refuses it, so a
client reading only `errorCode` can still tell a platform code from the
model's. The PPX holds a copy of `platformErrorCodes` (it cannot read this
file); a spec test keeps the two equal.
*/
type platformErrorCode =
  /** The caller may not act: an `@authorize` rule or an ownership check refused. */
  | Forbidden
  /** Contention the retries could not absorb, or a handler that failed outright. */
  | Conflict
  /** The event log refused the append. */
  | AppendFailed
  /** The plugin is disconnected; retry later. */
  | PluginUnavailable
  /** An administrator deactivated the plugin. */
  | PluginInactive
  /** The plugin version was retired. */
  | PluginRetired
  /** An inbound translation's commands could not be published. */
  | PublishFailed
  /** An inbound translation refused its input. */
  | TranslationFailed
  /** A door open to callers who are not signed in has had more requests from
      this source than its limit allows in the current window; retry later. */
  | Throttled

let code = (c: platformErrorCode): string =>
  switch c {
  | Forbidden => "Forbidden"
  | Conflict => "Conflict"
  | AppendFailed => "AppendFailed"
  | PluginUnavailable => "PluginUnavailable"
  | PluginInactive => "PluginInactive"
  | PluginRetired => "PluginRetired"
  | PublishFailed => "PublishFailed"
  | TranslationFailed => "TranslationFailed"
  | Throttled => "Throttled"
  }

/** Every constructor, in declaration order. */
let all = [
  Forbidden,
  Conflict,
  AppendFailed,
  PluginUnavailable,
  PluginInactive,
  PluginRetired,
  PublishFailed,
  TranslationFailed,
  Throttled,
]

let platformErrorCodes = all->Array.map(code)

let isPlatformErrorCode = (name: string): bool => platformErrorCodes->Array.includes(name)
