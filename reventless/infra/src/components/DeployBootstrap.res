/**
Deploy-time bootstrap seam: a named choke point through which a deploy program
runs cross-cutting activations at fixed phases, without hand-editing the
generated `Main.res`.

No-op by default. Zero registrations ⇒ `run` does nothing ⇒ existing generated
and hand-written deploy programs are byte-identical and preview with no resource
diff. An extension (a backend, an operational package) registers a contribution
via `register` — at module-load time as an import side effect, or explicitly —
and the generated program's `run(PreDeploy)` / `run(PostDeploy)` calls fire it in
registration order.

Same shape as `ReventlessCore.Monitoring.use`: a module-level registry consulted
by an emitted call, so deploy-time extension becomes *registration*, not *file
editing*. See `docs/plans/deploy-bootstrap-seam.md`.
*/

/**
Ordered phases at which bootstrap contributions run during a deploy program.
*/
type phase =
  | /** before `deployPlatform` / `deployPlugin` — seam registration and other
       ordering-sensitive activations that must precede the platform/plugin
       graph build */
  PreDeploy
  | /** after the platform/plugin graph is registered — exports, cross-stack
       output emission */
  PostDeploy

type contribution = unit => unit

let preContributions: ref<array<contribution>> = ref([])
let postContributions: ref<array<contribution>> = ref([])
let preRan = ref(false)
let postRan = ref(false)

let registryFor = phase =>
  switch phase {
  | PreDeploy => preContributions
  | PostDeploy => postContributions
  }

let ranFor = phase =>
  switch phase {
  | PreDeploy => preRan
  | PostDeploy => postRan
  }

/**
Register a contribution. Contributions run in registration order within a phase.
Safe to call at module-load time (as an import side effect) or explicitly.
Defaults to `PreDeploy`.
*/
let register = (~phase=PreDeploy, contribution: contribution) => {
  let registry = registryFor(phase)
  registry := registry.contents->Array.concat([contribution])
}

/**
Run all contributions registered for a phase, in registration order. Emitted by
generated deploy programs around the platform/plugin build. Idempotent per phase:
running an already-run phase is a no-op, and running a phase with no
registrations does nothing.
*/
let run = (phase: phase) => {
  let ran = ranFor(phase)
  if !ran.contents {
    ran := true
    registryFor(phase).contents->Array.forEach(contribution => contribution())
  }
}

/**
Reset all registries and run-flags. Test-support only — deploy programs never
call this. Lets a test exercise registration order, phase isolation, and
idempotency from a clean slate.
*/
let reset = () => {
  preContributions := []
  postContributions := []
  preRan := false
  postRan := false
}
