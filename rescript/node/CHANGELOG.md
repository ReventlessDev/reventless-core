# Change Log

All notable changes to this project will be documented in this file.
See [Conventional Commits](https://conventionalcommits.org) for commit guidelines.

# 2.0.0-alpha.0 (2026-07-31)

* feat(rescript)!: one Node bindings package, not two ([1258d8c](https://github.com/ReventlessDev/reventless-core/commit/1258d8c2b2ff2636b36a849fc5bdf9005c6fb0eb))

### BREAKING CHANGES

* `@reventlessdev/rescript-node-streams` and
`@reventlessdev/rescript-node-zlib` are replaced by
`@reventlessdev/rescript-node`. Module names are unchanged.



This package continues the version line of `@reventlessdev/rescript-node-streams` (1.1.0-alpha.13)
and `@reventlessdev/rescript-node-zlib` (1.1.0-alpha.14), which it replaces. Their changelogs up to
those versions are the history of the modules `NodeStreams` and `NodeZlib`; both module names are
unchanged, so the merge is a dependency swap for consumers.
