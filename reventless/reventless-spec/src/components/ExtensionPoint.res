/**
Module type for an extension point's identity and schema specification.

An extension point is a bidirectional protocol boundary: it exposes a
command topic for extensions to publish to, and an event topic that
extensions subscribe to. The `directive` type is used for internal
routing signals that are not exposed as public events.

Note: `module Id = Id.String` is fixed — extension points always use string IDs.
*/
module type Spec = {
  module Id = Id.String

  /** Logical extension point name (used as a topic name prefix). */
  let name: string

  /** Commands that extensions can send to this extension point. Must carry `@schema`. */
  @schema
  type command
  /** Events that this extension point emits to subscribed extensions. Must carry `@schema`. */
  @schema
  type event
  /** Internal routing directives (not exposed externally). Must carry `@schema`. */
  @schema
  type directive
}

