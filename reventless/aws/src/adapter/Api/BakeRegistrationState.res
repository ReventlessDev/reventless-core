/** What the Plugin read model says about one plugin the bake is waiting on.

    Distinct outcomes rather than a boolean because a bake that reported only
    "pending" left every one of these to be told apart by reading the read model
    out of band, with credentials the deploy pipeline does not surface.

    The bake function answers with the case's name; the deploy script reads it back. */
type t =
  /** Key agrees, row written by this deploy: the chain ran, and this is the evidence. */
  | Registered
  /** Key agrees, nothing re-registered — a correct pass that proves nothing. */
  | Unchanged
  /** Key agrees, and no deploy instant to tell the two above apart. */
  | Matched
  /** No Connected row carries a structure. The scan filters on Connected, so a
      version that dropped out mid-deploy leaves nothing to converge against. */
  | Missing
  /** Row holds another key and predates this deploy — the case retrying is for. */
  | Behind
  /** Row written by this deploy and still holding another key. Retrying cannot fix it. */
  | Diverged

let all = [Registered, Unchanged, Matched, Missing, Behind, Diverged]

let name = (state: t): string => (state :> string)

/** The state a word names; `None` for a word that names none. */
let ofName = (word: string): option<t> => all->Array.find(state => name(state) == word)
