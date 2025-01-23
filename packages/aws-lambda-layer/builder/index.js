import {join as joinPath, resolve as resolvePath, dirname} from 'node:path';
import {fileURLToPath} from 'node:url'
import {build as buildLayer} from '../lib/index.js';
import {decco, moment, bsMoment, objectAssign, rescriptDependent, reventless, bsPlatformDependent} from './postprocess.js';

const __dirname = dirname(fileURLToPath(import.meta.url));
const pathToLayerData = resolvePath(__dirname, 'layer/');
const pathToSavedDependencies = resolvePath(__dirname, 'layer/nodejs/node_modules');
const dependenciesPath = resolvePath(pathToLayerData, pathToSavedDependencies);

const opt = {
    //pathToSourcePackage: '../reventless-aws',
    sourcePackageName: '@reventless/reventless-aws',
    sourcePackageVersion: '2.0.3-runtime.7',
    pathToLayerData,
    pathToSavedDependencies,
    excludeScopes: ['pulumi', 'types', 'opentelemetry'],
    excludeModules: ['aws-sdk'],
    postProcess: {
        "@rescript-labs/decco": (node, cwd) => decco(node, cwd, dependenciesPath),
        "@reventless/reventless": reventless,
        ">rescript": rescriptDependent,
        ">bs-platform": bsPlatformDependent,//FIXME: does this work?
        "object-assign": objectAssign,
        "moment": moment,
        "bs-moment": (node, cwd) => bsMoment(node, cwd, dependenciesPath),
    }
};

buildLayer(opt);
