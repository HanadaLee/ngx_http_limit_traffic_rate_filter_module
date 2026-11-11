#!/usr/bin/perl

# Measure native and shared traffic limits on generated response bodies.

use warnings;
use strict;

use IO::Select;
use Test::More;
use Time::HiRes qw/time/;

BEGIN { use FindBin; chdir($FindBin::Bin); }

use Test::Nginx;

my @cases = (
    ['/direct', 200, 8192],
    ['/denied', 403, 8192],
    ['/generated', 404, 64],
    ['/custom', 404, 8192],
    ['/upstream', 503, 8192],
);
my $t = Test::Nginx->new()->has(qw/http rewrite proxy
    ngx_http_limit_traffic_rate_filter_module/)->plan(3 * 2 * @cases + 1);

my $block = 'X' x 1024;
my $body = 'X' x 32768;
my $value = '$block' x 32;
my $servers = '';
for my $mode (qw/native shared/) {
    my $rate = $mode eq 'native' ? 'limit_rate 8k;'
        : 'limit_rate 1m; limit_traffic_rate zone=rate rate=8k;';
    my $slow = $mode eq 'native' ? 'limit_rate 64;'
        : 'limit_traffic_rate zone=rate rate=64;';
    my $parent = $mode eq 'native' ? 'limit_rate 1m;'
        : 'limit_traffic_rate off;';
    $servers .= <<EOF;
    server {
        listen 127.0.0.1:8080;
        server_name $mode;
        access_log %%TESTDIR%%/rate.log rate;
        set \$block "$block";
        $rate
        location = /direct { return 200 "$value"; }
        location = /denied { return 403 "$value"; }
        location = /generated {
            $slow
            try_files /missing =404;
        }
        location = /custom {
            $parent
            error_page 404 = \@error;
            try_files /missing =404;
        }
        location \@error {
            $rate
            return 404 "$value";
        }
        location = /upstream {
            proxy_pass http://127.0.0.1:8081/error;
        }
    }
EOF
}
$t->write_file_expand('nginx.conf', <<EOF);
%%TEST_GLOBALS%%
daemon off;
events {}
http {
    %%TEST_GLOBALS_HTTP%%
    server_tokens off;
    limit_traffic_rate_zone "\$host\$uri" zone=rate:1m;
    log_format rate '\$server_name \$request_uri \$status \$limit_rate';
    $servers
    server {
        listen 127.0.0.1:8081;
        set \$block "$block";
        access_log off;
        return 503 "$value";
    }
}
EOF
$t->run();

my $select = IO::Select->new();
my (%pending, @results, @expected_log);
for my $mode (qw/native shared/) {
    for my $case (@cases) {
        my ($uri, $status, $rate) = @$case;
        my $start = time();
        my $s = http("GET $uri HTTP/1.0\r\nHost: $mode\r\n\r\n", start => 1);
        $select->add($s);
        $pending{fileno($s)} = {
            start => $start, data => '', socket => $s,
            mode => $mode, uri => $uri, status => $status,
        };
        push @expected_log, "$mode $uri $status $rate";
    }
}

my $deadline = time() + 30;
while ($select->count) {
    die 'timed out reading responses' if time() > $deadline;
    for my $s ($select->can_read(1)) {
        my $result = $pending{fileno($s)};
        my $n = sysread($s, my $buffer, 65536);
        die 'response closed before its body was complete' unless $n;
        $result->{data} .= $buffer;
        my ($headers, $content) = split /\r\n\r\n/, $result->{data}, 2;
        next unless defined $content;
        my ($length) = $headers =~ /^Content-Length: (\d+)\r?$/mi;
        die 'missing response length' unless defined $length;
        next if length($content) < $length;
        $result->{elapsed} = time() - $result->{start};
        $result->{headers} = $headers;
        $result->{body} = $content;
        push @results, $result;
        delete $pending{fileno($s)};
        $select->remove($s);
        close $s;
    }
}

for my $result (sort { "$a->{mode}$a->{uri}" cmp "$b->{mode}$b->{uri}" } @results) {
    my $label = "$result->{mode} $result->{uri}";
    like($result->{headers}, qr/^HTTP\/1\.[01] $result->{status} /,
        "$label status");
    if ($result->{uri} eq '/generated') {
        like($result->{body}, qr/404 Not Found/, "$label built-in error body");
    } else {
        is($result->{body}, $body, "$label complete body");
    }
    cmp_ok($result->{elapsed}, '>=', $result->{uri} eq '/generated' ? 1 : 2,
        "$label transmission is rate limited");
    note(sprintf '%s completed in %.3fs', $label, $result->{elapsed});
}

$t->stop();
is_deeply([sort split /\n/, $t->read_file('rate.log')], [sort @expected_log],
    'return, built-in errors, error_page and upstream errors use the effective rate');
