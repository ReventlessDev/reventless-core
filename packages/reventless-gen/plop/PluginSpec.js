export const createPluginSpecFiles = {
  type: 'addMany',
  destination: 'spec/',
  base: 'plop-templates/PluginSpec/',
  templateFiles: 'plop-templates/PluginSpec/**/*',
  globOptions: {dot: true}
};
export const gitInitPluginSpec = (plop, data) => ({
  type: 'gitInit',
  path: `${process.cwd()}/spec/`,
  verbose: true,
  abortOnFail: false
});
export const npmInstallPluginSpec = (plop, data) => ({
  type: 'npmInstall',
  path: `${process.cwd()}/spec`,
  verbose: true
});
export const rebuildPluginSpec = (plop, data) => ({
  type: 'rebuild',
  path: `${process.cwd()}/spec`,
  verbose: true,
  abortOnFail: false
});
