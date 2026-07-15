// Untyped reflection over an arbitrary thrown value — the shapes ReScript can't
// pattern-match. Kept whole in JS so the ReScript side (ExnMessage.res) is a
// clean typed binding with no `%raw` or `Obj.magic`.

// A human-readable message: a `throw null`, a bare thrown string, a JS `Error`
// (`.message`), or a ReScript exception's constructor payload (`RE_EXN_ID` +
// `_1`, e.g. `failwith("…")` raises `Failure`).
export function extractMessage(e) {
  if (e == null) return "unknown error";
  if (typeof e === "string") return e;
  if (typeof e.message === "string" && e.message.length) return e.message;
  if (typeof e.RE_EXN_ID === "string") {
    const id = e.RE_EXN_ID;
    const dot = id.lastIndexOf(".");
    const tag = dot >= 0 ? id.slice(dot + 1) : id;
    return typeof e._1 === "string" && e._1.length ? e._1 : tag;
  }
  return "unknown error";
}

// The `.stack` of a thrown JS `Error`, or "" for anything without one.
export function stackOf(e) {
  return (e && e.stack) || "";
}
