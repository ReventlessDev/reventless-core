# Change Log

All notable changes to this project will be documented in this file.
See [Conventional Commits](https://conventionalcommits.org) for commit guidelines.

# 2.0.0-alpha.5 (2026-08-13)

### Features

* **rescript:** bind import.meta so no module reaches for %raw ([c7bd00c](https://github.com/ReventlessDev/reventless-core/commit/c7bd00c0d49ca06cb26a0891a85921219eb87b12))


# 2.0.0-alpha.4 (2026-08-11)

**Note:** Version bump only for package @reventlessdev/rescript-node





# 2.0.0-alpha.3 (2026-08-09)

### Features

* **core,aws:** bundle a runtime extension's companion packages, guard imports at deploy ([e975175](https://github.com/ReventlessDev/reventless-core/commit/e9751758f51582a8e46db362219f725bb5f1bcde))


# 2.0.0-alpha.2 (2026-08-05)

### Features

* **local:** persist the object store beside the SQLite database ([f37e4a1](https://github.com/ReventlessDev/reventless-core/commit/f37e4a1ad3191a97f14f3db7e2ead0e2b27b46c2))


# 2.0.0-alpha.1 (2026-08-02)

### Features

* **rescript-node:** add NodeCrypto.sha256Hex convenience ([047d2a2](https://github.com/ReventlessDev/reventless-core/commit/047d2a297cee4738b9daf50b1c988532db8e13df))


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
