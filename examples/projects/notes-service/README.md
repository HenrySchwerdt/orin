# notes-service

A small concurrent HTTP/JSON service: in-memory notes. It is a project to copy: a package with several modules, unit tests,
and the concurrency pattern the language asks for.

```
GET  /health        200 {"status":"ok"}
GET  /notes         200 [{"id":1,"title":"milk","text":"2 litres"}, ...]
POST /notes         201 + the new note       body: {"title":"milk","text":"2 litres"} (both members required, no others)
GET  /notes/{id}    200 + the note, 404 if absent, 400 if the id is not a number
```

Errors are JSON too: `{"error":"..."}` with 400, 404, 405 or 507 (store full, 1000 notes).

## What it shows

| File | Role |
|---|---|
| `src/store.or` | the notes as a plain value with pure operations (`addNote`, `findNote`); no I/O, no tasks |
| `src/routes.or` | method and target to a `Route` union; pure |
| `src/api.or` | `handle(store, method, target, body)` returns the new store and the answer; JSON in and out with `std:json` and `std:json/decode`; pure |
| `src/owner.or` | the **owner task**: it holds the only store and answers commands from a channel |
| `src/server.or` | `std:net` + `std:http`: accept loop, bounded queue, fixed worker pool, one connection per worker at a time |
| `src/main.or` | arguments and wiring |
| `tests/*_test.or` | unit tests of the store, the routing and the whole API, no sockets needed |

**Shared state.** Orin tasks share no mutable state (every heap object belongs to one task, see
[docs/concurrency.md](../../../docs/concurrency.md)). So the store lives in one owner task. A worker sends a `Command` (method,
target, body, and a private reply channel) and waits for the `Answer`. The owner handles commands one at a time, so every request is
atomic and ids never collide, with no locks in the program. Shutdown goes in dependency order: stop accepting, workers finish, then
the command channel is closed and the owner ends.

**Network authority.** The listener is bound through a network grant narrowed to `127.0.0.1`; the program cannot open any other
socket whatever its code does. Limits (head 16 KiB, body 64 KiB, 100 requests per connection, 5 s deadlines) are the ones of
[examples/http_server.or](../../http_server.or), which explains the accept and worker design in detail.

## Build, run, test

From this directory, with `orin` installed ([docs/getting-started.md](../../../docs/getting-started.md), [docs/cli.md](../../../docs/cli.md)):

```sh
orin test                  # unit tests
orin run -- 8080           # serve on 127.0.0.1:8080 until stopped
orin build                 # build/dev/notes-service
```

Arguments: `notes-service [port] [maxConnections]`. Port `0` picks a free port and prints `listening on 127.0.0.1:PORT` on
stderr. `maxConnections` makes the server exit after serving that many connections (`0` = run forever), which is how the CI test
ends it.

```sh
curl -s -X POST -d '{"title":"milk","text":"2 litres"}' http://127.0.0.1:8080/notes
curl -s http://127.0.0.1:8080/notes
```

In a source checkout use `./tools/orin` instead of `orin`.

## CI

`python3 tools/test_example_projects.py --orinc build/bootstrap/orin2` builds the project, runs the unit tests, starts the service on
port 0 with a connection budget, and drives it with `tools/notes_service_client.py` (every route and error status, a
keep-alive connection, 8 concurrent writers whose 40 notes must get unique consecutive ids), then waits for the server to exit.
