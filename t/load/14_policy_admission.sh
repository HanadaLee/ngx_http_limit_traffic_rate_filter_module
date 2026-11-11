#!/usr/bin/env bash
# Only the selected policy counts; exhausted zones do not fall back.

source "$(dirname "$0")/helpers.sh"

tap_plan 8
trap _cleanup EXIT
check_requirements
init_test_dir "policy-admission"
make_file "$TEST_DIR/files/payload.bin" 2097152
printf 'ok' > "$TEST_DIR/files/probe.bin"
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
        limit_traffic_rate zone=first rate=1m;
        location = /hold {
            limit_traffic_rate zone=second rate=32k;
            alias $TEST_DIR/files/payload.bin;
        }
        location = /first {
            limit_traffic_rate zone=first rate=1m;
            alias $TEST_DIR/files/probe.bin;
        }
        location = /second {
            limit_traffic_rate zone=second rate=32k;
            alias $TEST_DIR/files/probe.bin;
        }
        location = /custom {
            limit_traffic_rate zone=second rate=32k;
            error_page 503 = @busy;
            alias $TEST_DIR/files/payload.bin;
        }
        location @busy {
            limit_traffic_rate zone=second rate=32k;
            return 503 "busy";
        }
        location = /proxy {
            limit_traffic_rate zone=second rate=32k;
            proxy_pass http://127.0.0.1:${TEST_PORT}/origin;
        }
        location = /off {
            limit_traffic_rate off;
            alias $TEST_DIR/files/probe.bin;
        }
        location = /origin {
            limit_traffic_rate off;
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


def request(uri, method="GET"):
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
        if uri.startswith("/hold?") and status == 200:
            held.append(s)
            body = b""
        else:
            body = data.split(b"\r\n\r\n", 1)[1]
            while True:
                chunk = s.recv(4096)
                if not chunk:
                    break
                body += chunk
            s.close()
            if len(body) != int(headers[b"content-length"]):
                raise RuntimeError("response body does not match Content-Length")
        return status, int(headers.get(b"x-rate", b"0")), body
    except BaseException:
        s.close()
        raise


def report(ok, name):
    print(("PASS" if ok else "FAIL") + "|" + name)


try:
    exhausted = False
    for i in range(128):
        status, _, _ = request("/hold?first=shared&second=" + str(i).zfill(900))
        if status == 503:
            exhausted = True
            break
        if status != 200:
            raise RuntimeError(f"unexpected HTTP {status}")

    report(bool(held), "requests join the selected zone before exhaustion")
    report(exhausted, "exhausted selected zone returns HTTP 503 without parent fallback")

    status, rate, _ = request("/first?first=shared")
    report(status == 200 and rate == 1048576,
           "selected policy never registers in the inherited zone")

    rejected_key = "rejected" * 100
    status, _, body = request("/custom?first=shared&second=" + rejected_key)
    report(status == 503 and body == b"busy",
           "custom error response bypasses failed admission without recursion")

    status, _, body = request("/proxy?first=shared&second=" + rejected_key)
    report(status == 503 and b"503" in body,
           "upstream response is replaced with a complete HTTP 503 response")

    status, rate, body = request("/off?first=shared&second=" + rejected_key)
    report(status == 200 and rate == 0 and body == b"ok",
           "off bypasses inherited and exhausted policies")

    for s in held:
        s.close()
    held.clear()

    for _ in range(100):
        status, rate, _ = request("/second?second=" + "new" * 300)
        if status == 200 and rate == 32768:
            break
        time.sleep(0.02)
    report(status == 200 and rate == 32768,
           "selected zone accepts new keys after aborts")

    status, rate, _ = request("/first?first=shared")
    report(status == 200 and rate == 1048576,
           "inherited zone remains unaffected after aborts")
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
