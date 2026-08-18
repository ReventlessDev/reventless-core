// Recording mock for `EmailService` (Option C of the `sideeffect-gwt` plan).
// `install()` swaps `EmailService.current` to a backend that records every
// call into a ref. `SideEffect_GWT` reads the recorded calls back via `mock`
// and renders assertions against them.
//
// Production code never sees this file — it lives under `tests/` and only
// loads when the test runner imports it.

@schema
type call = SendOrderConfirmation({email: string, orderId: string})

let calls: ref<array<call>> = ref([])

let reset = () => calls := []

let recordingBackend: EmailService.backend = {
  sendOrderConfirmation: async (~email, ~orderId) => {
    calls := calls.contents->Array.concat([SendOrderConfirmation({email, orderId})])
  },
}

// Swap the live backend and clear any prior recordings. Call from `beforeEach`.
let install = () => {
  EmailService.current := recordingBackend
  reset()
}

let mock: ReventlessGwt.SideEffect_GWT.mock<call> = {
  snapshot: () => calls.contents,
  encode: c => c->Reventless.Util_Sury.toJson(callSchema),
}
