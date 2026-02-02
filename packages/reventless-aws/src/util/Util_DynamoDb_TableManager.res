let dependencies: ref<array<promise<Pulumi.Resource.t>>> = ref([])

type registerResource = Pulumi.Resource.t => unit

let getDependencies = () => {
  let currentLen = dependencies.contents->Array.length
  let (start, end) = switch currentLen / 4 {
  | 0 => (0, 0)
  | idx => ((idx - 1) * 4, idx * 4)
  }
  let deps =
    dependencies.contents
    ->Array.slice(~start, ~end)
    ->Promise.all
    ->Pulumi.Output.fromPromise

  let registerResource = ref(_ => ())
  let promise = Promise.make((resolve, _) => registerResource := resolve)

  dependencies := dependencies.contents->Array.concat([promise])

  (deps, registerResource.contents)
}
