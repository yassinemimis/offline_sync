const express = require('express');
const app = express();
app.use(express.json());

// Logger middleware
app.use((req, res, next) => {
  console.log(`${new Date().toISOString()}  ${req.method} ${req.path}`, req.body);
  next();
});

let todos = []; // active: { ...fields, _version, _serverModifiedAt }
let deletedTodos = []; // tombstones: { id, _version, _serverModifiedAt }

// Delta fetch — the ONLY thing this route does now. `since` omitted
// means "everything" (first pull for this entity). Always returns the
// {records, fetchedAt} envelope DioSyncTransport.fetchChanges expects —
// see its doc comment for the exact shape.
app.get('/todos', (req, res) => {
  const since = req.query.since ? new Date(req.query.since) : null;

  const changedTodos = todos.filter(
    (t) => !since || new Date(t._serverModifiedAt) > since,
  );
  const changedDeletes = deletedTodos.filter(
    (t) => !since || new Date(t._serverModifiedAt) > since,
  );

  const records = [
    ...changedTodos.map((t) => {
      const { _version, _serverModifiedAt, ...data } = t;
      return {
        id: t.id,
        deleted: false,
        version: _version,
        updatedAt: t.updatedAt, // the entity's own business field
        data,
      };
    }),
    ...changedDeletes.map((t) => ({
      id: t.id,
      deleted: true,
      version: t._version,
      updatedAt: t._serverModifiedAt,
    })),
  ];

  console.log(
    `  → delta fetch: ${records.length} record(s) since ${
      since ? since.toISOString() : '(beginning)'
    }`,
  );

  res.json({
    records,
    fetchedAt: new Date().toISOString(),
  });
});

app.post('/todos', (req, res) => {
  const todo = {
    ...req.body,
    _version: 1,
    _serverModifiedAt: new Date().toISOString(),
  };
  todos.push(todo);
  console.log(`  → created ${todo.id} @ v1`);

  const { _serverModifiedAt, ...responseBody } = todo;
  res.status(201).json(responseBody);
});

app.put('/todos/:id', (req, res) => {
  const index = todos.findIndex((t) => t.id === req.params.id);
  if (index === -1) return res.sendStatus(404);

  const current = todos[index];
  const incomingVersion = req.body._version;

  if (incomingVersion !== current._version) {
    console.log(
      `  ⚠ conflict on ${req.params.id}: client based on v${incomingVersion}, server is at v${current._version}`,
    );
    const { _serverModifiedAt, ...conflictBody } = current;
    return res.status(409).json(conflictBody);
  }

  const { _version, ...payload } = req.body;
  const updated = {
    ...payload,
    id: req.params.id,
    _version: current._version + 1,
    _serverModifiedAt: new Date().toISOString(),
  };
  todos[index] = updated;
  console.log(`  → updated ${req.params.id} → v${updated._version}`);

  const { _serverModifiedAt, ...responseBody } = updated;
  res.json(responseBody);
});

app.delete('/todos/:id', (req, res) => {
  const index = todos.findIndex((t) => t.id === req.params.id);
  if (index === -1) return res.sendStatus(404);

  const current = todos[index];
  const incomingVersion = req.body?._version;

  if (incomingVersion !== current._version) {
    console.log(
      `  ⚠ conflict on delete ${req.params.id}: client based on v${incomingVersion}, server is at v${current._version}`,
    );
    const { _serverModifiedAt, ...conflictBody } = current;
    return res.status(409).json(conflictBody);
  }

  todos.splice(index, 1);
  // Tombstone kept (not just discarded) so a future delta pull can tell
  // clients "this no longer exists" — see DeltaRecord.deleted.
  deletedTodos.push({
    id: current.id,
    _version: current._version + 1,
    _serverModifiedAt: new Date().toISOString(),
  });
  console.log(`  → deleted ${req.params.id}`);
  res.sendStatus(204);
});

app.listen(3000, () => console.log('Backend listening on http://localhost:3000'));