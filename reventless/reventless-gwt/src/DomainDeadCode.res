// Domain-level dead-code analysis (Phase 5). Pure reflection over the loaded
// pluginStructures + cross-plugin edges (LocalHost.loadGraph): finds produced event
// types that no component consumes — the event-sourcing counterpart to reactive
// dead code, the domain layer the language LSP cannot see.
//
// An event is reachable when ANY of these hold:
//   1. Some component lists it in `consumedEventTypes` — the DCB-style link used by
//      state-view slices, automation slices, outbound translations, and aggregate /
//      state-change-slice consistency reads. Scanned across ALL plugins, so a
//      cross-plugin consumer clears it.
//   2. The producing write-side has a non-empty `linkedViews`. Classic aggregate →
//      read-model projections express the link on the PRODUCER side (the read model's
//      `consumedEventTypes` is empty; it projects the aggregate's whole stream). This
//      is event-opaque, so a write-side with at least one linked view is treated as
//      fully consumed — see the precision caveat below.
//   3. It appears in an edge's `viaEvents` (redundant with (1), kept so the
//      "reachability over the graph" input is explicit).
// A produced event matched by none of these is reported as an orphan, anchored on
// the producing write-side declaration.
//
// Precision caveat: because classic read models carry no per-event consumption, rule
// (2) is conservative — a write-side with a linked view is never flagged, even if a
// specific event it produces is projected by nothing. This avoids false positives at
// the cost of missing per-event orphans inside an otherwise-projected aggregate. DCB
// consumers (rule 1) keep full per-event precision.
//
// Scope (v1): orphan produced events only. "Extension points with zero extensions"
// and "read models nothing resolves against" need data `pluginStructure` does not
// carry (the EP declaration list / the id-resolver table) — deferred.

type finding = {
  kind: string, // "OrphanEvent"
  pluginName: string, // plugin owning the producer
  componentName: string, // the producing aggregate / state-change slice
  detail: string, // the orphaned event type
}

let analyze = (
  ~structures: array<(string, Reventless.Plugin.pluginStructure)>,
  ~edges: array<Reventless.Plugin.graphEdge>,
): array<finding> => {
  // Every event type consumed anywhere becomes a key in `consumed`.
  let consumed = Dict.make()
  let mark = (evt: string) => consumed->Dict.set(evt, true)
  structures->Array.forEach(((_, s)) => {
    s.readModels->Array.forEach((q: Reventless.Plugin.queryableDef) =>
      q.consumedEventTypes->Array.forEach(mark)
    )
    s.stateViewSlices->Array.forEach((q: Reventless.Plugin.queryableDef) =>
      q.consumedEventTypes->Array.forEach(mark)
    )
    s.aggregates->Array.forEach((w: Reventless.Plugin.writableDef) =>
      w.consumedEventTypes->Array.forEach(mark)
    )
    s.stateChangeSlices->Array.forEach((w: Reventless.Plugin.writableDef) =>
      w.consumedEventTypes->Array.forEach(mark)
    )
    s.automationSlices->Array.forEach((a: Reventless.Plugin.automationSliceDef) =>
      a.consumedEventTypes->Array.forEach(mark)
    )
    s.outboundTranslationSlices->Array.forEach((o: Reventless.Plugin.outboundTranslationSliceDef) =>
      o.consumedEventTypes->Array.forEach(mark)
    )
    s.extensions->Array.forEach((e: Reventless.Plugin.extensionDef) =>
      e.eventTypes->Array.forEach(mark)
    )
  })
  edges->Array.forEach((e: Reventless.Plugin.graphEdge) => e.viaEvents->Array.forEach(mark))

  // Produced events with no consumer, reported per producing write-side. A write-side
  // with a linked view is treated as fully consumed (rule 2 above).
  let findings = []
  let scanProducers = (pluginName, writables: array<Reventless.Plugin.writableDef>) =>
    writables->Array.forEach(w =>
      if w.linkedViews->Array.length > 0 {
        ()
      } else {
        w.producedEventTypes->Array.forEach(evt =>
          switch consumed->Dict.get(evt) {
          | Some(_) => ()
          | None =>
            findings->Array.push({
              kind: "OrphanEvent",
              pluginName,
              componentName: w.name,
              detail: evt,
            })
          }
        )
      }
    )
  structures->Array.forEach(((pluginName, s)) => {
    scanProducers(pluginName, s.aggregates)
    scanProducers(pluginName, s.stateChangeSlices)
  })
  findings
}
