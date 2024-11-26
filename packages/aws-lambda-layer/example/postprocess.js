import { cp } from 'node:fs';
import { dirname, resolve as resolvePath } from 'node:path';
import { fileURLToPath } from 'node:url';
import { rimraf } from 'rimraf';

const __dirname = dirname(fileURLToPath(import.meta.url));
const precompiledPath = resolvePath(__dirname, './precompiled');

function copyPrecompiled(source, target, dependenciesPath) {
    return new Promise((resolve, reject) =>
        cp(
            resolvePath(precompiledPath, source),
            resolvePath(dependenciesPath, target),
            { recursive: true },
            (err) => {
                if (err) {
                    reject(err)
                } else {
                    resolve()
                }
            }
        ));
}

export async function decco(node, cwd, dependenciesPath) {
    return Promise.all([
        //copyPrecompiled('decco@1.6.0', node.name, dependenciesPath),
        copyPrecompiled('@rescript-labs/decco@2.0.4', node.name, dependenciesPath),
        rimraf('ppx*', { glob: { cwd } })
    ]);
}

export async function bsMoment(node, cwd, dependenciesPath) {
    return copyPrecompiled('bs-moment@0.8.0', node.name, dependenciesPath);
}

export async function rescriptDependent(node, cwd) {
    const rmRes = rimraf('**/*.res', { glob: { cwd } });
    const rmResi = rimraf('**/*.resi', { glob: { cwd } });
    return Promise.all([rmRes, rmResi]);
}

export async function bsPlatformDependent(node, cwd) {
    const rmRes = rimraf('**/*.re', { glob: { cwd } });
    const rmResi = rimraf('**/*.rei', { glob: { cwd } });
    const rmLib = rimraf('lib', { glob: { cwd } });
    return Promise.all([rmRes, rmResi, rmLib]);
}

export async function reventless(node, cwd) {
    return rimraf([
        resolvePath(cwd, 'coverage'),
        resolvePath(cwd, 'scripts'),
        resolvePath(cwd, 'test-helper'),
        resolvePath(cwd, 'tests')
    ]);
}

export async function objectAssign(node, cwd) {
    return rimraf(resolvePath(cwd, 'test.html'));
}

export async function moment(node, cwd) {
    return rimraf([
        resolvePath(cwd, 'min'),
        resolvePath(cwd, 'src'),
        resolvePath(cwd, 'dist'),
    ]);
}