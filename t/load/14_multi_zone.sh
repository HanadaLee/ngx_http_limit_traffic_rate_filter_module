#!/usr/bin/env bash
# A later-zone admission failure must release earlier-zone registrations.

source "$(dirname "$0")/helpers.sh"

tap_plan 5
trap _cleanup EXIT
check_requirements
init_test_dir "multi-zone"
make_file "$TEST_DIR/files/payload.bin" 2097152
MIN_ZONE_BYTES=$(python3 -c 'import resource; print(8 * resource.getpagesize())')
preamble="$(get_load_module_preamble)"

cat > "$NGINX_CONF" <<NGINXCONF
${preamble}
worker_processes 1;
pid $TEST_DIR/nginx.pid;
error_log $TEST_DIR/logs/error.log notice;
events { worker_connections 512; }
http {
    limit_traffic_rate_zone \$arg_first zone=first:1m;
    limit_traffic_rate_zone \$arg_second zone=second:${MIN_ZONE_BYTES};
    server {
        listen ${TEST_PORT};
        add_header X-Rate \$limit_rate always;
        location = /hold {
            limit_traffic_rate zone=first rate=1m;
            limit_traffic_rate zone=second rate=32k;
            alias $TEST_DIR/files/payload.bin;
        }
        location = /first {
            limit_traffic_rate zone=first rate=1m;
            alias $TEST_DIR/files/payload.bin;
        }
        location = /second {
            limit_traffic_rate zone=second rate=32k;
            alias $TEST_DIR/files/payload.bin;
        }
    }
}
NGINXCONF
start_nginx

python3 - "$TEST_PORT" > "$TEST_DIR/results" <<'PY'
import socket
import sys
import time

port = int(sys.argv[1])
held = []


def request(uri, method="HEAD"):
    s = socket.create_connection(("127.0.0.1", port), timeout=5)
    try:
        s.sendall(f"{method} {uri} HTTP/1.0\r\nHost: localhost\r\n\r\n".encode())
        data = b""
        while b"\r\n\r\n" not in data:
            chunk = s.recv(4096)
            if not chunk:
                raise RuntimeError("connection closed before response headers")
            data += chunk
        lines = data.split(b"\r\n\r\n", 1)[0].split(b"\r\n")
        status = int(lines[0].split()[1])
        headers = dict(line.lower().split(b": ", 1) for line in lines[1:])
        if method == "GET" and status == 200:
            held.append(s)
        else:
            s.close()
        return status, int(headers.get(b"x-rate", b"0"))
    except BaseException:
        s.close()
        raise


def report(ok, name):
    print(("PASS" if ok else "FAIL") + "|" + name)


try:
    exhausted = False
    for i in range(128):
        status, _ = request("/hold?first=shared&second=" + str(i).zfill(900), "GET")
        if status == 503:
            exhausted = True
            break
        if status != 200:
            raise RuntimeError(f"unexpected HTTP {status}")

    report(bool(held), "requests join both zones before exhaustion")
    report(exhausted, "later shared zone rejects new keys with HTTP 503")

    status, rate = request("/first?first=shared")
    report(status == 200 and rate == 1048576 // (len(held) + 1),
           "failed admission does not retain an earlier-zone counter")

    for s in held:
        s.close()
    held.clear()

    for _ in range(100):
        status, rate = request("/first?first=shared")
        if status == 200 and rate == 1048576:
            break
        time.sleep(0.02)
    report(status == 200 and rate == 1048576,
           "aborted requests release all earlier-zone counters")

    status, rate = request("/second?second=" + "new" * 300)
    report(status == 200 and rate == 32768,
           "aborted requests release exhausted-zone allocations")
finally:
    for s in held:
        s.close()
PY

while IFS='|' read -r result name; do
    if [[ "$result" == PASS ]]; then
        tap_ok "$name"
    else
        tap_fail "$name"
    fi
done < "$TEST_DIR/results"
