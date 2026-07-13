const express = require("express");
const cors = require("cors");

const app = express();

app.use(cors());
app.use(express.json());

// Logger Middleware
app.use((req, res, next) => {
    const now = new Date().toLocaleTimeString();

    console.log("=================================");
    console.log(`[${now}] ${req.method} ${req.originalUrl}`);

    if (Object.keys(req.body).length > 0) {
        console.log("Body:");
        console.log(req.body);
    }

    next();
});

const todos = [];

app.get("/", (req, res) => {
    res.send("Offline Sync Example API");
});

app.get("/todos", (req, res) => {
    res.json(todos);
});

app.post("/todos", (req, res) => {
    todos.push(req.body);

    console.log("Todo created.");

    res.status(201).json(req.body);
});

app.put("/todos/:id", (req, res) => {
    const index = todos.findIndex(t => t.id === req.params.id);

    if (index === -1)
        return res.sendStatus(404);

    todos[index] = req.body;

    console.log("Todo updated.");

    res.json(req.body);
});

app.delete("/todos/:id", (req, res) => {
    const index = todos.findIndex(t => t.id === req.params.id);

    if (index === -1)
        return res.sendStatus(404);

    todos.splice(index, 1);

    console.log("Todo deleted.");

    res.sendStatus(204);
});

app.listen(3000, () => {
    console.log("=================================");
    console.log("🚀 Offline Sync API");
    console.log("Listening on http://localhost:3000");
    console.log("=================================");
});