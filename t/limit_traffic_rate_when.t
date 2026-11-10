#!/usr/bin/perl

# Conditional rates use independent ordered value lists for each zone.

use warnings;
use strict;

use Test::More;

BEGIN { use FindBin; chdir($FindBin::Bin); }

use Test::Nginx;

my @cases;
for my $host (qw/combined split included/) {
    for my $a (0, 1) {
        for my $b (0, 1) {
            for my $p (0, 1) {
                for my $keys (qw/client=x object=x client=x&object=x/) {
                    my $client = $a ? 32 : $b ? 16 : $p ? 64 : 0;
                    my $object = $a ? 24 : $p ? 48 : 0;
                    $client = 0 unless $keys =~ /client=/;
                    $object = 0 unless $keys =~ /object=/;
                    my $rate = $client && $object
                        ? ($client < $object ? $client : $object)
                        : $client || $object;
                    push @cases, [$host, "/data?a=$a&b=$b&p=$p&$keys",
                        $rate * 1024];
                }
            }
        }
    }
}

push @cases,
    ['inherit', '/data?client=x&p=1', 65536],
    ['inherit', '/data?object=x&p=1', 49152],
    ['inherit', '/data?client=x&object=x&p=0', 0],
    ['combined', '/child?client=x&a=1&b=1&l=1&p=1', 4096],
    ['combined', '/child?client=x&a=0&b=1&l=1&p=1', 8192],
    ['combined', '/child?client=x&a=1&b=0&l=0&p=1', 32768],
    ['combined', '/child?client=x&a=0&b=1&l=0&p=1', 16384],
    ['combined', '/child?client=x&a=0&b=0&l=0&p=1', 65536],
    ['combined', '/child?client=x&a=0&b=0&l=0&p=0', 0],
    ['combined', '/child?object=x&b=1&p=1', 12288],
    ['combined', '/child?object=x&a=1&b=0&p=1', 24576],
    ['combined', '/child?object=x&a=0&b=0&p=1', 49152],
    ['combined', '/child?client=x&object=x&l=1&b=1&p=1', 8192],
    ['combined', '/override?client=x&a=1&b=1&p=1', 40960],
    ['combined', '/override?object=x&a=1&b=1&p=1', 24576],
    ['combined', '/data?client=x&a=1&b=1&p=1', 32768],
    ['order', '/data?client=x&a=1', 40960],
    ['redirect', '/jump?client=x', 8192],
    ['redirect', '/data?client=x', 32768],
    ['miss', '/data?client=x&a=0', 0],
    ['miss', '/data?client=x&a=1', 10240],
    ['miss', '/data?client=x&a=0', 0];

my $t = Test::Nginx->new()->has(qw/http rewrite ngx_expr_module
    ngx_http_limit_traffic_rate_filter_module/)->plan(scalar @cases + 1);

$t->write_file('client.inc', 'limit_traffic_rate zone=client rate=32k;');
$t->write_file_expand('nginx.conf', <<'EOF');
%%TEST_GLOBALS%%
daemon off;
events {}
http {
    %%TEST_GLOBALS_HTTP%%

    limit_traffic_rate_zone $arg_client zone=client:1m;
    limit_traffic_rate_zone $arg_object zone=object:1m;
    limit_traffic_rate_zone $arg_client zone=optional:1m;

    expr a str_eq $arg_a 1;
    expr b str_eq $arg_b 1;
    expr p str_eq $arg_p 1;
    expr l str_eq $arg_l 1;

    when p {
        limit_traffic_rate zone=client rate=64k;
        limit_traffic_rate zone=object rate=48k;
    }

    add_header X-Rate $limit_rate always;
    log_format rate '$arg_a $limit_rate';

    server {
        listen 127.0.0.1:8080;
        server_name combined;
        when a {
            limit_traffic_rate zone=client rate=32k;
            limit_traffic_rate zone=object rate=24k;
        }
        when b { limit_traffic_rate zone=client rate=16k; }

        location / { }
        location = /child {
            when a b { limit_traffic_rate zone=client rate=4k; }
            when l { limit_traffic_rate zone=client rate=8k; }
            when b { limit_traffic_rate zone=object rate=12k; }
            alias %%TESTDIR%%/data;
        }
        location = /override {
            limit_traffic_rate zone=client rate=40k;
            alias %%TESTDIR%%/data;
        }
    }
    server {
        listen 127.0.0.1:8080;
        server_name split;
        when a { limit_traffic_rate zone=client rate=32k; }
        when b { limit_traffic_rate zone=client rate=16k; }
        when a { limit_traffic_rate zone=object rate=24k; }
        location / { }
    }
    server {
        listen 127.0.0.1:8080;
        server_name included;
        when a { include client.inc; }
        when b { limit_traffic_rate zone=client rate=16k; }
        when a { limit_traffic_rate zone=object rate=24k; }
        location / { }
    }
    server {
        listen 127.0.0.1:8080;
        server_name inherit;
        location / { }
    }
    server {
        listen 127.0.0.1:8080;
        server_name order;
        limit_traffic_rate zone=client rate=40k;
        when a { limit_traffic_rate zone=client rate=8k; }
        location / { }
    }
    server {
        listen 127.0.0.1:8080;
        server_name redirect;
        expr moved str_eq $uri /target;
        when moved { limit_traffic_rate zone=client rate=8k; }
        limit_traffic_rate zone=client rate=32k;
        location / { }
        location = /jump { try_files /missing /target?$args; }
    }
    server {
        listen 127.0.0.1:8080;
        server_name miss;
        access_log %%TESTDIR%%/rate.log rate;
        when a { limit_traffic_rate zone=optional rate=10k; }
        limit_rate 20k;
        location / { }
    }
}
EOF

$t->write_file('data', 'ok');
$t->write_file('target', 'ok');
$t->run();

for my $case (@cases) {
    my ($host, $uri, $rate) = @$case;
    my $response = http("GET $uri HTTP/1.0\r\nHost: $host\r\n\r\n");
    like($response,
        qr/\AHTTP\/1\.[01] 200 .*?\r\nX-Rate: $rate(?=\r\n).*?\r\n\r\nok\z/s,
        "$host $uri");
}

$t->stop();
is_deeply([split /\n/, $t->read_file('rate.log')],
    ['0 20480', '1 10240', '0 20480'],
    'unmatched conditions leave the native write-filter rate in effect');
