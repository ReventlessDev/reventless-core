export const createFiles = {
  type: 'addMany',
  destination: 'spec/',
  base: 'plop-templates/PluginSpec/',
  templateFiles: 'plop-templates/PluginSpec/**/*',
  globOptions: {dot: true}
};
export const npmInstall = (plop, data) => ({
  type: 'npmInstall',
  path: `${process.cwd()}/spec`,
  verbose: true
});
export const rebuild = (plop, data) => ({
  type: 'rebuild',
  path: `${process.cwd()}/spec`,
  verbose: true,
  abortOnFail: false
});
