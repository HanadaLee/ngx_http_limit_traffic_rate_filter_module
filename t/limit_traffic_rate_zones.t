#!/usr/bin/perl

# Whole-policy inheritance, independent zones and internal redirects.

use warnings;
use strict;

use IO::Select;
use Test::More;
use Time::HiRes qw/sleep/;

BEGIN { use FindBin; chdir($FindBin::Bin); }

use Test::Nginx;

my $t = Test::Nginx->new()->has(qw/http rewrite
    ngx_http_limit_traffic_rate_filter_module/)->plan(31);

$t->write_file_expand('nginx.conf', <<'EOF');
%%TEST_GLOBALS%%
daemon off;
events {}
http {
    %%TEST_GLOBALS_HTTP%%

    limit_traffic_rate_zone $arg_client zone=client:1m;
    limit_traffic_rate_zone $arg_object zone=object:1m;
    limit_traffic_rate_zone $arg_client zone=Client:1m;
    limit_traffic_rate_zone "$arg_a:$arg_b" zone=compound:1m;
    limit_traffic_rate zone=client rate=16k;

    server {
        listen 127.0.0.1:8080;
        server_name localhost;
        limit_traffic_rate zone=object rate=12k;
        add_header X-Rate $limit_rate always;
        sendfile off;
        postpone_output 0;

        location = /data {
            alias %%TESTDIR%%/data;
        }
        location = /override {
            limit_traffic_rate zone=client rate=32k;
            alias %%TESTDIR%%/data;
        }
        location = /case {
            limit_traffic_rate zone=Client rate=8k;
            alias %%TESTDIR%%/data;
        }
        location = /hold {
            alias %%TESTDIR%%/hold;
        }
        location = /off {
            limit_traffic_rate off;
            limit_rate 20k;
            alias %%TESTDIR%%/data;
        }
        location = /compound {
            limit_traffic_rate rate=10k zone=compound;
            alias %%TESTDIR%%/data;
        }
        location = /compound_hold {
            limit_traffic_rate zone=compound rate=10k;
            alias %%TESTDIR%%/hold;
        }
        location = /key_redirect {
            try_files /missing /hold?object=target;
        }
        location = /redirect {
            limit_traffic_rate zone=object rate=2k;
            try_files /missing /target?$args;
        }
        location = /target {
            limit_traffic_rate zone=object rate=24k;
            alias %%TESTDIR%%/data;
        }
        location = /named {
            limit_traffic_rate zone=object rate=2k;
            try_files /missing @target;
        }
        location @target {
            limit_traffic_rate zone=object rate=24k;
            root %%TESTDIR%%;
            try_files /data =404;
        }
    }
}
EOF

$t->write_file('data', 'ok');
$t->write_file('hold', 'X' x (1024 * 1024));
$t->run();

rate('/?client=a', 0, 'empty selected key does not fall back to the HTTP policy');
rate('/?object=a', 12288, 'server zone applies');
rate('/?client=a&object=a', 12288, 'server policy replaces the entire HTTP policy');
rate('/override?client=a', 32768, 'location replaces the server policy with another zone');
rate('/override?client=a&object=a', 32768, 'location policy does not retain the server zone');
rate('/?object=a', 12288, 'location override does not mutate siblings');
rate('/case?client=a', 8192, 'zone names are case sensitive');
rate('/', 0, 'empty selected key bypasses the module');

my $s = http_get('/hold?client=shared&object=shared', start => 1);
my $headers = read_headers($s);
like($headers, qr/^X-Rate: 12288\r?$/m, 'holding request joins only the selected zone');

rate('/override?client=shared', 32768, 'unselected parent zone has no registration');
rate('/?object=shared', 6144, 'selected zone shares its counter');
rate('/target?object=shared', 12288,
    'different policy rates share the same zone counter');
rate('/?client=shared&object=shared', 6144,
    'request joins the selected zone only once');
rate('/?client=other&object=other', 12288, 'unrelated keys stay independent');

close $s;
my $released;
for (1 .. 100) {
    my $response = http_get('/data?client=shared&object=shared');
    if ($response =~ /^X-Rate: 12288\r?$/m) {
        $released = 1;
        last;
    }
    sleep 0.02;
}
ok($released, 'client abort releases the selected zone');
rate('/override?client=shared', 32768, 'unselected zone remains unaffected');
rate('/?object=shared', 12288, 'object counter restored after abort');
rate('/redirect?object=redirect', 24576,
    'URI redirect reevaluates configuration without double counting');
rate('/named?object=named', 24576,
    'named location reevaluates configuration without double counting');
rate('/?object=redirect', 12288, 'URI redirect leaves no stale count');
rate('/?object=named', 12288, 'named location leaves no stale count');

my $compound = http_get('/compound_hold?a=one&b=two', start => 1);
like(read_headers($compound), qr/^X-Rate: 10240\r?$/m,
    'compound key joins its zone');
rate('/compound?a=one&b=two', 5120, 'equal compound keys share a counter');
rate('/compound?a=one&b=other', 10240, 'second key component is significant');
rate('/compound?a=other&b=two', 10240, 'first key component is significant');
close $compound;

my $redirect = http_get('/key_redirect?client=source&object=source', start => 1);
like(read_headers($redirect), qr/^X-Rate: 12288\r?$/m,
    'internal redirect reevaluates the zone key');
rate('/?object=source', 12288, 'redirect leaves the original key unregistered');
rate('/?object=target', 6144, 'redirect registers the new key');
close $redirect;

rate('/off?object=shared', 0, 'off suppresses inherited registration');
rate('/override?object=shared', 0, 'empty local key does not try the server zone');
rate('/?object=' . ('x' x 1025) . '&client=shared', 0,
    'oversized selected key does not fall back to the parent policy');

$t->stop();

sub rate {
    my ($uri, $expected, $label) = @_;
    $uri =~ s{^/(?=\?|$)}{/data};
    like(http_get($uri),
        qr/\AHTTP\/1\.[01] 200 .*?\r\nX-Rate: $expected(?=\r\n).*?\r\n\r\nok\z/s,
        $label);
}

sub read_headers {
    my ($s) = @_;
    my $headers = '';
    my $select = IO::Select->new($s);

    while ($headers !~ /\r\n\r\n/) {
        die 'timed out reading headers' unless $select->can_read(5);
        my $n = sysread($s, my $buffer, 4096);
        die 'connection closed before headers' unless $n;
        $headers .= $buffer;
    }

    return $headers;
}
