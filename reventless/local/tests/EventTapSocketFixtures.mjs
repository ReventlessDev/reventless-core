// Stand-in sockets for the tap's broadcast, which touches nothing on a socket but
// `write`. Here rather than in an `Obj.magic` inside the test, per the repo
// convention that untyped reflection lives in a companion `.mjs`.

/** Records every line written, so a test can assert what a reader received. */
export const recordingSocket = () => {
  const written = []
  return { socket: { write: line => written.push(line) }, written }
}

/** A reader whose peer is gone: `write` throws, the way it does on a closed pipe.
    Broadcast has to survive this without losing the other readers. */
export const throwingSocket = () => ({
  write: () => {
    throw new Error('EPIPE')
  },
})
