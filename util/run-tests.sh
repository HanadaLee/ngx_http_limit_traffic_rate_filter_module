#!/usr/bin/env bash

set -euo pipefail

module_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
nginx_source="$module_root/.ci/nginx"
test_output="$module_root/.ci/test-output"
build_jobs="${TEST_BUILD_JOBS:-$(getconf _NPROCESSORS_ONLN)}"
module_mode="${TEST_MODULE_MODE:-static}"
expr_mode="${TEST_EXPR:-enabled}"
mkdir -p "$test_output"
exec > >(tee "$test_output/run.log") 2>&1

configure_args=(
    --prefix="$nginx_source/test-prefix"
    --with-debug
    --with-http_ssl_module
    --with-http_v2_module
    --with-http_realip_module
    --with-http_sub_module
    --with-http_json_module
    --with-stream
    --with-stream_ssl_module
    --with-stream_realip_module
)

case "$expr_mode" in
    enabled)
        configure_args+=(--add-module="$module_root/.ci/ngx_expr_module")
        ;;
    disabled) ;;
    *) echo "Unsupported expr mode: $expr_mode" >&2; exit 1 ;;
esac

case "$module_mode" in
    static) configure_args+=(--add-module="$module_root") ;;
    dynamic) configure_args+=(--add-dynamic-module="$module_root") ;;
    *) echo "Unsupported module mode: $module_mode" >&2; exit 1 ;;
esac

cd "$nginx_source"
sh ./configure "${configure_args[@]}"
make -j"$build_jobs"
mkdir -p "$nginx_source/test-prefix/logs"

export TEST_NGINX_BINARY="$nginx_source/objs/nginx"
export PERL5LIB="$module_root/.ci/nginx-tests/lib"
export TMPDIR="$(mktemp -d /tmp/nginx-module-test.XXXXXX)"
export TEST_NGINX_LEAVE=1
export TEST_NGINX_SERVROOT="$TMPDIR/servroot"
collect_logs() {
    find "$TMPDIR" -type f -name '*.log' -exec cp --parents {} "$test_output/" \;
}
trap collect_logs EXIT
if [[ "$(id -u)" == 0 ]]; then
    export TEST_NGINX_GLOBALS="${TEST_NGINX_GLOBALS:-user root;}"
fi
if [[ "$module_mode" == dynamic ]]; then
    export TEST_NGINX_GLOBALS="${TEST_NGINX_GLOBALS:-} load_module $nginx_source/objs/ngx_http_limit_traffic_rate_filter_module.so;"
fi
"$TEST_NGINX_BINARY" -V

cd "$module_root"
shopt -s nullglob
tests=()
for test_file in t/*.t; do
    tests+=("$test_file")
done
if (( ${#tests[@]} == 0 )); then
    echo "No tests selected" >&2
    exit 1
fi
prove -v "${tests[@]}"

export TEST_NGINX_MODULE_MODE="$module_mode"
export TEST_NGINX_MODULES_PATH="$nginx_source/objs"
bash t/load/run_all.sh
