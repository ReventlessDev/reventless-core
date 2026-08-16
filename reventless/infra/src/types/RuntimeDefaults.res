/**
Platform-supplied per-kind runtime floor for pods that are sized straight from
core's resolved value (extension-point and task pods).

`RuntimeHints.resolveMemory`/`resolveTimeout` take a `~default` that is the
per-kind floor an override can only raise (`Math.Int.max`). For EP/task pods that
default is a *deployment* fact — how big a pod this platform wants — not a domain
fact, so the platform (not a core constant) supplies it. Each platform binds this
module at the seam where it applies the core `ExtensionPoint_Builder.Make` /
`Task_Builder.Make` functor; core feeds the two `let`s into `resolveMemory` /
`resolveTimeout` in place of the old hardcoded literals.

See docs/plans/done/runtime-hints-platform-supplied-defaults.md.
*/
module type T = {
  let memorySize: int // MiB floor for this pod kind on this platform
  let timeout: int // seconds
}
