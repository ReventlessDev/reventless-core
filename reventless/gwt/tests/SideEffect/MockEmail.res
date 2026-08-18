// Fixture: a mock email service that records every call into a ref. The
// SideEffect_GWT test reads the recorded calls back via `mock.snapshot()`
// and asserts against them.

@schema
type call = SendConfirmation({email: string, orderId: string})

let calls: ref<array<call>> = ref([])

let reset = () => calls := []

let recordSend = (~email, ~orderId) =>
  calls := calls.contents->Array.concat([SendConfirmation({email, orderId})])

let mock: SideEffect_GWT.mock<call> = {
  snapshot: () => calls.contents,
  encode: c => c->Reventless.Util_Sury.toJson(callSchema),
}
