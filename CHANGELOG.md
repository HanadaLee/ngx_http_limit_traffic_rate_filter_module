# Changelog

## 2.1.0

### Changed

- Move response registration from PREACCESS to the response header filter. Waiting for upstream headers no longer consumes a share, and policy selection can use access-stage results and upstream response headers.
- Apply traffic limits to response bodies produced by rewrite `return` and nginx error handling, including responses that do not reach PREACCESS.
- Register only main responses with a body, and preserve registration cleanup across internal redirects, replacement responses, and client cancellation.
- Select one complete zone-and-rate policy per main response, with declaration-order matching and parent fallback when no local condition matches.

### Added

- Support `when` conditions through the optional expr module.
- Support `limit_traffic_rate off;` to disable this module and stop parent fallback while preserving native nginx rate limits.
- Add HTTP/2 and HTTP/3 coverage for policy selection, shared counters, cancellation, and response delivery.

### Breaking changes

- Replace `limit_traffic_rate_zone name $variable size;` with `limit_traffic_rate_zone key zone=name:size;`, and replace `limit_traffic_rate name rate;` with `limit_traffic_rate zone=name rate=rate;`.
- Replace per-zone merging and simultaneous limits with one selected policy. A local unconditional policy replaces the entire inherited policy, even when its zone differs. Multiple unconditional policies or multiple policies for the same condition at one level are rejected regardless of zone name.

## 2.0.2

- Merge the upstream 2.0.0 and 2.0.1 fixes while retaining their original authors.
- Keep request state in the request pool instead of shared memory, eliminating cross-worker request-pointer access.
- Preserve the assigned rate in the nginx write filter, clamp shares to at least 1 byte/s, and reject shared-counter overflow.
- Correct configuration-allocation failure handling and retain key validation.
- Add multi-worker, shared-memory exhaustion, cleanup and native rate-precedence regressions, with static and dynamic nginx-ext CI builds.

## 2.0.1

This fork's former `1.0.0` tag is renamed to `2.0.1` at commit `e0a0046`, without changing its source. This is distinct from upstream's `2.0.1` release.

- Correct the module source path and rate-calculation overflow and signedness issues.
- Fix traffic-rate enforcement and add nginx integration tests.
- Add GitHub Actions regression testing.

## 2.0.0

- Remove request queues and request pointers from shared memory to prevent cross-worker crashes.
- Use request-local rate limits and request-pool cleanup; remove sibling-pointer updates and log-phase cleanup.
- Correct red-black-tree traversal, allocation cleanup, counter-underflow handling and configuration error reporting.
- Add ten load-test suites and static/dynamic build coverage across three nginx versions.

## 2.0.0-pre

- Rework throttling around `r->limit_rate` instead of modifying the shared location configuration or scheduling module-owned write timers.
- Refresh sibling rates when requests join or leave a key.
- Correct request-queue traversal, cleanup and allocation-failure handling; guard counter underflow and division by zero.
- Restore C89 declaration layout, correct configuration error reporting, and add the load-test harness and CI matrix.

## 1.0.2-pre

- Initialize and inherit the shared-memory zone alongside the configured rate.
- Remove the zone-presence check that rejected repeated configuration.

## 1.0.1-pre

- Support dynamic modules with nginx 1.9.11 and later.
- Correct the request-record allocation check when joining an existing key.
- Normalize source formatting and convert the README to Markdown.

## 1.0

- Replace `r->limit_rate` adjustments with module-managed write-event timers based on sent bytes and elapsed time.
- Adjust `sendfile_max_chunk` according to the number of requests sharing the key.
- Correct the allocation-failure check for request records and remove redundant request-queue cleanup.

## v0.2

- modify algorithm, rate = (limit - last_rate)/conn + last_rate

## v0.1

- first release
