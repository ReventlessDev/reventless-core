// Maps each `Outcome.mismatch` variant to a fix-locus hint.
//
// Single source of truth for the `(kind, locus, branch, message)` mapping
// referenced by the human formatter, the JSON envelope, and the AI loop.
// See `docs/analysis/given-when-then-specifications.md` §3.2 (locus table)
// and §3.3 (JSON `hint` field).
//
// `locus` is a dotted pointer like "CategoryBehavior.decide" filled in by
// the DSL at `then*` call time when the slice module name is in scope. If the
// DSL can't provide it (e.g. Projection has no single "locus" function name
// the user controls), `locus` falls back to a generic pointer.

type t = {
  locus: string,
  branch: option<string>,
  message: string,
}

// Generic fallback mapping, parameterised by the slice module name when the
// caller can supply one. Branch specificity lives in the DSLs (they can pass
// a richer hint through `withLocus` below).
let forMismatch = (~slice="<slice>", m: Outcome.mismatch): t =>
  switch m {
  | EventsMismatch(_) => {
      locus: `${slice}.decide`,
      branch: None,
      message: "decide() returned different events than expected. Check the event payload and count.",
    }
  | ErrorMismatch({actual: None}) => {
      locus: `${slice}.decide`,
      branch: None,
      message: "decide() returned Ok([...]) but the test expected Error.",
    }
  | ErrorMismatch({actual: Some(_)}) => {
      locus: `${slice}.decide`,
      branch: None,
      message: "decide() returned a different Error variant than expected.",
    }
  | StateMismatch(_) => {
      locus: `${slice}.evolve`,
      branch: None,
      message: "evolve() produced a different state than expected. Check the fold and missing event branches.",
    }
  | NoEventExpected(_) => {
      locus: `${slice}.decide`,
      branch: None,
      message: "decide() emitted events but the test expected none — possible idempotency miss.",
    }
  | TodoMismatch(_) => {
      locus: `${slice}.collect / ${slice}.resolve`,
      branch: None,
      message: "The automation slice's TODO projection diverged from the expected set.",
    }
  | AppendConditionMismatch(_) => {
      locus: `${slice}.commandSchema`,
      branch: None,
      message: "DCB optimistic-concurrency condition drift — likely a missing `@s.matches(DcbTag.string)` annotation on a command field, or the expected condition documented in the test disagrees with what the runtime would build.",
    }
  | TranslateError(_) => {
      locus: `${slice}.translate`,
      branch: None,
      message: "The translation slice returned a different result than expected.",
    }
  | QueryRowsMismatch(_) => {
      locus: `${slice}.config`,
      branch: None,
      message: "The read-model query returned wrong rows — likely a missing index, sub-id, or resolver.",
    }
  | Throw({error}) => {
      locus: `${slice}`,
      branch: None,
      message: `The slice threw an exception: ${error}`,
    }
  }

// Convert to the JSON shape documented in §3.3.
let toJson = (h: t): JSON.t => {
  let obj = Dict.make()
  obj->Dict.set("locus", JSON.Encode.string(h.locus))
  obj->Dict.set(
    "branch",
    h.branch->Option.mapOr(JSON.Encode.null, JSON.Encode.string),
  )
  obj->Dict.set("message", JSON.Encode.string(h.message))
  JSON.Encode.object(obj)
}

let format = (h: t) =>
  switch h.branch {
  | None => `hint: ${h.message}\n      Look at ${h.locus}.`
  | Some(b) => `hint: ${h.message}\n      Look at ${h.locus}'s branch ${b}.`
  }
