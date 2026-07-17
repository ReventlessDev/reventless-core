type interceptResult = Allow | Deny(string)

type queryInterceptor = (
  ~identity: Reventless.Identity.t,
  ~readModelName: string,
  ~args: JSON.t,
) => promise<interceptResult>

/** Module-level interceptor hook. None = passthrough (default). */
let queryInterceptorHook: ref<option<queryInterceptor>> = ref(None)

let registerQueryInterceptor = (interceptor: queryInterceptor) => {
  queryInterceptorHook.contents = Some(interceptor)
}

let clearQueryInterceptor = () => {
  queryInterceptorHook.contents = None
}
