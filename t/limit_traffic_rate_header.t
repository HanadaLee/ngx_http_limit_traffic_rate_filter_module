#!/usr/bin/perl

# Response-time admission, bodyless responses, subrequests and late variables.

use warnings;
use strict;

use IO::Select;
use IO::Socket::INET;
use Test::More;
use Time::HiRes qw/sleep/;

BEGIN { use FindBin; chdir($FindBin::Bin); }

use Test::Nginx qw/:DEFAULT http_end/;

my $t = Test::Nginx->new()->has(qw/http proxy rewrite ssi slice auth_request
    ngx_http_limit_traffic_rate_filter_module/)->plan(22);
my $expr = $t->has_module('ngx_expr_module');
my $conditions = $expr ? <<'EOF' : '';
        expr auth_slow str_eq $policy slow;
        expr upstream_slow str_eq $upstream_http_x_policy slow;
        when auth_slow { limit_traffic_rate zone=rate rate=8k; }
        when upstream_slow { limit_traffic_rate zone=rate rate=8k; }
EOF

$t->write_file_expand('slice-probe.conf', <<'EOF');
%%TEST_GLOBALS%%
events {}
http {
    %%TEST_GLOBALS_HTTP%%
    slice on;
    slice_size 1k;
}
EOF
my $nginx = $ENV{TEST_NGINX_BINARY};
my $dir = $t->testdir();
my $probe = `"$nginx" -t -p "$dir/" -c slice-probe.conf 2>&1`;
my $slice_directives = $? == 0 ? 'slice on; slice_size 1k;' : 'slice 1k;';
# nginx -t can create the pid file that Test::Nginx uses as its startup signal.
unlink "$dir/nginx.pid";

my $conf = <<'EOF';
%%TEST_GLOBALS%%
daemon off;
events {}
http {
    %%TEST_GLOBALS_HTTP%%
    limit_traffic_rate_zone $http_x_key zone=rate:1m;

    server {
        listen 127.0.0.1:8080;
        %%CONDITIONS%%
        limit_traffic_rate zone=rate rate=32k;
        add_header X-Rate $limit_rate always;
        postpone_output 0;

        location = /data { }
        location = /hold { }
        location = /empty { }
        location = /direct { return 200 "direct"; }
        location = /no-content { return 204; }
        location = /missing { error_page 404 = @fallback; }
        location @fallback { return 200 "fallback"; }
        location = /bad-range {
            error_page 416 = @range_fallback;
            alias %%TESTDIR%%/data;
        }
        location @range_fallback {
            limit_traffic_rate zone=rate rate=64k;
            max_ranges 0;
            return 200 "fallback";
        }
        location = /delayed { proxy_pass http://127.0.0.1:8082/delay; }
        location = /headers { proxy_pass http://127.0.0.1:8082/headers; }
        location = /protected {
            auth_request /auth;
            auth_request_set $policy $upstream_http_x_policy;
            alias %%TESTDIR%%/data;
        }
        location = /auth {
            internal;
            proxy_pass http://127.0.0.1:8082/auth;
        }
        location = /ssi.html { ssi on; }
        location = /part {
            internal;
            proxy_pass http://127.0.0.1:8082/part;
        }
        location = /slice {
            %%SLICE%%
            proxy_set_header Range $slice_range;
            proxy_pass http://127.0.0.1:8081/hold;
        }
    }
    server {
        listen 127.0.0.1:8081;
        location / { }
    }
}
EOF
$conf =~ s/%%CONDITIONS%%/$conditions/;
$conf =~ s/%%SLICE%%/$slice_directives/;
$t->write_file_expand('nginx.conf', $conf);
$t->write_file('data', 'ok');
$t->write_file('empty', '');
$t->write_file('hold', 'X' x (1024 * 1024));
$t->write_file('ssi.html', '<!--# include virtual="/part" -->');
$t->run_daemon(\&origin, $t->testdir());
$t->waitforsocket('127.0.0.1:' . port(8082));
$t->run();

my $waiting = request('/delayed', 'waiting', start => 1);
$t->waitforfile($t->testdir() . '/ready-delay') or die 'upstream did not start';
rate(request('/data', 'waiting'), 32768,
    'waiting for upstream headers does not consume a share');
$t->write_file('release-delay', '');
like(http_end($waiting), qr/^HTTP\/1\.[01] 200 .*\r\n\r\nok\z/s,
    'delayed response is served after admission');

my $hold = request('/hold', 'held', start => 1);
rate(read_headers($hold), 32768, 'response joins the zone at header filtering');
rate(request('/hold', 'held', method => 'HEAD'), 0, 'HEAD is not registered');
rate(request('/no-content', 'held'), 0, '204 is not registered');
rate(request('/empty', 'held'), 0, 'empty response is not registered');
my ($etag) = request('/data', 'held') =~ /^ETag: (.+)\r$/m;
my $not_modified = request('/data', 'held', extra => "If-None-Match: $etag\r\n");
like($not_modified, qr/^HTTP\/1\.[01] 304 .*\r\nX-Rate: 0\r\n/s,
    'conditional 304 is not registered');
rate(request('/data', 'held'), 16384, 'bodyless responses leave no counters');
rate(request('/direct', 'held'), 16384, 'rewrite return response is limited');
rate(request('/not-found', 'held'), 16384, 'generated error body is limited');
like(request('/missing', 'held'),
    qr/^HTTP\/1\.[01] 200 .*\r\nX-Rate: 16384(?=\r\n).*\r\n\r\nfallback\z/s,
    'error_page registers the final response once');
like(request('/data', 'held', extra => "Range: bytes=0-0\r\n"),
    qr/^HTTP\/1\.[01] 206 .*\r\nX-Rate: 16384\r\n/s,
    'range response keeps one registration');
like(request('/bad-range', 'held', extra => "Range: bytes=99-100\r\n"),
    qr/^HTTP\/1\.[01] 200 .*\r\nX-Rate: 32768(?=\r\n).*\r\n\r\nfallback\z/s,
    'later filter error replaces the registration after a context reset');
close $hold;
released('held', 'finished response releases its counter');

my $ssi = request('/ssi.html', 'ssi', start => 1);
my $ssi_headers = read_headers($ssi);
rate($ssi_headers, 32768, 'SSI main response is registered');
$t->waitforfile($t->testdir() . '/ready-part') or die 'SSI upstream did not start';
rate(request('/data', 'ssi'), 16384, 'SSI subrequest does not consume a share');
$t->write_file('release-part', '');
like($ssi_headers . http_end($ssi), qr/\r\n\r\npart\z/,
    'SSI response body is preserved');

my $slice = request('/slice', 'slice', start => 1);
rate(read_headers($slice), 32768, 'slice main response is registered');
rate(request('/data', 'slice'), 16384, 'slice subrequests do not consume shares');
close $slice;
released('slice', 'aborted slice response releases its counter');

rate(request('/protected', 'auth'), $expr ? 8192 : 32768,
    'rate selection sees the access-stage authentication result');
rate(request('/headers', 'headers'), $expr ? 8192 : 32768,
    'rate selection sees upstream response headers');

$t->stop();

sub request {
    my ($uri, $key, %options) = @_;
    my $method = delete($options{method}) || 'GET';
    my $extra = delete($options{extra}) || '';
    return http("$method $uri HTTP/1.0\r\nHost: localhost\r\n"
        . "X-Key: $key\r\n$extra\r\n", %options);
}

sub rate {
    my ($response, $rate, $label) = @_;
    like($response, qr/^X-Rate: $rate\r?$/m, $label);
}

sub released {
    my ($key, $label) = @_;
    my $released;
    for (1 .. 100) {
        if (request('/data', $key) =~ /^X-Rate: 32768\r?$/m) {
            $released = 1;
            last;
        }
        sleep 0.02;
    }
    ok($released, $label);
}

sub read_headers {
    my ($s) = @_;
    my $response = '';
    my $select = IO::Select->new($s);
    while ($response !~ /\r\n\r\n/) {
        die 'timed out reading headers' unless $select->can_read(5);
        my $n = sysread($s, my $buffer, 4096);
        die 'connection closed before headers' unless $n;
        $response .= $buffer;
    }
    return $response;
}

sub origin {
    my ($dir) = @_;
    my $server = IO::Socket::INET->new(
        Proto => 'tcp', LocalAddr => '127.0.0.1:' . port(8082),
        Listen => 16, Reuse => 1,
    ) or die "origin listen failed: $!";
    $SIG{CHLD} = 'IGNORE';

    while (my $client = $server->accept()) {
        my $pid = fork();
        die "fork failed: $!" unless defined $pid;
        if ($pid) {
            close $client;
            next;
        }
        close $server;
        local $SIG{ALRM} = sub { die 'origin timed out'; };
        alarm(15);
        my $request = '';
        while ($request !~ /\r\n\r\n/) {
            my $n = sysread($client, my $buffer, 4096);
            exit 0 unless $n;
            $request .= $buffer;
        }
        my ($path) = $request =~ /^\S+ \/(\w+)/;
        if ($path eq 'delay' || $path eq 'part') {
            open my $ready, '>', "$dir/ready-$path" or die $!;
            close $ready;
            sleep 0.02 until -e "$dir/release-$path";
        }
        my $body = $path eq 'part' ? 'part' : 'ok';
        my $policy = $path eq 'auth' || $path eq 'headers'
            ? "X-Policy: slow\r\n" : '';
        print $client "HTTP/1.0 200 OK\r\nContent-Length: " . length($body)
            . "\r\nContent-Type: text/plain\r\n${policy}\r\n$body";
        close $client;
        exit 0;
    }
}
