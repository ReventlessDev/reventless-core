open QueryDb;

type primitives('id, 'state) = {
  load: load('id, 'state),
  save: save('id, 'state),
  saveBatch: saveBatch('id, 'state),
  delete: delete('id),
};
