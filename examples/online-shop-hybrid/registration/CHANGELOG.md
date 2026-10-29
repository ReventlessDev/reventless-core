# Change Log

All notable changes to this project will be documented in this file.
See [Conventional Commits](https://conventionalcommits.org) for commit guidelines.

# 1.0.0-alpha.4 (2026-10-29)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-registration





# 1.0.0-alpha.3 (2026-10-25)

**Note:** Version bump only for package @reventlessdev/online-shop-hybrid-registration





# 1.0.0-alpha.2 (2026-10-25)

### Features

* **admission:** the open-roles view marks itself, and the shell's key names its query ([4b91015](https://github.com/ReventlessDev/reventless-core/commit/4b910153c3c477b6830ce4636b93ed5b4dfde482))
* **registration:** an invitation's code names the roles it grants ([3d1b619](https://github.com/ReventlessDev/reventless-core/commit/3d1b619797d51023d773fd5b21f2c7a782310475))


# 1.0.0-alpha.1 (2026-10-25)

* refactor!: internal results and tool records whose parts may be absent are optional fields ([7009ddf](https://github.com/ReventlessDev/reventless-core/commit/7009ddf5d522f39ec9946a3b5cd062ceae889bbf))
### Features

* a plugin declares per role how a person is admitted, and the local platform honors the self-service and provisioned halves ([9c37bf5](https://github.com/ReventlessDev/reventless-core/commit/9c37bf50f15cac1703bf2c351713518121a56211))
* **example:** a registered address is told someone tried at most once an hour ([be0e5ea](https://github.com/ReventlessDev/reventless-core/commit/be0e5ea6b4b397a1de8df9bdd1b0599e7554f081))
* **example:** self-registration on the local platform, verify-then-create with the password kept out of the log ([739719d](https://github.com/ReventlessDev/reventless-core/commit/739719d279b5a4674fad3396c3431f7bf7f05035))
* **registration:** the ledger takes an invitation, a reissued code and a withdrawal ([5d72df0](https://github.com/ReventlessDev/reventless-core/commit/5d72df097b15af8aa1799995efe79cdb2929267f))
* self-registration ships as a library of slices an app's plugin lists ([43883ca](https://github.com/ReventlessDev/reventless-core/commit/43883ca382339033f934c3ef92585dc8fde8bd37))

### BREAKING CHANGES

* code that builds these records drops `name: None` and
writes `name: x` for `name: Some(x)`; a destructure of one of them binds a
field that may be absent with `?name`.
