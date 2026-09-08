# Change Log

All notable changes to this project will be documented in this file.
See [Conventional Commits](https://conventionalcommits.org) for commit guidelines.

# 1.0.0-alpha.9 (2026-09-08)

**Note:** Version bump only for package @reventlessdev/trait-attachments





# 1.0.0-alpha.8 (2026-09-08)

### Features

* a slice folder is named for its kind, without the Slice ([a400555](https://github.com/ReventlessDev/reventless-core/commit/a400555121b023823983ebe846e99cda27063c1f))


# 1.0.0-alpha.7 (2026-09-07)

**Note:** Version bump only for package @reventlessdev/trait-attachments





# 1.0.0-alpha.6 (2026-09-07)

* refactor(traits)!: consumed facts are grouped, not suffixed ([a844b7a](https://github.com/ReventlessDev/reventless-core/commit/a844b7a99349ca20633d68cf32b95cb7677d02a4))
### Features

* **catalog:** the set says which member now stands, and orders freeze it ([79d882d](https://github.com/ReventlessDev/reventless-core/commit/79d882d094c11b35a1cb42958a89fc63561e43ab))

### BREAKING CHANGES

* a graft's `Binding` must expose `Consumed` instead of the
`*C` bindings. The scaffolds emit the new shape, so a regenerated graft is
already correct; a hand-written one moves its consumed builders into a module.



# 1.0.0-alpha.5 (2026-09-04)

**Note:** Version bump only for package @reventlessdev/trait-attachments





# 1.0.0-alpha.4 (2026-09-04)

### Features

* **spec,traits:** an image carries the text that goes with it, and a set's first member is its primary ([e4e5845](https://github.com/ReventlessDev/reventless-core/commit/e4e58458aee7b3db5564727d358a3a9767362ca4))
* **trait-attachments:** a host can bound its set to one, and the primary carries its caption ([af5953b](https://github.com/ReventlessDev/reventless-core/commit/af5953b73000fc401295d2c78eac667c4c78bf40))


# 1.0.0-alpha.3 (2026-09-02)

### Bug Fixes

* **traits:** a graft's consumed arms name the type its events carry ([e63e448](https://github.com/ReventlessDev/reventless-core/commit/e63e448df84f8b75d5f89f4fb4dd08728f30d5e5))


# 1.0.0-alpha.2 (2026-09-01)

**Note:** Version bump only for package @reventlessdev/trait-attachments





# 1.0.0-alpha.1 (2026-09-01)

### Features

* **spec:** a command declares its lifecycle edge as a value ([40eee9f](https://github.com/ReventlessDev/reventless-core/commit/40eee9f7723dc05e418be680528f01967d074da4))
* **spec:** a graft leaves a trace the deployed plugin can read ([c08ff6c](https://github.com/ReventlessDev/reventless-core/commit/c08ff6c0f6177d58603e7ae1e5cec392d9bac16a))
* **traits:** a conformance run leaves something a machine can read ([cd9cb81](https://github.com/ReventlessDev/reventless-core/commit/cd9cb81aa643f8e30ccf072df458fdc136897746))
* **traits:** a listing reads a trait instead of being told about it ([8a23219](https://github.com/ReventlessDev/reventless-core/commit/8a23219c5a69011ef9310ebf8bfcbf9315a577ba))
* **traits:** the attachments graft is written, not transcribed ([6d7330c](https://github.com/ReventlessDev/reventless-core/commit/6d7330c19381bb54d24c6d392a11ecec1a33a5be))
