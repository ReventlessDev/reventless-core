# Plan (Backlog): Switching a plugin's slices to the stream builder deletes the shared projection ESM

**Status:** Backlog (not started) — defect, cause not yet understood

**Found while:** implementing
[change-descriptors-for-non-read-model-tables.md](../done/change-descriptors-for-non-read-model-tables.md).
Unrelated to that plan's seam; recorded separately so the investigation is not
buried in a completed plan.

---

## Symptom

Switching a plugin's `StateViewSlice` declarations to the stream builder
(`StateViewSliceStream`) produced a deploy preview that **deletes the shared
projection Lambda's EventSourceMapping** (event log → `AllStateViewSlices`) and
its role policy, recreating neither — while the runtime side still registered
every slice through `StateViewSliceRuntime_Builder_Single`.

## What it is not

- **Not a table-replacement problem.** The tables updated in place, streams were
  enabled, zero replace markers — stored data was never at risk.
- **Not an inherent consequence of a plugin being all-stream.** An all-stream
  plugin has a healthy event-log → projection mapping deployed today.

## Why it matters

Applying the preview would leave every affected table with a new stream and
nothing writing to it — a read model frozen at its current contents, which is
worse than not switching at all.

## Interim guidance

Treat a wholesale switch of a plugin's slices to the stream builder as **unsafe**
until the cause is understood. The preview's delete list is the check that
catches it: if it names the projection Lambda's EventSourceMapping or its role
policy, do not apply.

## Investigation starting points

- `StateViewSlice_Builder_Stream` vs the non-stream builder — which one owns the
  event-log → `AllStateViewSlices` EventSourceMapping, and whether an all-stream
  plugin stops constructing it while `StateViewSliceRuntime_Builder_Single` still
  registers the slices that need it.
- Whether the ESM's ownership is conditional on at least one non-stream slice
  existing in the plugin, and what the deployed-and-healthy all-stream plugin does
  differently.

## Verification when fixed

- A plugin switched wholesale from `StateViewSlice` to `StateViewSliceStream`
  previews with no deletion of the projection Lambda's EventSourceMapping or role
  policy.
- After applying, projections still advance from the event log for every slice
  the runtime registers.
