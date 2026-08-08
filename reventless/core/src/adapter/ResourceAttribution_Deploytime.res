/***
Carrying `ResourceAttribution` across a `Pulumi.Output` boundary.

Separate from `ResourceAttribution` itself on purpose: that module is read by
code that ends up in a Lambda bundle, and importing the deploy-time engine there
is a cold-start failure. Everything Pulumi-shaped lives here, where only
deploy-time builders reach it — the same reason `AdapterDeploytime` sits apart
from `Adapter`.

Both helpers wrap `apply` / `flatMap` rather than the callback alone. Wrapping
the callback would read more neatly, but it severs the type flow from the Output
to the callback's parameters, and inference then fails on records the Output was
the only thing constraining.
*/

/** `Pulumi.Output.apply` for a callback that CREATES RESOURCES.

    An apply callback runs after the enclosing builder's construct has returned,
    so the ambient attribution context — published for the duration of that
    construct and unpublished at the end of it — is already empty by then, and
    anything the callback provisions is attributed to nobody. That is not a gap
    but a wrong answer: an empty plugin means platform-scope substrate.

    This captures the context where the apply is *registered*, which is
    synchronous inside construct, and reinstates it around the callback. Reach
    for it wherever an apply body reaches a resource; plain `Pulumi.Output.apply`
    stays right for a callback that only shapes data. */
let applyAttributed = (output, callback) => {
  let captured = ResourceAttribution.current.contents
  output->Pulumi.Output.apply(resolved =>
    captured->ResourceAttribution.within(() => callback(resolved))
  )
}

/** `Pulumi.Output.flatMap` counterpart, for the same reason — a builder that
    resolves one resource's outputs in order to build the next one defers just as
    far. */
let flatMapAttributed = (output, callback) => {
  let captured = ResourceAttribution.current.contents
  output->Pulumi.Output.flatMap(resolved =>
    captured->ResourceAttribution.within(() => callback(resolved))
  )
}
