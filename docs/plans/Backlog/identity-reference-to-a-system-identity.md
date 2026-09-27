# Plan (Backlog): an identity declared on the system is not a dangling reference

**Status:** Backlog (not started)

`Plugin_Structure.identityReference` reports a field typed by an identity that no view in the
plugin is keyed by: "`siteId` is a SiteId, and no view in this plugin is keyed by it, so it
references nothing". It is reported at every platform start, as a warning.

That is correct when the identity was meant to be listed and is not. It is not a fault when the
identity is declared on purpose and has no view yet: a site that other parts name, but no screen
lists. Repeated as a warning at every start, it is noise that hides the warnings that matter.

**Change:** the same sentence, as information rather than a warning, when the identity is
declared in the plugin (its `…Id.res` exists) and no view is keyed by it. An identity used but
declared nowhere keeps the warning.

**Verify:** a plugin with a declared `SiteId`, a field typed by it and no Sites view starts
without a warning, and lists the reference as information.
