// A graphql-ws client for the subscription tests, here rather than in an
// `Obj.magic` inside the test, per the repo convention that untyped reflection
// lives in a companion `.mjs`.
import { createClient } from 'graphql-ws'
import WebSocket from 'ws'

/** Subscribes, collects values until `count` arrive (or an error or `timeoutMs`),
    calling `onStarted` once the server acknowledged the connection. Resolves
    `{ values, error }`; `error` is the first error message, if any. */
export const collect = (url, query, connectionParams, count, timeoutMs, onStarted) =>
  new Promise(resolve => {
    const values = []
    let settled = false
    const client = createClient({
      url,
      webSocketImpl: WebSocket,
      connectionParams,
      lazy: false,
      retryAttempts: 0,
      on: { connected: () => onStarted() },
    })
    const finish = error => {
      if (settled) return
      settled = true
      clearTimeout(timer)
      dispose()
      client.dispose()
      resolve({ values, error })
    }
    const timer = setTimeout(() => finish(undefined), timeoutMs)
    const dispose = client.subscribe(
      { query },
      {
        next: msg => {
          if (msg.errors && msg.errors.length > 0) return finish(String(msg.errors[0].message))
          values.push(Object.values(msg.data)[0])
          if (values.length >= count) finish(undefined)
        },
        error: err => {
          const m = Array.isArray(err) ? err[0]?.message : err?.message ?? err?.reason ?? String(err)
          finish(String(m))
        },
        complete: () => finish(undefined),
      },
    )
  })
