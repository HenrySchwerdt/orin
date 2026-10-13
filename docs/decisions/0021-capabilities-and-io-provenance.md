# ADR-0021: Root capabilities, constrained derivation, and verifiable I/O provenance

Status: **proposed** (2026-10-13), except **Stage A (D1, the resource-handle part of D2, D4a handle identity, D7 Stage A), which is accepted and implemented** -- see Addendum A and [ADR-0027](0027-stage-a-root-capabilities.md). Everything else (D3 library adapters, D4 events beyond primitives, D5 process discovery, D6 attestations, Stages B-D) stays proposed. This ADR specifies the language/runtime authority model and the interfaces needed for OSIG processes and later field lineage. It does **not** claim that these mechanisms are implemented or that capabilities alone reconstruct processes.

Relates to [ADR-0016](0016-language-1.0-core-scope.md) (two-stage freeze), [ADR-0020](0020-verifiable-software-roadmap.md) D2–D5, [ADR-0023](0023-osig-schema-v0.1.md), [ADR-0025](0025-resources-and-streaming-fs.md), [spec 19](../../spec/19-self-hosted-runtime.md) and [docs/osig.md](../osig.md).

## Motivation and goals

Applications must be able to use third-party HTTP, Kafka, database and filesystem libraries while the compiler and OSIG can still identify **all mediated external I/O** and derive entry/exit boundaries. Libraries may explain that a network byte stream is, for example, a Kafka topic, but may **not forge privilege**, silently suppress underlying I/O, or upgrade an unverified protocol assertion to a proof.

The user-facing outcome is a navigable graph from a listener or consumer input, through the functions and data objects that handle it, to a producer, database, network or file output, with source-level explanations and explicit uncertainties. A pull request should compare these flows and their authorization.

**Critical distinction:** (1) authority = which external operations are permitted; (2) effects = which primitive operations a function can perform; (3) provenance = where data values originate and flow; (4) process = an interpreted slice of control/data flow connecting triggers to effects. A capability is **not** a process, a flow proof, or an annotation on every function.

## Decisions

### D1 — A closed, compiler/runtime-known primitive authority set

The platform defines the finite set of root authority families and the only primitive effect operations that use them. Proposed initial families:

- Network: Bind(local address/port), Accept(bound listener), Connect(remote endpoint), socket StreamRead/StreamWrite (bound to authenticated handle identity).
- Filesystem: Open(path/mode), FileRead, FileWrite (bound to opened file handles and allowed path scopes).
- Process: Spawn(executable/argv policy), stdio streams.
- Clock, entropy and environment access where observability/nondeterminism matters.

These are **operation kinds, not freely mintable global ambient tokens**. Actual handles are platform-created, opaque/nonforgeable, noncopyable resources, passed explicitly and narrowed without authority amplification. Root grants enter at the program root according to the trusted host/deployment policy. Every privileged L0 operation validates its handle and restrictions at runtime; static checks are additional, not a replacement. A valid network connection is not automatically a grant for every remote host or socket.

Network reads and writes carry direction and a concrete *handle identity*. They do not imply that an incoming socket is semantically an HTTP request or a Kafka message. FFI, native syscalls and dynamic libraries are unsafe boundaries: strict/certified builds must disallow them, isolate them or require an explicit trusted policy and mark data-flow evidence incomplete. Simply compiling to native code cannot enforce no-raw-syscall behavior; deployment isolation is necessary for that threat model.

### D2 — User-defined capability types are bounded derivations, not new authority

Libraries can declare **nominal**, parameterized derived capability types, e.g. KafkaConsume(broker, topic), KafkaPublish(broker, topic), HttpServe(address, port, route), DatabaseWrite(connection, table). Definitions include the primitive resource handles / constraints they require and can use; the compiler checks actual underlying accesses. Libraries cannot create root handles or arbitrarily extend permission.

Formally, for available grants G and any derived handle D:

    Authority(D) ⊆ Union(Authority(G))

All primitive I/O executed through D must remain inside G's effective allowlist. If a derived capability needs two grants, it must carry both; it cannot silently obtain either. Narrowing and composition preserve provenance of both parent grants. If a scope is dynamic, its exact value is tracked symbolically / as UNKNOWN and validated by the runtime when used.

Two derived capabilities built from the same *kinds* of root operations are **not equal**. Separate nominal identity, parameters, endpoint identity and direction from actual effective authority. Equality of granted primitive effects is not proof of protocol semantic equivalence or common data origin.

An ordinary pure helper, transform, or function with inputs/outputs **never requires a fresh capability definition**. Functions automatically acquire inferred effect summaries (transitively), while object/field flow is separately inferred from HIR/MIR.

### D3 — Enforcement rules for library authors

A library declaring a derived capability must provide an implementation whose privileged operations can be checked against the declared/available root handles. Compilation fails for missing/forged handles, unauthorized primitive effects, invalid widening, illegal storage/copy of resource handles, and disallowed FFI escapes.

The compiler **does not silently accept a library-declared high-level protocol boundary as verified**. A package may register a Kafka/HTTP semantic adapter only with explicitly indicated provenance evidence:

- ENFORCED: resource/operation restrictions are implemented by a trusted boundary or verifiable binding, backed by specified assumptions (e.g. broker-side ACLs; trusted protocol adapter).
- DERIVED: a concrete data dependency or primitive effect is established by compiler analysis, with uncertainty where necessary.
- DECLARED / ASSUMED: metadata from the package author, not verified protocol truth.
- UNKNOWN: resolution incomplete or opaque boundary.

These are **boundary/edge evidence attributes**, not substitutions for the proof-status vocabulary and assurance level mandated by ADR-0020 D1/D7. Crosswalk into the existing VERIFIED / ASSUMED / UNKNOWN plus assurance fields must be explicit. Do not label library-declared Kafka topic identities or an arbitrary handwritten parser as implementation-verified merely because they have an annotation.

An ordinary package with unproved higher-level semantics may still be built under non-strict policy; OSIG displays raw primitive I/O, declaring the protocol/topic UNKNOWN as appropriate. Under a policy requiring **verified HTTP/Kafka boundaries**, an unverified binding is a compilation/policy failure. This does not promise full arbitrary HTTP/Kafka protocol correctness (which may require trusted adapters or proof of protocol parsing and authorization).

### D4 — Semantic boundary contracts, without library-defined primitive events

Each primitive I/O boundary emits a stable semantic *event* independent of how library authors name their functions. Minimum event schema:

- operation kind; read/write direction; primitive handle identity and grant chain;
- optional normalized resource identity (address/port/path), dynamic-expression summary if unknown;
- source span and callable symbol; value IDs for bytes read/written;
- authorization result / denied attempt where instrumented, static-vs-runtime evidence;
- optional validated high-level adapter binding (HTTP route, Kafka broker/topic, database query/table).

Library packages may attach **typed boundary descriptions** to call/return/stream/callback relations (input payload, output payload, decode, dispatch, publish, response); these are checkable claims against actual data and control-flow where supported, never a way to invent or erase primitive effects. The compiler compares declared boundaries to actual effects and inferred flow and marks mismatches. A semantic adapter cannot grant permissions.

Example illustrative specification, **not current Orin syntax**:

~~~text
derive KafkaConsume(broker, topic) from Net.Connect(broker) {
    boundary input: KafkaMessage<T>;
    binding: trusted KafkaAdapter.receive(topic);
}

derive KafkaPublish(broker, topic) from Net.Connect(broker) {
    boundary output: KafkaMessage<T>;
    binding: trusted KafkaAdapter.send(topic);
}
~~~

Kafka protocol metadata cannot be reliably inferred from raw TCP bytes in arbitrary libraries. In strict verification, topic identity and restriction require a controlled adapter / externally enforced ACL or an independently checkable proof. A network grant alone does not enforce Kafka topic restriction.

### D4a — Explicit resource identities and verified bindings (the missing join key)

Separate three different concepts that must **never** collapse into one:

1. **Resource descriptor**: a typed, unprivileged identity for an external endpoint or logical object, e.g. `KafkaTopic(cluster, topic)`, `HttpRoute(listener, method, path)`, `DbTable(server, database, schema, table)`, `FilePath(root, relativePath)`. A package may define descriptor *types* without privileged authority. Constructing a descriptor does not grant access.
2. **Authorized resource handle**: a platform-issued or validly narrowed **noncopyable handle**, whose sealed origin, lifetime, parent grant IDs and enforced scope are checked at primitive operations. A descriptor cannot be cast into a handle. This reuses ADR-0025 resource discipline and its `MHandle` model rather than inventing another ownership mechanism.
3. **Semantic binding**: a proof/evidence-qualified association between an authorized handle/primitive event and a higher-level descriptor plus payload schema (for example, a Kafka frame decoded as `OrderCreated`). The descriptor is *not trusted* simply because a library supplies it.

**No new root permissions** are introduced by `resource`. A future `resource` declaration is a nominal, typed description for OSIG and capability parameters—not a new way to call the OS. The precise syntax and its interaction with the completed language freeze require an ADR-approved language extension; use a typed library descriptor and versioned manifest in the first implementation. Existing `File` is already a noncopyable OS handle and must not be confused with `FilePath` or with a new `resource` declaration.

The runtime stores the grant chain and restricted handle identity out of reach of Orin user code. The compiler models handles as scoped borrowed function parameters (as in ADR-0025). Derived typed views may only be passed/borrowed in supported scopes; they must not be stored in ordinary classes, returned, captured or copied until an explicit lifetime/ownership extension is separately reviewed. In particular, do **not** allow user-authored constructors or `as` casts to create a capability token. Any adapter introducing a long-lived server/consumer must have a trusted scoped lifecycle API (e.g. `withListener(grant, port, listener => ...)`) and an authorized host grant. Handle identity is not the same as OSIG descriptor identity.

**Resource identity rules:** a semantic identity is structured and canonicalized using a namespace controlled by its protocol adapter, rather than a string-only type name:

- Kafka: deployment/cluster identity + broker-enforced topic name + operation/consumer group where relevant; same topic name in two clusters is **not** one resource.
- HTTP: host/listener identity + route method/path (routes can be parameterized, conditional and dynamically registered; do not claim a concrete route when unresolved).
- Database: server/tenant/database/schema/table, with query and column lineage as separately inferred flow, not an unverified permission claim.
- File: rooted and normalized path plus applicable filesystem identity; symlinks, aliases, mounts and path races require host enforcement and uncertainty handling.
- Generic stream: sealed primitive connection/descriptor identity; protocol and message type remain UNKNOWN until a valid high-level binding is established.

Two independently created descriptors with the same textual value are not automatically proven to refer to the same external object. Canonicalization and identity equality are checkable only to the level supported by the binding, deployment configuration and trusted runtime information. A dynamic expression yields a symbolic identity or UNKNOWN, not a fabricated constant.

**Direction integrity:** the compiler fixes physical direction at the primitive *event*: `Stream.Read` = bytes enter this process; `Stream.Write` = bytes leave it. Connection establish/bind/accept events do not on their own prove application-payload direction. Packages cannot redefine these directions. A Kafka consumer may both read and write transport bytes (poll, acknowledgments); **logical** `KafkaConsume` and `KafkaPublish` apply only to protocol payload transfer validated by a semantic binding. Unverified adapter metadata remains DECLARED/UNKNOWN and may not suppress transport writes.

A binding declares explicit linkages:

```text
illustrative schema (NOT currently supported Orin syntax)
resource KafkaTopic { cluster: ClusterId; name: string }

binding KafkaConsumer<T>.receive {
  descriptor = topic: KafkaTopic
  requires = { Net.Connect(broker), Stream.Read(socket), Stream.Write(socket) }
  source = Stream.Read(socket) -> FrameDecoder -> KafkaPayload<T> -> callback.argument[0]
  semantic_direction = input    // accepted only if checkable; does not override primitive I/O
  enforcement = trusted_adapter + broker_topic_acl  // must be backed by policy/evidence
}

binding KafkaProducer<T>.send {
  descriptor = topic: KafkaTopic
  sink = call.argument[0] -> FrameEncoder -> Stream.Write(socket)
  semantic_direction = output
}
```

The **compiler**, not the library declaration, owns and propagates primitive event IDs, MIR value IDs, source spans, actual handle identity and read/write direction. An adapter can provide a semantic *mapping*, and the checker must either validate the mapping, record explicit assumptions/trust, or reject it under strict policy. It cannot relabel writes as reads, omit network egress, claim authority from a descriptor, or claim an unproven topic identity as VERIFIED.

**Cross-service stitching:** a producer output and consumer input may be linked through a resource descriptor only when the normalized, sufficiently evidenced identities refer to the same broker/topic (and schema/compatibility assumptions support the typed linkage). Kafka transport uses separate service executions; OSIG shows an **asynchronous message edge**, not a direct synchronous function call or proof of delivery. Partitions, filters, consumer groups, retries, duplicates and environment-specific routing may make a potential link MAY/UNKNOWN. Two instances of the same derived *capability type* or root kind alone do not make a cross-service lineage edge.

**Resource-oriented API error rules:** missing or forged authorization, resource-handle escape/copy, unauthorized narrow/widen operation, unsupported primitive use and incorrect sealed-handle association are compilation errors; invalid runtime resource grants/identity are denied by L0. A library's claimed HTTP/Kafka-specific identity with an unverified binding is **not automatically** an error in permissive compilation (the raw I/O remains visible), but is a strict-policy compilation failure when verified protocol identities are required.

#### End-to-end exemplar (acceptance fixture, not current syntax)

```text
Service A:
  granted handle: NetworkConnect(brokerA)
  bound resource: KafkaTopic(clusterA, "orders.created")
  OrderPublisher.send(encode(OrderCreated{orderId, total}))
  => primitive Stream.Write + CHECKED KafkaPublish(clusterA/orders.created)

Service B:
  granted handle: NetworkConnect(brokerA)
  bound resource: KafkaTopic(clusterA, "orders.created")
  CHECKED KafkaConsume -> decode(OrderCreated)
  OrderService.validate -> OrderService.price -> Repository.save
  => DbTable(dbA/orders) write

OSIG:
  ServiceA.OrderCreated.total -> topic(clusterA/orders.created)
       -- asynchronous potential delivery -->
  ServiceB.OrderCreated.total -> OrderRow.total -> dbA/orders.total
```

The process explorer must make these separate physical operations, semantic messages, process steps and field dependencies inspectable, with distinct colors/labels for checked, possible, and unknown edges. Example fixture must include **negative cases**: same topic name in different clusters, false library-provided direction, raw socket bypass disguised as Kafka, dynamic topic, different payload schemas, and revoked/insufficient broker ACL.

#### Feasibility: exact socket events versus application-level meaning

This design is implementable **without protocol recognition** for primitive I/O: the only permitted socket read/write paths in a strict Orin build are L0 `Net.Accept`, `Net.Connect`, `Stream.Read(handle, buffer)` and `Stream.Write(handle, bytes)` intrinsics. These have **compiler-owned stable operation IDs**, an immutable INPUT/OUTPUT direction and attached sealed handle identity. The event's direction is defined by the primitive, not an arbitrary function or type named `read`/`write`. Every call must be effect-checked through indirect calls, generics and dynamically dispatched calls; UNKNOWN prevents certification under a fail-closed policy. The runtime separately checks handle scopes/identity and emits an observed I/O event when instrumentation is enabled.

For an illustrative socket exchange:

```text
connection = listener.accept()   -> CONTROL: accept connection, not application payload
requestBytes = connection.read() -> INPUT: actual bytes read (possibly 0/partial/EOF)
response = service(requestBytes) -> TRANSFORM: compiler-inferred value lineage
connection.write(response)       -> OUTPUT: actual submitted bytes (possibly partial/error)
```

A socket is **bidirectional**; a whole `Socket` or `KafkaConsumer` object must not receive a single immutable "direction" tag. Direction attaches to each primitive operation and, separately, to checked semantic payload events. Buffering, TCP framing, TLS, retries, short writes, error branches and concurrent use must remain explicit or summarized with sound uncertainty. OSIG static analysis establishes *may/possible* flows; successful actual sends/receives require runtime evidence. A `Stream.Write` call is not a proof that the remote peer received the bytes.

For a plain custom HTTP server over TCP, the compiler can guarantee it saw (authorized) socket `read` and `write` effects and can track value dependencies through the handler. It **cannot automatically classify** arbitrary read bytes as an HTTP request, assign a specific route or establish application-message direction without a validated HTTP parser/dispatch adapter (or explicit unverified assumptions). This is a hard acceptance boundary, not a feature to handwave.

**Native threat model:** C or LLVM output can otherwise call OS APIs directly. Compiler analysis alone cannot prevent a modified compiler or hostile native dependency from emitting raw syscalls. A *strict build check* rejects visible forbidden FFI/unsafe constructs; **actual prevention** against an adversarial native binary additionally requires OS-level isolation, privilege restrictions and controlled egress, or an execution target with enforced imported I/O functions (such as an appropriately configured WASI host). Do not describe static detection as unconditional OS-level enforcement.

**Feasibility milestones / tests** (concrete implementation order):
1. A minimal in-process TCP echo server: `accept → read → transform → write` emits 1 input and 1 output primitive event with IDs, spans, handle identity, partial-I/O/error semantics.
2. A wrapper `function receive(conn) { conn.read(...) }` propagates the primitive input effect transitively; a wrapper lying about its direction cannot alter the event.
3. A copied/forged handle, widened remote/port scope or socket call without an authorized handle fails compilation/runtime validation.
4. A raw TCP library is represented as **unknown protocol** while retaining all primitive input/output edges; no declaration can certify it as HTTP or Kafka without validated mapping.
5. Two services connected through a checked protocol resource, with field-level influence, appear as joined process **candidates** only when broker/route identity is sufficiently established.
6. Run adversarial/native-bypass tests under the selected OS isolation policy before claiming hostile binaries cannot escape I/O permissions.

### D5 — Process discovery is a separate compiler analysis

A process is a **view over a rooted control/data-flow slice**, not a newly minted capability. Candidate roots: bound listener/accept, HTTP handler dispatch, Kafka receive/callback, file source, scheduled event or declared host entry point. Candidate sinks: stream/write, Kafka publish, database mutation, HTTP response, file write, process execution. A callback/async message edge may establish a new process episode or a relation between processes, not an imaginary synchronous call.

Required graph pipeline:

1. Discover primitive boundary events unconditionally through compiler-known L0 calls and scoped handles.
2. Propagate effect summaries through calls (including may/unknown dispatch).
3. Build interprocedural def-use/SSA, alias and field-level lineage on HIR/MIR with source spans; include conditional influence and success/error branches.
4. Associate protocol-level input/output payload identities through checked adapter bindings and payload decoders/encoders.
5. Slice from each input trigger to reachable sinks, then group and label meaningful services/process steps; maintain clickable references to underlying functions, statements, fields and contracts.
6. Mark every edge MUST, MAY or UNKNOWN, separately from proof/assurance and from observed runtime traces.
7. Compare base/head graphs for PR review; preserve structural and process-slice changes with explaining paths. For cross-service broker links, require a justified common topic/broker identity; dynamic routing and missing service coverage remain unknown.

A capability graph can **reliably expose mediated external boundary operations** under the trusted runtime assumptions. It **cannot by itself** reconstruct full process paths, know which field influenced which output, prove business logic correctness, resolve arbitrary callback targets, or verify Kafka/HTTP packet semantics. Those guarantees require D5 steps 2–5 and supporting contracts/proofs. Do not label a process as fully analyzed when unknown edges could affect it. OSIG 0.1 currently implements a structural graph, **not** this process/lineage pipeline.

### D6 — Grants, policies, build trust and attestations

The program host supplies actual grants; package/module boundaries in orin.toml declare maximum effects / allowed dependencies per ADR-0020. Default deny is the security posture. A strict policy may forbid raw sockets outside approved adapters, unknown data-flow exits, or new PR-introduced egress. Policies operate on inferred effects and *enforced* bindings, never package-authored labels alone.

The compiler can generate a capability/effect/lineage report and an .orcert statement binding exact source/commit, compiler release digest, build artifact digest, graph digest, declared assumptions and check results. A trusted CI identity (e.g. OIDC/Sigstore artifact attestation) authenticates **who ran which compiler/checks on which inputs**. It **does not independently prove that a modified or buggy compiler faithfully checked them**, nor guarantee that a native executable contains no injected unauthorized I/O. Consumers independently verify signatures/hashes and enforce their selected trust policy. Projects may use their own trusted CI; Orin remains open source and does not require an official central build service.

No new full proof checker is mandated by this ADR. Runtime/OS I/O isolation and provenance policy are still necessary for robust execution-time guarantees. Certification levels must follow ADR-0020's existing proof and assurance vocabulary and not be falsely upgraded by a signature.

### D7 — Staging without redesigning the compiler or breaking the freeze

- **Stage A, pre-std I/O freeze:** standard primitive handle API, nonforgeability, resource restrictions, platform grant issuance and L0 checks; update unstable std I/O signatures. Define stable resource descriptor IDs, sealed handle provenance, primitive direction events and the *schema contract* for future derived capability bindings. Work within the existing two-stage freeze decision; an ADR is needed for any new post-language-freeze syntax.
- **Stage B, alongside/after compiler rewrite:** effect inference / policy; source-mapped MIR; primitive boundary events, stable IDs, initial OSIG effects.
- **Stage C:** checked library adapters for HTTP/Kafka, interprocedural object- and field-lineage, event/callback/branch tracking, process slices and clickable implementation view.
- **Stage D:** PR process diffs, merge/history comparison, attested analysis artifacts, strict policy gates. Build reports with GitHub Actions first; browser-only WASM compilation is optional and later.

Do not build unverified protocol annotation syntax into the language until a representative library validates the abstraction. Initial bindings may be a versioned typed manifest plus compiler-recognized adapter ABI.

## Mandatory acceptance tests (before claiming process discovery)

1. A pure calculation creates lineage but **zero** new capability definitions/effects.
2. A listener can only bind an allowed port; forged root grants, widening an existing port/endpoint, or passing the wrong resource handle are rejected. A resource descriptor cannot be converted into an authorized handle.
3. A Kafka library that calls Stream.Write to an unauthorized endpoint fails a strict capability check even if it claims only KafkaConsume.
4. A library that declares KafkaConsume(topic A) but uses raw TCP and cannot establish topic semantics is not certified as topic A; strict verified-adapter policy rejects it.
5. A Kafka receive of OrderCreated leads via two services and a field transform to KafkaPublish(OrderProcessed): OSIG discovers input, output, and meaningful explanatory path with source links.
6. A message field transformed as price × quantity has field-level provenance; a field used only in a branch condition appears as control dependence.
7. An indirect callback or runtime-selected topic produces MAY/UNKNOWN, not a false MUST or asserted concrete topic.
8. An unauthorized FFI/native syscall path does not pass strict policy; document the separate native runtime sandbox requirement.
9. PR adding a new egress changes effect/impact report and fails an explicit deny-egress policy; changing only implementation without observable effects does not invent an external flow change.
10. Self-hosted CI can attest a report and external CI can do so too; signature verification authenticates provenance, not independent correctness.
11. A library that falsely labels Stream.Write as input still produces a compiler-owned output event; its claimed semantic binding is rejected under strict policy.
12. Two Kafka topics with identical names in different clusters must never be joined as the same resource; producer-to-consumer links are asynchronous and uncertainty-qualified.
13. A scoped Kafka/HTTP handle cannot escape through a captured closure or class field; existing ADR-0025 resource rules remain enforced.
14. An unverified HTTP route or dynamically chosen topic remains symbolic/UNKNOWN, not a fabricated concrete resource identity. A verified adapter can connect a listener/route or broker/topic to a typed callback and distinguish payload direction from protocol control traffic.

## Addendum A (2026-10-13): Stage A decisions, vocabulary crosswalk, handles and tasks

### A1. What Stage A accepted and implemented

[ADR-0027](0027-stage-a-root-capabilities.md) records the concrete design and is the reference for the API, the error
codes (E0470-E0472), the platform and runtime parts and the limitations. In short: grants enter at `main(host: Host)`;
`Host` and every grant are **resource handles with the ADR-0025 rules** (no new ownership mechanism; the type checker and
the MIR verifier enforce them independently); derived grants are obtained through scope functions and only ever narrow
(`useUnder`, `useReadOnly`, `useArgsOnly`); every std I/O function takes its grant first; the runtime validates handle,
family, host policy (`ORIN_DENY`) and path scope on every operation; `main()` without `host` has no authority (compile
error E0470). Root families implemented: filesystem, process, stdio, clock. Reserved, not implemented: network
(`Net.Bind/Accept/Connect`, `Stream.Read/Write`), environment. No new syntax was needed (ADR-0016).

| Decision | Status after Stage A |
|---|---|
| D1 closed root families, platform-created non-copyable handles, runtime validation at every privileged operation | **accepted, implemented** for fs / process / stdio / clock; network **proposed** |
| D2 derived capabilities | narrowing of the root grants **accepted, implemented**; user-defined nominal derived capability types **proposed** |
| D3 library adapters and evidence for protocol semantics | **proposed** |
| D4 primitive event schema | primitive direction and operation names **accepted** as OSIG `PERFORMS_IO` edges (ADR-0027); runtime events, grant chains, value ids **proposed** |
| D4a handle identity (ADR-0025 reuse, no casts / constructors, scoped lifecycle API) | **accepted, implemented**; resource descriptors and bindings **proposed** |
| D5, D6 | **proposed** |
| D7 Stage A | **accepted, implemented** (this addendum, ADR-0027); Stages B-D **proposed** |

### A2. Crosswalk between the four vocabularies

The four label sets answer different questions and must never be merged or abbreviated into one another. Where a row
says "none" there is deliberately no mapping.

| Question | Vocabulary | Values | Owner |
|---|---|---|---|
| Is a *claim* proved? | **proof status** | `VERIFIED`, `REFUTED`, `UNKNOWN`, `ASSUMED`, `NEEDS_DECISION`, `NOT_APPLICABLE`, `STALE`, `NOT_RUN` | ADR-0020 D1 |
| How far does the *evidence* reach? | **assurance level** | `MODEL_ONLY`, `TRANSLATION_VALIDATED`, `IMPLEMENTATION_VERIFIED`, `TESTED_ONLY` | ADR-0020 D7, `docs/assurance.md` |
| Does a graph *edge* hold in every run? | **OSIG edge evidence** | `MUST`, `MAY`, `UNKNOWN` | ADR-0023 |
| Who vouches for a *boundary* (a library's protocol / resource claim)? | **boundary evidence** | `ENFORCED`, `DERIVED`, `DECLARED`, `ASSUMED`, `UNKNOWN` | this ADR, D3 |

| Boundary evidence (D3) | Meaning | Proof status it may support | Assurance level it may carry | OSIG edge evidence it may produce |
|---|---|---|---|---|
| `ENFORCED` | a trusted boundary or verifiable binding restricts the operation (platform check, broker ACL), under listed assumptions | `VERIFIED` only if a checkable obligation exists and its assumptions are listed; else `ASSUMED` | the level of the *enforcing mechanism*: the L0 grant checks are `TESTED_ONLY` (ADR-0027, assurance row C15); an external ACL is not an Orin assurance level at all | `MUST` for the primitive operation; the link to a *semantic* resource is `MAY` unless the identity is established |
| `DERIVED` | the compiler established a data dependency or primitive effect by analysis | `VERIFIED` for a sound analysis of the fragment it covers, otherwise `UNKNOWN` for the rest | `TESTED_ONLY` until the analysis is validated (ADR-0020 L1-L3) | `MUST` for a direct call; `MAY` for conditional / closure / dynamic dispatch; `UNKNOWN` for unresolved targets |
| `DECLARED` | stated by the package author, not checked | `ASSUMED` (never `VERIFIED`) | none (no evidence) | at most `MAY`; never `MUST` |
| `ASSUMED` (boundary) | an explicit trust statement of the build policy (`@Assume`-like) | `ASSUMED` | none | at most `MAY` |
| `UNKNOWN` | resolution incomplete / opaque boundary (FFI, raw syscall, dynamic topic) | `UNKNOWN` | none | `UNKNOWN`; blocks certification under a fail-closed policy |

Rules that follow: (1) a signature (`.orcert`) authenticates *who ran which check*; it never upgrades a status or an
assurance level. (2) `DECLARED` and `ASSUMED` boundary evidence appear as proof status `ASSUMED`, never `VERIFIED`,
whatever the annotation says. (3) Edge evidence `MUST` requires a direct, statically resolved primitive call; boundary
evidence `ENFORCED` is about authority, edge evidence about control flow -- an `ENFORCED` operation reached through a
function value is a `MAY`/`UNKNOWN` edge. (4) "No edge" is not "no effect" (ADR-0023 decision 4). (5) A runtime denial
(`ORIN_DENY`, scope) is observed behaviour, not a proof status.

### A3. Handles move, never share (ADR-0017)

A capability handle may be **moved** into a task (when ADR-0017's task spawn and an owned-parameter mode for handles
exist: the parent loses it, the task closes it) but never shared, copied or aliased between tasks or between a task and
its parent. The one-owner rule is what keeps `Authority(D) subseteq Union(Authority(G))` true with concurrency: two tasks
holding the same grant would be two uses of one authority with no owner to revoke it. Stage A creates no tasks, so this is a
recorded constraint on the task design, enforced today only as far as a handle cannot be copied at all.

### A4. Grant design record (Stage A)

See ADR-0027 for the complete record; the decisions are: scope functions instead of returned grants (ADR-0025 forbids
returning a resource; a lifetime extension is a separate review); one grant per root family; narrowing never widens
(a scope outside the parent's yields a grant that reaches nothing); default host policy = everything the OS process has,
`ORIN_DENY` removes families, a malformed policy is rejected as a whole; denial is `Err` where the operation returns a
`Result` and a trap otherwise; path scopes compare absolute normalised paths and resolved symbolic links and open the
checked path; `console.log` / `console.error` / `exit` stay grant-free and are recorded as ambient primitive OUTPUT /
CONTROL events in the OSIG (an honest weakening: code without grants can still write to stdout and stderr).

### A5. Acceptance tests covered by Stage A

From the list above: 1 (pure calculation: no grants, no `PERFORMS_IO` edge: `tests/next/run/cap_pure_no_grants.or` and the
OSIG test), the grant part of 2 and 3 for the primitive operations that exist (filesystem scope, wrong grant kind, forged
grant, descriptor-to-handle conversion impossible: no constructor), 11 (a library cannot relabel a primitive: the
direction belongs to the compiler's operation table), 13 (a scoped handle cannot escape through a captured closure or
class field: E0452, E0450). Not covered (Stage B and later): 3-10 and 12, 14 for network / Kafka / HTTP, effect inference through
indirect calls, strict-policy gates, cross-service stitching, field lineage, attestation.

## Open design questions requiring follow-up

- Exact Orin grammar for eventual `resource` descriptors versus versioned semantic-binding manifests; class/interface interaction; resource move/borrow semantics of narrowed handles and scoped long-running network listeners. Note: the language freeze already occurred, so new syntax requires ADR approval.
- Parameter refinements for DNS resolution, IP rebinding, paths, dynamic Kafka topic names, multiplexed shared connections, broker ACLs.
- Whether verified protocol adapters are limited to audited built-ins, can ship independently verifiable proof artifacts, or rely on explicit trust policy.
- Alias/pointer model, callback resolution, asynchronous message correlation and scalability/incremental analysis.
- Host controls and documented trust boundaries for native executables, FFI, runtime and OS sandboxes.

These should be resolved with concrete tests and ADR amendments. No broad claim of automatic complete process recognition is justified before the acceptance tests pass.
