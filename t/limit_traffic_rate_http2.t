#!/usr/bin/perl

# Each HTTP/2 stream registers one main response, independent of the connection.

use warnings;
use strict;

use Test::More;

BEGIN { use FindBin; chdir($FindBin::Bin); }

use Test::Nginx;
use Test::Nginx::HTTP2;

my $t = Test::Nginx->new()->has(qw/http http_v2 rewrite
    ngx_http_limit_traffic_rate_filter_module/)->plan(11);

$t->write_file_expand('nginx.conf', <<'EOF');
%%TEST_GLOBALS%%
daemon off;
events {}
http {
    %%TEST_GLOBALS_HTTP%%
    limit_traffic_rate_zone $arg_key zone=rate:1m;
    limit_traffic_rate_zone $arg_key zone=alternate:1m;
    server {
        listen 127.0.0.1:8080;
        http2 on;
        limit_traffic_rate zone=rate rate=32k;
        add_header X-Rate $limit_rate always;
        location / { }
        location = /alternate {
            limit_traffic_rate zone=alternate rate=64k;
            alias %%TESTDIR%%/hold;
        }
        location = /off {
            limit_traffic_rate off;
            alias %%TESTDIR%%/data;
        }
        location = /no-content { return 204; }
    }
}
EOF
$t->write_file('hold', 'X' x (1024 * 1024));
$t->write_file('data', 'X');
$t->write_file('empty', '');
$t->run();

my $s = Test::Nginx::HTTP2->new();
$s->h2_settings(0, 0x4 => 1);

my $first = $s->new_stream({ path => '/hold?key=shared' });
headers($s, $first, 200, 32768, 'first stream receives the full share');
my $second = $s->new_stream({ path => '/hold?key=shared' });
headers($s, $second, 200, 16384, 'second stream shares the zone');

my $other = $s->new_stream({ path => '/data?key=other' });
headers($s, $other, 200, 32768, 'different key has an independent counter', 1);
my $head = $s->new_stream({ path => '/hold?key=shared', method => 'HEAD' });
headers($s, $head, 200, 0, 'HEAD stream does not register', 1);

my $alternate = $s->new_stream({ path => '/alternate?key=shared' });
headers($s, $alternate, 200, 65536, 'local policy selects another zone');
my $parent = $s->new_stream({ path => '/data?key=shared' });
headers($s, $parent, 200, 10922, 'selected zone does not count in the parent zone', 1);
my $off = $s->new_stream({ path => '/off?key=shared' });
headers($s, $off, 200, 0, 'off bypasses the inherited policy', 1);
$s->h2_rst($alternate, 8);

$s->h2_rst($second, 8);
my $probe = $s->new_stream({ path => '/data?key=shared' });
headers($s, $probe, 200, 16384, 'reset stream releases its counter', 1);
$s->h2_rst($first, 8);
$probe = $s->new_stream({ path => '/data?key=shared' });
headers($s, $probe, 200, 32768, 'all reset streams release their counters', 1);

my $empty = $s->new_stream({ path => '/empty?key=shared' });
headers($s, $empty, 200, 0, 'empty stream does not register', 1);
my $no_content = $s->new_stream({ path => '/no-content?key=shared' });
headers($s, $no_content, 204, 0, '204 stream does not register', 1);

undef $s;
$t->stop();

sub headers {
    my ($s, $sid, $status, $rate, $label, $fin) = @_;
    my $wait = $fin ? { sid => $sid, fin => 1 } : { sid => $sid, length => 1 };
    my $frames = $s->read(all => [$wait]);
    my ($frame) = grep { $_->{type} eq 'HEADERS' && $_->{sid} == $sid } @$frames;
    is_deeply($frame ? [@{$frame->{headers}}{':status', 'x-rate'}] : [],
        [$status, $rate], $label);
}
