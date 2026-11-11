#!/usr/bin/perl

# Select one complete policy, with ordered conditions and parent fallback.

use warnings;
use strict;

use IO::Select;
use Test::More;
use Time::HiRes qw/sleep/;

BEGIN { use FindBin; chdir($FindBin::Bin); }

use Test::Nginx;

my @cases;
for my $host (qw/combined included/) {
    for my $a (0, 1) {
        for my $b (0, 1) {
            for my $p (0, 1) {
                for my $keys (qw/client=x object=x client=x&object=x/) {
                    my ($key, $rate) = $a ? ('object', 32)
                        : $b ? ('client', 16) : ('client', $p ? 64 : 0);
                    $rate = 0 unless $keys =~ /$key=/;
                    push @cases, [$host, "/data?a=$a&b=$b&p=$p&$keys",
                        $rate * 1024];
                }
            }
        }
    }
}

push @cases,
    ['inherit', '/data?client=x&p=1', 65536],
    ['inherit', '/data?object=x&p=1', 0],
    ['inherit', '/data?client=x&p=0', 0],
    ['combined', '/child?client=x&object=x&a=1&b=1&p=1', 4096],
    ['combined', '/child?client=x&object=x&a=0&b=1&l=1&p=1', 8192],
    ['combined', '/child?client=x&object=x&a=1&b=0&p=1', 32768],
    ['combined', '/child?client=x&object=x&a=0&b=1&p=1', 12288],
    ['combined', '/child?client=x&object=x&a=0&b=0&p=1', 65536],
    ['combined', '/child?client=x&object=x&a=0&b=0&p=0', 0],
    ['combined', '/child?object=x&a=1&b=1&p=1', 0],
    ['combined', '/override?client=x&object=x&a=1&b=1&p=1', 40960],
    ['combined', '/override?object=x&a=1&b=1&p=1', 0],
    ['combined', '/off?client=x&object=x&a=1&p=1', 0],
    ['combined', '/off/child?client=x&object=x&a=1&p=1', 0],
    ['combined', '/off/on?client=x&object=x&a=1&p=1', 6144],
    ['disabled', '/data?client=x&p=1', 0],
    ['disabled', '/on?client=x&p=1', 6144],
    ['order', '/data?client=x&object=x&a=1', 40960],
    ['conditional_off', '/data?client=x&object=x&a=1&p=1', 0],
    ['conditional_off', '/data?client=x&object=x&a=0&p=1', 65536],
    ['fallback', '/data?client=x&object=x&a=1&p=1', 10240],
    ['fallback', '/data?client=x&object=x&a=0&p=1', 20480],
    ['redirect', '/jump?client=x&object=x', 8192],
    ['redirect', '/data?client=x&object=x', 32768],
    ['miss', '/data?client=x&a=0', 0],
    ['miss', '/data?client=x&a=1', 10240],
    ['miss', '/off?client=x&a=1&p=1', 0];

my $t = Test::Nginx->new()->has(qw/http rewrite ngx_expr_module
    ngx_http_limit_traffic_rate_filter_module/)->plan(scalar @cases + 6);

$t->write_file('client.inc', 'limit_traffic_rate zone=object rate=32k;');
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
    }

    add_header X-Rate $limit_rate always;
    log_format rate '$uri $arg_a $limit_rate';

    server {
        listen 127.0.0.1:8080;
        server_name combined;
        when a {
            limit_traffic_rate zone=object rate=32k;
        }
        when b { limit_traffic_rate zone=client rate=16k; }

        location / { }
        location = /child {
            when a b { limit_traffic_rate zone=client rate=4k; }
            when l { limit_traffic_rate zone=client rate=8k; }
            when b { limit_traffic_rate zone=object rate=12k; }
            alias %%TESTDIR%%/data;
        }
        location /off {
            limit_traffic_rate off;
            alias %%TESTDIR%%/data;
            location = /off/child { alias %%TESTDIR%%/data; }
            location = /off/on {
                limit_traffic_rate zone=client rate=6k;
                alias %%TESTDIR%%/data;
            }
        }
        location = /override {
            limit_traffic_rate zone=client rate=40k;
            alias %%TESTDIR%%/data;
        }
    }
    server {
        listen 127.0.0.1:8080;
        server_name included;
        when a { include client.inc; }
        when b { limit_traffic_rate zone=client rate=16k; }
        location / { }
    }
    server {
        listen 127.0.0.1:8080;
        server_name inherit;
        location / { }
    }
    server {
        listen 127.0.0.1:8080;
        server_name disabled;
        limit_traffic_rate off;
        location / { }
        location = /on {
            limit_traffic_rate zone=client rate=6k;
            alias %%TESTDIR%%/data;
        }
    }
    server {
        listen 127.0.0.1:8080;
        server_name conditional_off;
        when a { limit_traffic_rate off; }
        location / { }
    }
    server {
        listen 127.0.0.1:8080;
        server_name fallback;
        when a { limit_traffic_rate zone=object rate=10k; }
        limit_traffic_rate zone=client rate=20k;
        location / { }
    }
    server {
        listen 127.0.0.1:8080;
        server_name order;
        limit_traffic_rate zone=client rate=40k;
        when a { limit_traffic_rate zone=object rate=8k; }
        location / { }
    }
    server {
        listen 127.0.0.1:8080;
        server_name redirect;
        expr moved str_eq $uri /target;
        when moved { limit_traffic_rate zone=object rate=8k; }
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
        location = /off {
            limit_traffic_rate off;
            alias %%TESTDIR%%/data;
        }
    }
}
EOF

$t->write_file('data', 'ok');
$t->write_file('hold', 'X' x (1024 * 1024));
$t->write_file('target', 'ok');
$t->run();

for my $case (@cases) {
    my ($host, $uri, $rate) = @$case;
    my $response = http("GET $uri HTTP/1.0\r\nHost: $host\r\n\r\n");
    like($response,
        qr/\AHTTP\/1\.[01] 200 .*?\r\nX-Rate: $rate(?=\r\n).*?\r\n\r\nok\z/s,
        "$host $uri");
}

my $held = http("GET /hold?client=shared&object=shared&a=1&b=1&p=1 HTTP/1.0\r\nHost: combined\r\n\r\n", start => 1);
my $headers = '';
my $select = IO::Select->new($held);
while ($headers !~ /\r\n\r\n/) {
    die 'timed out reading headers' unless $select->can_read(5);
    my $n = sysread($held, my $buffer, 4096);
    die 'connection closed before headers' unless $n;
    $headers .= $buffer;
}
like($headers, qr/^X-Rate: 32768\r?$/m, 'first matching policy registers its zone');
like(http("GET /data?client=shared&p=1 HTTP/1.0\r\nHost: inherit\r\n\r\n"),
    qr/^X-Rate: 65536\r?$/m, 'conditional hit does not count in the parent zone');
like(http("GET /data?client=shared&object=shared&b=1 HTTP/1.0\r\nHost: combined\r\n\r\n"),
    qr/^X-Rate: 16384\r?$/m, 'later matching policy has no hidden registration');
like(http("GET /data?object=shared&a=1 HTTP/1.0\r\nHost: combined\r\n\r\n"),
    qr/^X-Rate: 16384\r?$/m, 'requests selecting the same zone and key share a counter');
close $held;
my $released;
for (1 .. 100) {
    my $response = http("GET /data?object=shared&a=1 HTTP/1.0\r\nHost: combined\r\n\r\n");
    if ($response =~ /^X-Rate: 32768\r?$/m) {
        $released = 1;
        last;
    }
    sleep 0.02;
}
ok($released, 'conditional policy registration is released after abort');

$t->stop();
is_deeply([split /\n/, $t->read_file('rate.log')],
    ['/data 0 20480', '/data 1 10240', '/off 1 20480'],
    'unmatched conditions and off preserve the native write-filter rate');
