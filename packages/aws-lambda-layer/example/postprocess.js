import { cp } from 'node:fs';
import { dirname, resolve as resolvePath } from 'node:path';
import { fileURLToPath } from 'node:url';
import { rimraf } from 'rimraf';

const __dirname = dirname(fileURLToPath(import.meta.url));
const precompiledPath = resolvePath(__dirname, './precompiled');

export async function decco(node, cwd, dependenciesPath) {
    await new Promise((resolve, reject) =>
        cp(
            resolvePath(precompiledPath, 'decco@1.6.0'),
            resolvePath(dependenciesPath, 'decco'),
            { recursive: true },
            (err) => {
                if (err) {
                    reject(err)
                } else {
                    resolve()
                }
            }
        )
    );
    return rimraf('ppx*', { glob: { cwd } });
}

export async function rescriptDependent(node, cwd) {
    const rmRes = rimraf('**/*.res', { glob: { cwd } });
    const rmResi = rimraf('**/*.resi', { glob: { cwd } });
    return Promise.all([rmRes, rmResi]);
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