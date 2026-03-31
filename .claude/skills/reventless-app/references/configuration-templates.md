# Package Configuration Templates

## Spec Package

### package.json

```json
{
  "name": "@reventlessdev/{platform}-{plugin}-spec",
  "version": "1.0.0-alpha.0",
  "description": "{Plugin} extension point specifications",
  "license": "MIT",
  "scripts": {
    "build": "rescript build",
    "clean": "rescript clean",
    "rebuild": "npm run clean && npm run build -- -with-deps"
  },
  "dependencies": {
    "@reventlessdev/reventless-spec": "*",
    "sury": "^11.0.0-alpha.4"
  },
  "devDependencies": {
    "rescript": "^12.2.0",
    "sury-ppx": "^11.0.0-alpha.2"
  },
  "peerDependencies": {
    "rescript": "^12.2.0"
  },
  "publishConfig": {
    "registry": "https://npm.pkg.github.com"
  }
}
```

### rescript.json

```json
{
  "name": "@reventlessdev/{platform}-{plugin}-spec",
  "namespace": "{Plugin}Spec",
  "ppx-flags": ["sury-ppx/bin"],
  "warnings": { "error": "-44+101" },
  "sources": [
    { "dir": "src", "subdirs": true }
  ],
  "dependencies": [
    "sury",
    "@reventlessdev/reventless-spec"
  ],
  "compiler-flags": []
}
```

## Plugin Package

### package.json

```json
{
  "name": "@reventlessdev/{platform}-{plugin}",
  "version": "1.0.0-alpha.0",
  "description": "{Plugin} plugin — {description}",
  "license": "MIT",
  "scripts": {
    "build": "rescript build",
    "start": "rescript build -w",
    "clean": "rescript clean",
    "rebuild": "npm run clean && npm run build -- -with-deps",
    "test": "NODE_OPTIONS='--experimental-vm-modules' npx jest"
  },
  "jest": {
    "testMatch": ["<rootDir>/tests/**/*Test.res.mjs"],
    "moduleFileExtensions": ["js", "mjs"],
    "moduleNameMapper": {
      "^@npmcli/arborist$": "<rootDir>/__mocks__/emptyModule.js",
      "^spdx-license-ids$": "<rootDir>/../../../node_modules/spdx-license-ids/index.json",
      "^spdx-license-ids/deprecated$": "<rootDir>/../../../node_modules/spdx-license-ids/deprecated.json",
      "^spdx-exceptions$": "<rootDir>/../../../node_modules/spdx-exceptions/index.json"
    }
  },
  "dependencies": {
    "@reventlessdev/{platform}-{plugin}-spec": "*",
    "@reventlessdev/reventless-in-memory": "*",
    "@reventlessdev/reventless-spec": "*",
    "sury": "^11.0.0-alpha.4"
  },
  "devDependencies": {
    "@glennsl/rescript-jest": "^0.13.1",
    "rescript": "^12.2.0",
    "sury-ppx": "^11.0.0-alpha.2"
  },
  "peerDependencies": {
    "rescript": "^12.2.0"
  },
  "publishConfig": {
    "registry": "https://npm.pkg.github.com"
  }
}
```

### rescript.json

```json
{
  "name": "@reventlessdev/{platform}-{plugin}",
  "namespace": "{Plugin}Plugin",
  "ppx-flags": ["sury-ppx/bin"],
  "warnings": { "error": "-44+101" },
  "sources": [
    { "dir": "src", "subdirs": true },
    { "dir": "tests", "subdirs": true }
  ],
  "dependencies": [
    "sury",
    "@reventlessdev/rescript-pulumi-pulumi",
    "@reventlessdev/reventless-spec",
    "@reventlessdev/reventless-infra",
    "@reventlessdev/reventless-in-memory",
    "@reventlessdev/{platform}-{plugin}-spec"
  ],
  "dev-dependencies": [
    "@glennsl/rescript-jest"
  ],
  "compiler-flags": []
}
```

**Add cross-plugin spec dependencies** when subscribing to other plugins' extension points:
```json
"dependencies": [
  "@reventlessdev/{platform}-{other-plugin}-spec"
]
```

## Platform Package

### package.json

```json
{
  "name": "@reventlessdev/{platform}",
  "version": "1.0.0-alpha.0",
  "description": "{Platform} — Reventless platform",
  "license": "MIT",
  "scripts": {
    "build": "rescript build",
    "start": "rescript build -w",
    "clean": "rescript clean",
    "rebuild": "npm run clean && npm run build -- -with-deps",
    "dev": "node src/Main.res.mjs"
  },
  "dependencies": {
    "@reventlessdev/{platform}-{plugin1}": "*",
    "@reventlessdev/{platform}-{plugin2}": "*",
    "@reventlessdev/reventless-in-memory": "*",
    "@reventlessdev/reventless-spec": "*",
    "sury": "^11.0.0-alpha.4"
  },
  "devDependencies": {
    "rescript": "^12.2.0",
    "sury-ppx": "^11.0.0-alpha.2"
  },
  "peerDependencies": {
    "rescript": "^12.2.0"
  }
}
```

### rescript.json

```json
{
  "name": "@reventlessdev/{platform}",
  "namespace": true,
  "ppx-flags": ["sury-ppx/bin"],
  "warnings": { "error": "-44+101" },
  "sources": [
    { "dir": "src", "subdirs": true }
  ],
  "dependencies": [
    "sury",
    "@reventlessdev/rescript-pulumi-pulumi",
    "@reventlessdev/reventless-spec",
    "@reventlessdev/reventless-infra",
    "@reventlessdev/reventless-in-memory",
    "@reventlessdev/{platform}-{plugin1}",
    "@reventlessdev/{platform}-{plugin2}"
  ],
  "compiler-flags": []
}
```

## Dependency Ordering

In both `package.json` and `rescript.json`, order dependencies:
1. Third-party (`sury`)
2. ReScript bindings (`rescript-pulumi-pulumi`)
3. Framework packages (`reventless-spec`, `reventless-infra`, `reventless-in-memory`)
4. Spec packages (`{platform}-{plugin}-spec`)
5. Plugin packages (`{platform}-{plugin}`)

## Jest Mock File

Create `__mocks__/emptyModule.js` in each plugin package:

```javascript
module.exports = {}
```

This prevents Jest from failing on optional native dependencies.
