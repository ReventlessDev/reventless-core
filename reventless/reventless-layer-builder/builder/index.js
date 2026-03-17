import { resolve as resolvePath, dirname } from 'node:path';
import { fileURLToPath } from 'node:url'
import { build as buildLayer } from '../src/index.js';
import { rescriptDependent, reventlessCore, deleteTests, deleteEffectSrc } from './postprocess.js';

const __dirname = dirname(fileURLToPath(import.meta.url));
const pathToLayerData = resolvePath(__dirname, 'layer/');
const pathToSavedDependencies = resolvePath(__dirname, 'layer/nodejs/node_modules');

const sourcePackageVersion = process.env.REVENTLESS_AWS_VERSION || 'latest';

const opt = {
    sourcePackageName: '@reventlessdev/reventless-aws',
    sourcePackageVersion,
    pathToLayerData,
    pathToSavedDependencies,
    excludeScopes: ['pulumi', 'types', 'opentelemetry', 'aws-sdk', 'smithy', 'sigstore'],
    excludeModules: ['aws-sdk', 'sury-ppx', 'fast-check'],
    registryOpts: {
        "@reventlessdev:registry": "https://npm.pkg.github.com",
        "//npm.pkg.github.com/:_authToken": process.env.NPM_GITHUB_TOKEN || process.env.NODE_AUTH_TOKEN
    },
    postProcess: {
        ">rescript": rescriptDependent,
        "@reventlessdev/reventless-core": reventlessCore,
        "@reventlessdev/rescript-effect": deleteTests,
        "effect": deleteEffectSrc
    }
};

buildLayer(opt);
