# Change Log

All notable changes to this project will be documented in this file.
See [Conventional Commits](https://conventionalcommits.org) for commit guidelines.

# 1.0.0-alpha.24 (2026-11-07)

**Note:** Version bump only for package @reventlessdev/reventless-registration





# 1.0.0-alpha.23 (2026-11-06)

**Note:** Version bump only for package @reventlessdev/reventless-registration





# 1.0.0-alpha.22 (2026-11-06)

### Bug Fixes

* **deps:** update sury to 11.1.0 ([512bc78](https://github.com/ReventlessDev/reventless-core/commit/512bc78da92c03664fa52fb3ab32df65f5e49b19))


# 1.0.0-alpha.21 (2026-11-05)

### Bug Fixes

* **registration:** the sign-up and completion doors keep the address out of their audit rows ([814e436](https://github.com/ReventlessDev/reventless-core/commit/814e436320d47c03e76cdb0abc7e4105e5112600))
* refactor(registration)!: the ledger names the fingerprint emailId and the sealed address email ([6fa0f11](https://github.com/ReventlessDev/reventless-core/commit/6fa0f1148abee3301a5cb86484dce524975b8a40))

### BREAKING CHANGES

* the ledger's stored events change field names. Ledger
events written before this do not decode; a local platform's ledger needs
a fresh database or a wipe of its registration events. Code that builds or
matches the ledger's commands and events renames email to emailId and
address to email.



# 1.0.0-alpha.20 (2026-11-05)

**Note:** Version bump only for package @reventlessdev/reventless-registration





# 1.0.0-alpha.19 (2026-11-02)

**Note:** Version bump only for package @reventlessdev/reventless-registration





# 1.0.0-alpha.18 (2026-11-01)

**Note:** Version bump only for package @reventlessdev/reventless-registration





# 1.0.0-alpha.17 (2026-10-30)

**Note:** Version bump only for package @reventlessdev/reventless-registration





# 1.0.0-alpha.16 (2026-10-30)

**Note:** Version bump only for package @reventlessdev/reventless-registration





# 1.0.0-alpha.15 (2026-10-30)

**Note:** Version bump only for package @reventlessdev/reventless-registration





# 1.0.0-alpha.14 (2026-10-30)

**Note:** Version bump only for package @reventlessdev/reventless-registration





# 1.0.0-alpha.13 (2026-10-30)

**Note:** Version bump only for package @reventlessdev/reventless-registration





# 1.0.0-alpha.12 (2026-10-29)

### Features

* **registration:** an erased account releases its address ([3731676](https://github.com/ReventlessDev/reventless-core/commit/37316763bbbbcf088d89ae14cd66715b444a142d))


# 1.0.0-alpha.11 (2026-10-29)

**Note:** Version bump only for package @reventlessdev/reventless-registration





# 1.0.0-alpha.10 (2026-10-29)

**Note:** Version bump only for package @reventlessdev/reventless-registration





# 1.0.0-alpha.9 (2026-10-29)

**Note:** Version bump only for package @reventlessdev/reventless-registration





# 1.0.0-alpha.8 (2026-10-29)

* feat(ppx)!: `@pii` marks a value about a person, and an event reads it as `Pii.t` ([37174c1](https://github.com/ReventlessDev/reventless-core/commit/37174c10eb80e9e3adbb93a52ad7a9ef5def7100))

### BREAKING CHANGES

* the ledger's events carry `address: Pii.t<Email.t>`. Pattern-match
`Value(address)` where the address is read.

The published per-platform PPX binary does not know `@pii` until it is republished.

Step PD2 of docs/plans/a-personal-field-is-marked-redacted-and-encrypted-at-the-seam.md.
Claude-Session: https://claude.ai/code/session_01HiQfdxVEsHwLHRoHSUcus1



# 1.0.0-alpha.7 (2026-10-29)

* feat(ppx)!: `@pii` marks a value about a person, and an event reads it as `Pii.t` ([37174c1](https://github.com/ReventlessDev/reventless-core/commit/37174c10eb80e9e3adbb93a52ad7a9ef5def7100))

### BREAKING CHANGES

* the ledger's events carry `address: Pii.t<Email.t>`. Pattern-match
`Value(address)` where the address is read.

The published per-platform PPX binary does not know `@pii` until it is republished.

Step PD2 of docs/plans/a-personal-field-is-marked-redacted-and-encrypted-at-the-seam.md.
Claude-Session: https://claude.ai/code/session_01HiQfdxVEsHwLHRoHSUcus1



# 1.0.0-alpha.6 (2026-10-29)

* feat(ppx)!: `@pii` marks a value about a person, and an event reads it as `Pii.t` ([37174c1](https://github.com/ReventlessDev/reventless-core/commit/37174c10eb80e9e3adbb93a52ad7a9ef5def7100))

### BREAKING CHANGES

* the ledger's events carry `address: Pii.t<Email.t>`. Pattern-match
`Value(address)` where the address is read.

The published per-platform PPX binary does not know `@pii` until it is republished.

Step PD2 of docs/plans/a-personal-field-is-marked-redacted-and-encrypted-at-the-seam.md.
Claude-Session: https://claude.ai/code/session_01HiQfdxVEsHwLHRoHSUcus1



# 1.0.0-alpha.5 (2026-10-29)

* feat(registration)!: the ledger tags an address by its keyed fingerprint ([ccafddf](https://github.com/ReventlessDev/reventless-core/commit/ccafddfc7eb8039687afc62a483ce34b8e7081dd))

### BREAKING CHANGES

* `Secrets.t` has a third field, `fingerprint`; a hand-built provider
adds it. `Register` and `Invite` take `address`, and their `email` is the
fingerprint from `ContactAddressId.fingerprint`, not `makeFromString(address)`.

Step PD5 of docs/plans/a-personal-field-is-marked-redacted-and-encrypted-at-the-seam.md.
Claude-Session: https://claude.ai/code/session_01HiQfdxVEsHwLHRoHSUcus1



# 1.0.0-alpha.4 (2026-10-29)

**Note:** Version bump only for package @reventlessdev/reventless-registration





# 1.0.0-alpha.3 (2026-10-25)

**Note:** Version bump only for package @reventlessdev/reventless-registration





# 1.0.0-alpha.2 (2026-10-25)

### Features

* **admission:** the open-roles view marks itself, and the shell's key names its query ([4b91015](https://github.com/ReventlessDev/reventless-core/commit/4b910153c3c477b6830ce4636b93ed5b4dfde482))
* **registration:** an invitation's code names the roles it grants ([3d1b619](https://github.com/ReventlessDev/reventless-core/commit/3d1b619797d51023d773fd5b21f2c7a782310475))


# 1.0.0-alpha.1 (2026-10-25)

### Features

* **registration:** the ledger takes an invitation, a reissued code and a withdrawal ([5d72df0](https://github.com/ReventlessDev/reventless-core/commit/5d72df097b15af8aa1799995efe79cdb2929267f))
* self-registration ships as a library of slices an app's plugin lists ([43883ca](https://github.com/ReventlessDev/reventless-core/commit/43883ca382339033f934c3ef92585dc8fde8bd37))
