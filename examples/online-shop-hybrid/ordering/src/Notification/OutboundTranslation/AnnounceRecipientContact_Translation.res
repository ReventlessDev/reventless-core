@@reventless.translation

// Keyed by recipient AND address: keying by recipient alone would make a later
// address change look like work already done, and the change is the whole point
// of consuming `EmailUpdated`. `~sourceId` is the aggregate id, which an
// aggregate's event payload does not repeat.
let collect = (event, ~sourceId) =>
  switch event {
  | Registered({email}) => [(`${sourceId}:${email}`, {recipientId: sourceId, email})]
  | EmailUpdated({email}) => [(`${sourceId}:${email}`, {recipientId: sourceId, email})]
  }

// No service to call, so nothing can go wrong and there is nothing to await. The
// item completes on this returning `Ok`, which is what makes the directory's own
// `AnnounceRecipient` free to be idempotent: a re-announced address publishes no
// event, and no row is left waiting for one.
let translate = async (_id, item: outboundItem, ~capabilities as _) =>
  Ok(Some((item.recipientId, AnnounceRecipient({recipientId: item.recipientId, email: item.email}))))

// Unreachable in practice — `translate` cannot fail — but a slice that stays
// silent has to say so on purpose. If a publish failure ever did exhaust the
// budget, the honest record is the sweep's Abandoned row: inventing a
// notification fact here would claim the directory knows an address it does not.
let onExhausted = (_id, _item, ~lastError as _) => None
