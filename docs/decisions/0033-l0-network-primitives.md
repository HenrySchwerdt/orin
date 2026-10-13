# ADR-0033: L0 network primitives for `std:net`

Status: proposed (2026-10-13). Amends the closed L0 list of spec 19 §2 (an ADR is required for
every new platform function). Related: ADR-0021 (primitive operations Bind / Accept / Connect /
StreamRead / StreamWrite, handle identity), ADR-0027 (Stage A: root grants as resource handles),
ADR-0030 (the trust boundary is L0 only), ADR-0025 (resources).

## Decision

### 1. New L0 functions (blocking, IPv4/IPv6 TCP first)

| Function | Operation (ADR-0021) | Handle checked |
|---|---|---|
| `orin_platform_tcp_listen(grant, addr, port, backlog, out_fd)` | Bind | a listen grant whose scope covers `addr:port` |
| `orin_platform_tcp_accept(listener, out_fd, out_peer)` | Accept | listener handle created by `tcp_listen` |
| `orin_platform_tcp_connect(grant, host_addr, port, timeout_ms, out_fd)` | Connect | a connect grant whose scope covers the remote endpoint |
| `orin_platform_stream_recv(stream, buf, cap, timeout_ms, out_len)` | StreamRead | stream handle from accept/connect |
| `orin_platform_stream_send(stream, data, len, out_sent)` | StreamWrite | same |
| `orin_platform_net_close(handle)` | — | any network handle; idempotent |
| `orin_platform_dns_resolve(grant, name, out_addrs)` | Connect (lookup) | a connect grant whose scope covers `name` |

UDP comes in a later amendment.

**Rules:**
- every function takes a handle; there is no ambient socket;
- every function validates the handle's identity and scope at run time, and refuses with
  `ORIN_PLATFORM_EPERM` before any syscall;
- every function has an ACSL contract (`requires`/`ensures`/`assigns`) in `orin_platform.h`,
  like the file functions;
- `recv` never writes past `cap`, and `send` reports partial writes; both are CBMC-checked for
  buffer bounds;
- timeouts are mandatory parameters, with no infinite default.

### 2. Grants (Orin side, `std:host` / `std:net`)

- `host.net()` gives the root network grant (ADR-0027). The root grant can only be narrowed:
  - `listenGrant(addr, port)`
  - `connectGrant(hostPattern, portRange)`
- Listener and stream handles are resources: they cannot be copied, are closed on scope exit, and
  cannot escape through closures or fields (ADR-0025).
- OSIG: every call of a network primitive is a `PERFORMS_IO` edge with direction (IN for
  recv/accept, OUT for send/connect) and the handle's identity, as in ADR-0021.

### 3. Budget and assurance

- About 250 lines of C.
- L0 stays under its 1,000-line budget. CI checks this (ADR-0032 §10).
- Assurance: the buffer and bounds properties are CBMC-verified. Socket behaviour itself is
  OS-trusted and tested. A loopback test suite runs in CI on Linux and macOS.

## Consequences

`std:net` and `std:http` (ADR-0030 §3) can be written in safe Orin on top of this. The HTTP parser
does not depend on it: it is a pure function over `std:bytes` and can be built first.
