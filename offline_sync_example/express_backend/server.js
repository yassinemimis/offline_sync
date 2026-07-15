const express = require('express');
const app = express();
app.use(express.json());

// Logger middleware 
app.use((req, res, next) => {
  console.log(`${new Date().toISOString()}  ${req.method} ${req.path}`, req.body);
  next();
});

let todos = []; 

app.get('/todos', (req, res) => {
  
  res.json(todos.map(({ _version, ...rest }) => rest));
});

app.post('/todos', (req, res) => {
  const todo = { ...req.body, _version: 1 };
  todos.push(todo);
  console.log(`  → created ${todo.id} @ v1`);
  res.status(201).json(todo);
});

app.put('/todos/:id', (req, res) => {
  const index = todos.findIndex((t) => t.id === req.params.id);
  if (index === -1) return res.sendStatus(404);

  const current = todos[index];
  const incomingVersion = req.body._version;

  if (incomingVersion !== current._version) {
    console.log(
      `  ⚠ conflict on ${req.params.id}: client based on v${incomingVersion}, server is at v${current._version}`
    );
    return res.status(409).json(current);
  }

  const { _version, ...payload } = req.body;
  const updated = { ...payload, id: req.params.id, _version: current._version + 1 };
  todos[index] = updated;
  console.log(`  → updated ${req.params.id} → v${updated._version}`);
  res.json(updated);
});

app.delete('/todos/:id', (req, res) => {
  const index = todos.findIndex((t) => t.id === req.params.id);
  if (index === -1) return res.sendStatus(404);

  const current = todos[index];
  const incomingVersion = req.body?._version;

  if (incomingVersion !== current._version) {
    console.log(
      `  ⚠ conflict on delete ${req.params.id}: client based on v${incomingVersion}, server is at v${current._version}`
    );
    return res.status(409).json(current);
  }

  todos.splice(index, 1);
  console.log(`  → deleted ${req.params.id}`);
  res.sendStatus(204);
});

app.listen(3000, () => console.log('Backend listening on http://localhost:3000'));