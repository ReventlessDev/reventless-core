# Change Log

All notable changes to this project will be documented in this file.
See [Conventional Commits](https://conventionalcommits.org) for commit guidelines.

# 3.0.0-alpha.90 (2026-08-12)

**Note:** Version bump only for package @reventlessdev/reventless-postgres





# 3.0.0-alpha.89 (2026-08-12)

### Features

* **queries:** narrow owner-bearing reads to the caller ([ba9cc3d](https://github.com/ReventlessDev/reventless-core/commit/ba9cc3d58d7914a9e4827bda90a704a74b1b82dd))


# 3.0.0-alpha.88 (2026-08-11)

**Note:** Version bump only for package @reventlessdev/reventless-postgres





# 3.0.0-alpha.87 (2026-08-10)

**Note:** Version bump only for package @reventlessdev/reventless-postgres





# 3.0.0-alpha.86 (2026-08-10)

**Note:** Version bump only for package @reventlessdev/reventless-postgres





# 3.0.0-alpha.85 (2026-08-09)

**Note:** Version bump only for package @reventlessdev/reventless-postgres





# 3.0.0-alpha.84 (2026-08-09)

**Note:** Version bump only for package @reventlessdev/reventless-postgres





# 3.0.0-alpha.83 (2026-08-09)

**Note:** Version bump only for package @reventlessdev/reventless-postgres





# 3.0.0-alpha.82 (2026-08-09)

**Note:** Version bump only for package @reventlessdev/reventless-postgres





# 3.0.0-alpha.81 (2026-08-08)

**Note:** Version bump only for package @reventlessdev/reventless-postgres





# 3.0.0-alpha.80 (2026-08-08)

**Note:** Version bump only for package @reventlessdev/reventless-postgres





# 3.0.0-alpha.79 (2026-08-08)

**Note:** Version bump only for package @reventlessdev/reventless-postgres





# 3.0.0-alpha.78 (2026-08-07)

**Note:** Version bump only for package @reventlessdev/reventless-postgres





# 3.0.0-alpha.77 (2026-08-05)

**Note:** Version bump only for package @reventlessdev/reventless-postgres





# 3.0.0-alpha.76 (2026-08-04)

**Note:** Version bump only for package @reventlessdev/reventless-postgres





# 3.0.0-alpha.75 (2026-08-04)

**Note:** Version bump only for package @reventlessdev/reventless-postgres





# 3.0.0-alpha.74 (2026-08-04)

**Note:** Version bump only for package @reventlessdev/reventless-postgres





# 3.0.0-alpha.73 (2026-08-03)

**Note:** Version bump only for package @reventlessdev/reventless-postgres





# 3.0.0-alpha.72 (2026-08-03)

**Note:** Version bump only for package @reventlessdev/reventless-postgres





# 3.0.0-alpha.71 (2026-08-03)

**Note:** Version bump only for package @reventlessdev/reventless-postgres





# 3.0.0-alpha.70 (2026-08-03)

**Note:** Version bump only for package @reventlessdev/reventless-postgres





# 3.0.0-alpha.69 (2026-08-02)

**Note:** Version bump only for package @reventlessdev/reventless-postgres





# 3.0.0-alpha.68 (2026-08-02)

**Note:** Version bump only for package @reventlessdev/reventless-postgres





# 3.0.0-alpha.67 (2026-08-02)

**Note:** Version bump only for package @reventlessdev/reventless-postgres





# 3.0.0-alpha.66 (2026-08-02)

**Note:** Version bump only for package @reventlessdev/reventless-postgres





# 3.0.0-alpha.65 (2026-08-02)

**Note:** Version bump only for package @reventlessdev/reventless-postgres





# 3.0.0-alpha.64 (2026-08-01)

**Note:** Version bump only for package @reventlessdev/reventless-postgres





# 3.0.0-alpha.63 (2026-08-01)

**Note:** Version bump only for package @reventlessdev/reventless-postgres





# 3.0.0-alpha.62 (2026-08-01)

**Note:** Version bump only for package @reventlessdev/reventless-postgres





# 3.0.0-alpha.61 (2026-08-01)

**Note:** Version bump only for package @reventlessdev/reventless-postgres





# 3.0.0-alpha.60 (2026-07-31)

**Note:** Version bump only for package @reventlessdev/reventless-postgres





# 3.0.0-alpha.59 (2026-07-30)

**Note:** Version bump only for package @reventlessdev/reventless-postgres





# 3.0.0-alpha.58 (2026-07-30)

**Note:** Version bump only for package @reventlessdev/reventless-postgres





# 3.0.0-alpha.57 (2026-07-30)

**Note:** Version bump only for package @reventlessdev/reventless-postgres





# 3.0.0-alpha.56 (2026-07-30)

**Note:** Version bump only for package @reventlessdev/reventless-postgres





# 3.0.0-alpha.55 (2026-07-29)

**Note:** Version bump only for package @reventlessdev/reventless-postgres





# 3.0.0-alpha.54 (2026-07-28)

**Note:** Version bump only for package @reventlessdev/reventless-postgres





# 3.0.0-alpha.53 (2026-07-28)

**Note:** Version bump only for package @reventlessdev/reventless-postgres





# 3.0.0-alpha.52 (2026-07-28)

**Note:** Version bump only for package @reventlessdev/reventless-postgres





# 3.0.0-alpha.51 (2026-07-28)

**Note:** Version bump only for package @reventlessdev/reventless-postgres





# 3.0.0-alpha.50 (2026-07-27)

**Note:** Version bump only for package @reventlessdev/reventless-postgres





# 3.0.0-alpha.49 (2026-07-27)

**Note:** Version bump only for package @reventlessdev/reventless-postgres





# 3.0.0-alpha.48 (2026-07-27)

* refactor(aws)!: convert remaining Group-1 entry points to typed-core/thin-shell; fix Counter publish + EP stub wiring ([d7f1aeb](https://github.com/ReventlessDev/reventless-core/commit/d7f1aeb90cfc122106ccc3ffa522911fba5db2de))

### BREAKING CHANGES

* reventless-postgres QueryEnginePostgres.Make no longer
exposes the dead deploy-time `make` (queryEngineMaker); its Pulumi.Output
wrap was the last @pulumi/pulumi import in the PgQueryResolver Lambda's
cold-start graph. Pure helpers now alias QueryDbStorage_Postgres_Ops.



# 3.0.0-alpha.47 (2026-07-27)

**Note:** Version bump only for package @reventlessdev/reventless-postgres





# 3.0.0-alpha.46 (2026-07-26)

**Note:** Version bump only for package @reventlessdev/reventless-postgres





# 3.0.0-alpha.45 (2026-07-26)

**Note:** Version bump only for package @reventlessdev/reventless-postgres





# 3.0.0-alpha.44 (2026-07-24)

**Note:** Version bump only for package @reventlessdev/reventless-postgres





# 3.0.0-alpha.43 (2026-07-23)

**Note:** Version bump only for package @reventlessdev/reventless-postgres





# 3.0.0-alpha.42 (2026-07-22)

**Note:** Version bump only for package @reventlessdev/reventless-postgres





# 3.0.0-alpha.41 (2026-07-22)

**Note:** Version bump only for package @reventlessdev/reventless-postgres





# 3.0.0-alpha.40 (2026-07-22)

**Note:** Version bump only for package @reventlessdev/reventless-postgres





# 3.0.0-alpha.39 (2026-07-22)

### Features

* **core:** attribute shared substrate to the plugin that owns it ([a440d4f](https://github.com/ReventlessDev/reventless-core/commit/a440d4f827dfab9e2e9a763ffd9fc40240852e09))


# 3.0.0-alpha.38 (2026-07-21)

**Note:** Version bump only for package @reventlessdev/reventless-postgres





# 3.0.0-alpha.37 (2026-07-20)

**Note:** Version bump only for package @reventlessdev/reventless-postgres





# 3.0.0-alpha.36 (2026-07-17)

**Note:** Version bump only for package @reventlessdev/reventless-postgres





# 3.0.0-alpha.35 (2026-07-17)

**Note:** Version bump only for package @reventlessdev/reventless-postgres





# 3.0.0-alpha.34 (2026-07-16)

**Note:** Version bump only for package @reventlessdev/reventless-postgres





# 3.0.0-alpha.33 (2026-07-15)

**Note:** Version bump only for package @reventlessdev/reventless-postgres





# 3.0.0-alpha.32 (2026-07-14)

**Note:** Version bump only for package @reventlessdev/reventless-postgres





# 3.0.0-alpha.31 (2026-07-14)

**Note:** Version bump only for package @reventlessdev/reventless-postgres





# 3.0.0-alpha.30 (2026-07-14)

**Note:** Version bump only for package @reventlessdev/reventless-postgres





# 3.0.0-alpha.29 (2026-07-13)

**Note:** Version bump only for package @reventlessdev/reventless-postgres





# 3.0.0-alpha.28 (2026-07-13)

**Note:** Version bump only for package @reventlessdev/reventless-postgres





# 3.0.0-alpha.27 (2026-07-13)

**Note:** Version bump only for package @reventlessdev/reventless-postgres





# 3.0.0-alpha.26 (2026-07-13)

**Note:** Version bump only for package @reventlessdev/reventless-postgres





# 3.0.0-alpha.25 (2026-07-13)

**Note:** Version bump only for package @reventlessdev/reventless-postgres





# 3.0.0-alpha.24 (2026-07-13)

**Note:** Version bump only for package @reventlessdev/reventless-postgres





# 3.0.0-alpha.23 (2026-07-12)

**Note:** Version bump only for package @reventlessdev/reventless-postgres





# 3.0.0-alpha.22 (2026-07-12)

**Note:** Version bump only for package @reventlessdev/reventless-postgres





# 3.0.0-alpha.21 (2026-07-12)

**Note:** Version bump only for package @reventlessdev/reventless-postgres





# 3.0.0-alpha.20 (2026-07-11)

**Note:** Version bump only for package @reventlessdev/reventless-postgres





# 3.0.0-alpha.19 (2026-07-11)

### Bug Fixes

* **build:** mark tests as dev-only sources so dependents don't compile them ([28b3b1c](https://github.com/ReventlessDev/reventless-core/commit/28b3b1ccfeaafc1d7050a86ce2362f32e4299187))


# 3.0.0-alpha.18 (2026-07-11)

**Note:** Version bump only for package @reventlessdev/reventless-postgres





# 3.0.0-alpha.17 (2026-07-10)

**Note:** Version bump only for package @reventlessdev/reventless-postgres





# 3.0.0-alpha.16 (2026-07-10)

**Note:** Version bump only for package @reventlessdev/reventless-postgres





# 3.0.0-alpha.15 (2026-07-10)

**Note:** Version bump only for package @reventlessdev/reventless-postgres





# 3.0.0-alpha.14 (2026-07-10)

**Note:** Version bump only for package @reventlessdev/reventless-postgres





# 3.0.0-alpha.13 (2026-07-09)

**Note:** Version bump only for package @reventlessdev/reventless-postgres





# 3.0.0-alpha.12 (2026-07-09)

**Note:** Version bump only for package @reventlessdev/reventless-postgres





# 3.0.0-alpha.11 (2026-07-08)

**Note:** Version bump only for package @reventlessdev/reventless-postgres





# 3.0.0-alpha.10 (2026-07-08)

**Note:** Version bump only for package @reventlessdev/reventless-postgres





# 3.0.0-alpha.9 (2026-07-08)

**Note:** Version bump only for package @reventlessdev/reventless-postgres





# 3.0.0-alpha.8 (2026-07-07)

**Note:** Version bump only for package @reventlessdev/reventless-postgres





# 3.0.0-alpha.7 (2026-07-07)

### Bug Fixes

* **reventless-postgres:** keep [@pulumi](https://github.com/pulumi) out of the deployed Lambda runtime graph ([0f363cd](https://github.com/ReventlessDev/reventless-core/commit/0f363cd273590591c8f9353fa38ac8b6072e6c49))


# 3.0.0-alpha.6 (2026-07-06)

### Features

* **reventless-postgres,reventless-aws:** items (sub-id connection) resolver for Postgres reads (B3.2c) ([2477220](https://github.com/ReventlessDev/reventless-core/commit/247722062913f5d0bcb5895b152f05033d8297d8))


# 3.0.0-alpha.5 (2026-07-06)

### Features

* **reventless-aws:** classic EventLog Postgres deploy-time wiring + relay (B1 vertical) ([8235ba4](https://github.com/ReventlessDev/reventless-core/commit/8235ba44e506f7094d17251405c6a05c39789805))
* **reventless-aws:** Postgres QueryDb storage vertical (B3.1) ([51a7993](https://github.com/ReventlessDev/reventless-core/commit/51a79934c1d9f59bb6f61233a90651d5eadf9f4e))
* **reventless-postgres:** QueryEnginePostgres list/index/byIds resolver push-downs (B3.2a-1) ([8cb09e4](https://github.com/ReventlessDev/reventless-core/commit/8cb09e40cffa9698a251f1ee3fb17b016c4f8b07))


# 3.0.0-alpha.4 (2026-07-05)

### Features

* **reventless-postgres:** classic event_log change feed (B2.5) ([59529c7](https://github.com/ReventlessDev/reventless-core/commit/59529c795395f37d29e935ba2d6bd5a3e7e8b5c0))


# 3.0.0-alpha.3 (2026-07-05)

**Note:** Version bump only for package @reventlessdev/reventless-postgres





# 3.0.0-alpha.2 (2026-07-05)

**Note:** Version bump only for package @reventlessdev/reventless-postgres





# 3.0.0-alpha.1 (2026-07-05)

### Features

* **postgres:** add reventless-postgres backend + local-platform integration ([6913200](https://github.com/ReventlessDev/reventless-core/commit/69132001f9271e832a5af33416acd5b645feaf47))
* **postgres:** cold-start pool foundation for AWS Postgres adapters ([b393449](https://github.com/ReventlessDev/reventless-core/commit/b393449769b6cd92abd03d2d5e7f564fe092938e))
