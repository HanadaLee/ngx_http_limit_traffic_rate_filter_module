# ngx_http_limit_traffic_rate_filter_module

Shares a configured download bandwidth among concurrent requests with the same key (e.g. `$remote_addr`), including connections handled by different nginx worker processes.

nginx's built-in `limit_rate` limits each request independently. A client using a multi-threaded download tool can open *N* connections and receive *N × limit_rate* in aggregate. This module tracks all active requests for a given key in a shared-memory zone and calculates an approximate fair share:

```
per-request rate = max(1 byte/s, configured_limit / active_requests)
```

Each request refreshes its own rate on subsequent output body-filter calls. **Rates are not pushed immediately to sibling requests across workers.** In particular, the sum of actual throughput is not a strict instantaneous ceiling while membership changes. For a hard aggregate byte budget across workers, a different scheduling design is needed.

## Requirements

- nginx 1.21.5 or later (documented minimum; CI currently builds 1.26.3, 1.28.2 and 1.29.6, not the minimum)
- A C compiler supported by your nginx build (code uses C89-style declarations)

## Installation

### Static module

```bash
./configure --add-module=/path/to/this/directory
make && make install
```

### Dynamic module

```bash
./configure --add-dynamic-module=/path/to/this/directory
make && make install
```

Add to the top of `nginx.conf`, before any `events {}` or `http {}` block:

```nginx
load_module modules/ngx_http_limit_traffic_rate_filter_module.so;
```

### Conditional configuration

To use `when`, build [ngx_expr_module](https://github.com/HanadaLee/ngx_expr_module) statically before this module:

```bash
./configure \
    --add-module=/path/to/ngx_expr_module \
    --add-module=/path/to/ngx_http_limit_traffic_rate_filter_module
```

The traffic module can also use `--add-dynamic-module` in this configuration. Without expr, ordinary `limit_traffic_rate` directives and per-zone inheritance remain available.

## Configuration

### `limit_traffic_rate_zone`

Declares a named shared-memory zone. Place in the `http {}` context.

```
Syntax:  limit_traffic_rate_zone key zone=name:size;
Default: —
Context: http
```

| Parameter | Description |
|---|---|
| `name` | Zone identifier referenced by `limit_traffic_rate` |
| `key` | Grouping key containing text, nginx variables, or both |
| `size` | Shared memory size (e.g. `32m`). Minimum is 8 × page size |

Common key variables:

| Variable | Effect |
|---|---|
| `$remote_addr` | One bucket per client IP — the typical use case |
| `$binary_remote_addr` | Compact IP form, saves ~10 bytes per node |
| `$request_uri` | One bucket per URL — limit per-file across all clients |

### `limit_traffic_rate`

Applies a zone's limit within a context.

```
Syntax:  limit_traffic_rate zone=name rate=rate;
Default: —
Context: http, server, location, when
```

Rate units: `k` (kilobytes/sec), `m` (megabytes/sec), or plain bytes/sec. The rate must be greater than zero.

Both parameters are required and may appear in either order. The rate is a fixed configuration value; use `when` to select different rates.

Configuration is merged separately for each case-sensitive zone name. A directive for one zone does not remove inherited limits for other zones. When several zones apply, a request participates in each zone once and uses the lowest of their per-request rates.

With expr, the first unconditional or matching conditional value for a zone is selected in declaration order at the current level. Put conditional values before an unconditional fallback. If no local value matches, the parent values for that zone are considered. A local unconditional value replaces the inherited values for that zone. If no value matches at any level, that zone does not limit or count the request.

The same zone cannot be configured twice for the same condition at one configuration level, or twice unconditionally. Splitting an equivalent `when` block does not change this check. Different zones may share the same condition. `limit_traffic_rate_zone` declares shared memory unconditionally and cannot be used inside `when`.

## Example

```nginx
http {
    # One rate bucket per client IP, 32 MB of shared memory.
    limit_traffic_rate_zone $remote_addr zone=rate:32m;

    server {
        # Target aggregate bandwidth per IP: 500 KiB/s.
        # With 8 steady requests, each gets about 62.5 KiB/s.
        location /download/ {
            limit_traffic_rate zone=rate rate=500k;
        }
    }
}
```

With expr, a location can override one zone conditionally while retaining another inherited zone:

```nginx
http {
    limit_traffic_rate_zone $binary_remote_addr zone=client:32m;
    limit_traffic_rate_zone $uri zone=object:32m;

    expr slow str_starts_with $uri /download/slow/;
    limit_traffic_rate zone=client rate=500k;
    limit_traffic_rate zone=object rate=2m;

    server {
        location /download/ {
            when slow {
                limit_traffic_rate zone=client rate=100k;
            }
        }
    }
}
```

Requests matching `slow` use `zone=client rate=100k`; other requests inherit `zone=client rate=500k`. Both also participate in `zone=object rate=2m`.

> The previous positional forms, `limit_traffic_rate_zone name $variable size` and `limit_traffic_rate name rate`, must be converted to the syntax above.

## Behaviour

**Rate sharing.** A shared counter tracks registered main responses for each key. Responses join while their headers are filtered and remain registered until request cleanup. Requests waiting for upstream headers do not consume a share. Existing responses learn of additions/removals when their output body filter runs again. The module sets `r->limit_rate_set` so the nginx write filter respects its chosen rate. The module's `limit_traffic_rate` takes precedence over the native nginx `limit_rate` for registered responses; the core `limit_rate_after` still applies.

**Approximation, not a strict aggregate cap.** Refresh timing depends on nginx output scheduling and buffering; it is not synchronous across workers. The integer division is floored at 1 byte/s because zero disables nginx rate limiting. When the number of active requests exceeds the configured limit in bytes/s, the combined floor may exceed that limit. The core rate limiter can also permit initial bursts. This release does not implement cross-worker token-bucket accounting or provide a hard aggregate throughput guarantee.

**Admission and overload.** The shared counter is a `u_short`: once a key has 65,535 active registered requests, additional requests for that key receive HTTP 503 instead of wrapping the counter. An exhausted shared-memory slab also produces HTTP 503. No durable worker-crash recovery is implemented: if a worker is killed without request cleanup, a stale count can persist until the shared zone is recreated. Normal request completion and client aborts perform cleanup via the request pool.

**HTTP/2 and HTTP/3.** Each client stream has its own main response and registration. Cancelling one stream releases its registrations when nginx closes the request. With HTTP/3, a pending native rate-limit write timer can delay request cleanup after the QUIC reset notification; the notification alone does not mean the shared counter has already been released.

**Request lifecycle.** Conditions and zone keys are evaluated in the response header filter, using the effective location and variables available at that point, including access-stage results and upstream response headers. Internal redirects before the response do not register intermediate locations. If a later filter replaces the response with an error, the previous registrations are released before the replacement is evaluated. If admission to any zone fails, all zones already registered during that evaluation are released and an error response is generated before forwarding headers. The replacement response skips admission to prevent recursive failures. Body-filter calls refresh the selected rates from the current shared counters without reevaluating conditions.

**Passthrough.** Subrequests, HEAD requests, informational responses, 204 and 304 responses, and responses already known to have no body do not register with shared zones. Slice and SSI subrequests are covered by their main response's registration. A zone is skipped when no value matches, its evaluated key is empty, or its key value exceeds 1024 bytes. Other applicable zones remain effective. When no zone applies, the native nginx `limit_rate` behaviour is preserved. Responses generated by rewrite `return` and responses with error bodies can now be limited even when they bypass PREACCESS.

## Validation

The fork runs the nginx integration and load tests against nginx-ext 1.31.8 in static and dynamic module builds, both with and without expr. The integration tests cover per-zone inheritance, conditional fallbacks, declaration order, equivalent `when` blocks and includes, concurrent counters, internal redirects, SSI and slice subrequests, HTTP/2 and HTTP/3 streams, and cleanup. HTTP/3 tests use the nginx-tests QUIC client and require CryptX and the OpenSSL command-line tool.

The load tests under `t/load/` run with either a statically compiled module or a dynamically loaded `.so`. CI configures nginx versions `1.26.3`, `1.28.2` and `1.29.6` in both modes. The test suite includes multi-worker throughput, nginx `limit_rate` precedence, invalid configuration, request cleanup, graceful reload, concurrent shared-zone exhaustion and a 5,000-request repeated-allocation test.

```bash
# After building nginx with the module, using your actual binary:
TEST_NGINX_BINARY=/path/to/nginx/sbin/nginx bash t/load/run_all.sh

# Run only the multi-worker bandwidth and write-filter regressions:
TEST_NGINX_BINARY=/path/to/nginx/sbin/nginx \
    bash t/load/run_all.sh 11 12
```

The tests cover selected workloads; they do not establish strict aggregate bandwidth guarantees, failure recovery after `SIGKILL`, or compatibility with every nginx build and output-filter combination.

## License

See [LICENSE](LICENSE).
