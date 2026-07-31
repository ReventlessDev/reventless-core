// What remains of the generator's own Node bindings after they moved to
// `@reventlessdev/rescript-node`: one helper, which is not a binding.
//
// The generator walks directories that may legitimately not exist — an
// `Extension/` folder is optional, and so is every other component folder — and
// it treats "absent" and "empty" the same way. `readdirSync` throws on absent,
// so every walk would otherwise carry its own try/catch. This does not belong in
// the bindings package: a binding that swallows an error is a policy, and the
// policy is the generator's.

let readDir = (dir: string): array<NodeFs.dirent> =>
  try NodeFs.readdirSync(dir, {withFileTypes: true}) catch {
  | _ => []
  }
