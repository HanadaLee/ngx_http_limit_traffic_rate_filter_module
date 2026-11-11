# ngx_http_limit_traffic_rate_filter_module

Shares a configured download bandwidth among concurrent requests with the same key (e.g. `$remote_addr`), including connections handled by different nginx worker processes.

Unlike nginx's per-request `limit_rate`, this module divides the configured rate among active responses sharing a zone and key:

```
per-request rate = max(1 byte/s, configured_limit / active_requests)
```

## Requirements

- nginx 1.21.5 or later (documented minimum; CI currently builds 1.26.3, 1.28.2 and 1.29.6, not the minimum)
- A C compiler supported by your nginx build

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

This module can also use `--add-dynamic-module` with expr built statically.

## Configuration

### `limit_traffic_rate_zone`

Defines a shared-memory zone and its grouping key.

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
| `$binary_remote_addr` | Binary client IP address |
| `$request_uri` | One bucket per URL — limit per-file across all clients |

### `limit_traffic_rate`

Selects the zone and rate used for the response.

```
Syntax:  limit_traffic_rate zone=name rate=rate;
         limit_traffic_rate off;
Default: limit_traffic_rate off;
Context: http, server, location, when
```

Rate units: `k` (kilobytes/sec), `m` (megabytes/sec), or plain bytes/sec. The rate must be greater than zero.

The zone and rate are selected together. The rate is a fixed configuration value.

The first matching directive at the current level takes effect. Unconditional directives always match, so place conditional directives before the fallback. If none matches, the parent configuration is used.

`off` disables this module; native nginx `limit_rate` remains in effect.

Policies using the same zone and key share a counter, even if their rates differ.

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

A conditional override:

```nginx
http {
    limit_traffic_rate_zone $binary_remote_addr zone=normal:32m;
    limit_traffic_rate_zone $binary_remote_addr zone=slow:32m;

    expr is_slow str_starts_with $uri /download/slow/;
    limit_traffic_rate zone=normal rate=500k;

    server {
        location /download/ {
            when is_slow {
                limit_traffic_rate zone=slow rate=100k;
            }
        }

        location /unlimited/ {
            limit_traffic_rate off;
        }
    }
}
```

Slow downloads use the `slow` zone; other downloads inherit `normal`.

## Behaviour

Only main responses participate; responses known to have no body are skipped. HTTP/2 and HTTP/3 streams are counted individually; SSI and slice subrequests share their main response's registration.

The policy and key are selected when response headers are filtered, using the effective location configuration. Internal redirects and replacement responses use the corresponding response configuration. Registrations are released during request cleanup, including after client cancellation.

Each body-filter call refreshes the response's share from the current counter. Updates are not immediate across requests or workers, and nginx can allow initial bursts, so the aggregate rate is approximate. The minimum share is 1 byte/s.

For registered responses, `limit_traffic_rate` takes precedence over native `limit_rate`; `limit_rate_after` still applies.

An empty key or a key exceeding 1024 bytes skips this module. If the selected zone is exhausted or a key already has 65,535 registered responses, admission returns HTTP 503. The module does not try another policy after selection; an admission error response skips registration.

If a worker exits without request cleanup, stale counters can remain until the shared zone is recreated.

## Validation

CI tests nginx-ext 1.31.8 in static and dynamic builds, with and without expr. Load tests also run against nginx 1.26.3, 1.28.2 and 1.29.6. HTTP/3 tests require CryptX and the OpenSSL command-line tool.

```bash
# After building nginx with the module, using your actual binary:
TEST_NGINX_BINARY=/path/to/nginx/sbin/nginx bash t/load/run_all.sh

# Run only the multi-worker bandwidth and write-filter regressions:
TEST_NGINX_BINARY=/path/to/nginx/sbin/nginx \
    bash t/load/run_all.sh 11 12
```

## License

See [LICENSE](LICENSE).
