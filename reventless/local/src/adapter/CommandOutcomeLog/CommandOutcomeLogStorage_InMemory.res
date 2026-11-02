// The command outcomes of an in-memory platform, oldest first, for as long as it runs.

type entry = CommandOutcomeLogEntry.t

let entries: array<entry> = []

let append = (e: entry) => entries->Array.push(e)

/** Up to `first` entries matching the filter, newest first, below the `before` sequence number. */
let read = (~filter: CommandOutcomeLogEntry.filter, ~before: option<int>, ~first: int): array<
  entry,
> => {
  let out = []
  let i = ref(entries->Array.length - 1)
  while i.contents >= 0 && out->Array.length < first {
    let e = entries->Array.getUnsafe(i.contents)
    if before->Option.mapOr(true, b => e.seq < b) && CommandOutcomeLogEntry.matches(filter, e) {
      out->Array.push(e)
    }
    i := i.contents - 1
  }
  out
}

/** Test seam. */
let clear = () => entries->Array.splice(~start=0, ~remove=entries->Array.length, ~insert=[])
