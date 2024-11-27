let dependencies: ref<array<Js.Promise.t<Pulumi.Resource.t>>> = ref([])

type registerResource = Pulumi.Resource.t => unit

let getDependencies = () => {
  let currentLen = dependencies.contents->Belt.Array.length
  let (offset, len) = switch currentLen / 4 {
  | 0 => (0, 0)
  | idx => ((idx - 1) * 4, 4)
  }
  let deps =
    dependencies.contents
    ->Belt.Array.slice(~offset, ~len)
    ->Js.Promise.all
    ->Pulumi.Output.fromPromise

  let registerResource = ref(_ => ())
  let promise = Js.Promise.make((~resolve, ~reject as _) => registerResource := resolve)

  dependencies := dependencies.contents->Belt.Array.concat([promise])

  (deps, registerResource.contents)
}
