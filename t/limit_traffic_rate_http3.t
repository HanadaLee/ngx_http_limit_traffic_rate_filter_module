#!/usr/bin/perl

# QUIC streams share bandwidth and release registrations on cancellation.

use warnings;
use strict;

use POSIX qw/sysconf _SC_PAGESIZE/;
use Test::More;
use Time::HiRes qw/sleep time/;

BEGIN { use FindBin; chdir($FindBin::Bin); }

use Test::Nginx;
use Test::Nginx::HTTP3;

my $t = Test::Nginx->new()->has(qw/http http_v3 rewrite cryptx
    ngx_http_limit_traffic_rate_filter_module/)->has_daemon('openssl')->plan(17);

my $conf = <<'EOF';
%%TEST_GLOBALS%%
daemon off;
events { worker_connections 1024; }
http {
    %%TEST_GLOBALS_HTTP%%
    ssl_certificate localhost.crt;
    ssl_certificate_key localhost.key;
    limit_traffic_rate_zone $arg_key zone=rate:4m;
    limit_traffic_rate_zone $arg_key zone=small:%%ZONE_SIZE%%;
    server {
        listen 127.0.0.1:%%PORT_8980_UDP%% quic;
        http3_max_concurrent_streams 1024;
        limit_traffic_rate zone=rate rate=32k;
        add_header X-Rate $limit_rate always;
        location / { }
        location = /alternate {
            limit_traffic_rate zone=small rate=64k;
            alias %%TESTDIR%%/hold;
        }
        location = /off {
            limit_traffic_rate off;
            alias %%TESTDIR%%/data;
        }
        location = /no-content { return 204; }
        location = /not-modified { return 304; }
        location = /timed { limit_traffic_rate zone=rate rate=8k; }
        location = /small {
            limit_traffic_rate zone=small rate=32k;
            alias %%TESTDIR%%/hold;
        }
    }
}
EOF
my $zone_size = 8 * sysconf(_SC_PAGESIZE);
$conf =~ s/%%ZONE_SIZE%%/$zone_size/;
$t->write_file_expand('nginx.conf', $conf);
$t->write_file('openssl.conf', <<'EOF');
[ req ]
default_bits = 2048
encrypt_key = no
distinguished_name = req_distinguished_name
[ req_distinguished_name ]
EOF
my $d = $t->testdir();
system("openssl req -x509 -new -config $d/openssl.conf -subj /CN=localhost/ "
    . "-out $d/localhost.crt -keyout $d/localhost.key >$d/openssl.out 2>&1") == 0
    or die 'cannot create test certificate';
$t->write_file('hold', 'X' x (1024 * 1024));
$t->write_file('data', 'X');
$t->write_file('empty', '');
$t->write_file('timed', 'T' x 32768);
$t->run();

my $s = Test::Nginx::HTTP3->new();
$s->h3_max_data(64 * 1024 * 1024);
my $first = $s->new_stream({ path => '/hold?key=shared' });
headers($s, $first, 200, 32768, 'first QUIC stream receives the full share');
my $second = $s->new_stream({ path => '/hold?key=shared' });
headers($s, $second, 200, 16384, 'second QUIC stream shares the zone');
my $other = $s->new_stream({ path => '/data?key=other' });
headers($s, $other, 200, 32768, 'different key has an independent share', 1);
my $head = $s->new_stream({ path => '/hold?key=shared', method => 'HEAD' });
headers($s, $head, 200, 0, 'HTTP/3 HEAD does not register', 1);

my $alternate = $s->new_stream({ path => '/alternate?key=shared' });
headers($s, $alternate, 200, 65536, 'local policy selects another zone');
my $parent = $s->new_stream({ path => '/data?key=shared' });
headers($s, $parent, 200, 10922, 'selected zone does not count in the parent zone', 1);
my $off = $s->new_stream({ path => '/off?key=shared' });
headers($s, $off, 200, 0, 'off bypasses the inherited policy', 1);
$s->stop_sending($alternate, 0x010c);
$s->read(all => [{ sid => $alternate, type => 'RESET_STREAM' }]);

$s->stop_sending($second, 0x010c);
$s->read(all => [{ sid => $second, type => 'RESET_STREAM' }]);
recovered($s, '/data?key=shared', 16384,
    'cancelled QUIC stream releases its counter');
$s->stop_sending($first, 0x010c);
$s->read(all => [{ sid => $first, type => 'RESET_STREAM' }]);
recovered($s, '/data?key=shared', 32768,
    'all cancelled streams release their counters');
my $empty = $s->new_stream({ path => '/empty?key=shared' });
headers($s, $empty, 200, 0, 'HTTP/3 empty response does not register', 1);
my $no_content = $s->new_stream({ path => '/no-content?key=shared' });
headers($s, $no_content, 204, 0, 'HTTP/3 204 does not register', 1);
my $not_modified = $s->new_stream({ path => '/not-modified?key=shared' });
headers($s, $not_modified, 304, 0, 'HTTP/3 304 does not register', 1);

my (@held, $rejected, $error_headers, $body);
for my $i (1 .. 512) {
    my $sid = $s->new_stream({ path => '/small?key=' . sprintf('%0900d', $i) });
    my $frames = $s->read(all => [{ sid => $sid, fin => 1 }], wait => 0.1);
    my ($frame) = grep { $_->{type} eq 'HEADERS' && $_->{sid} == $sid } @$frames;
    die 'missing HTTP/3 response headers' unless $frame;
    if ($frame->{headers}->{':status'} == 503) {
        $rejected = $sid;
        $error_headers = $frame->{headers};
        unless (grep { $_->{sid} == $sid && ($_->{flags} || 0) & 1 } @$frames) {
            push @$frames, @{$s->read(all => [{ sid => $sid, fin => 1 }])};
        }
        $body = join '', map { $_->{data} }
            grep { $_->{type} eq 'DATA' && $_->{sid} == $sid } @$frames;
        last;
    }
    die 'unexpected HTTP/3 response' unless $frame->{headers}->{':status'} == 200;
    push @held, $sid;
}
ok(defined $rejected && @held, 'QUIC response admission rejects an exhausted zone');
ok(defined $body && $body =~ /503/
    && length($body) == $error_headers->{'content-length'},
    'HTTP/3 admission failure sends a complete error response');

for my $sid (@held) {
    $s->stop_sending($sid, 0x010c);
}
$s->read(all => [map { { sid => $_, type => 'RESET_STREAM' } } @held]) if @held;
my $recovered = recovered($s, '/small?key=' . ('new' x 300), 32768,
    'cancelled QUIC streams free exhausted storage');
$s->stop_sending($recovered, 0x010c);

my $start = time();
my $timed = $s->new_stream({ path => '/timed?key=timed' });
my $frames = $s->read(all => [{ sid => $timed, fin => 1 }]);
my $elapsed = time() - $start;
my $content = join '', map { $_->{data} }
    grep { $_->{type} eq 'DATA' && $_->{sid} == $timed } @$frames;
is($content, 'T' x 32768, 'HTTP/3 rate limiting preserves the complete body');
cmp_ok($elapsed, '>=', 2, 'HTTP/3 body transmission is rate limited');

undef $s;
$t->stop();

sub headers {
    my ($s, $sid, $status, $rate, $label, $fin) = @_;
    # Drain complete frames and retain partial DATA while a response is held.
    # Stopping at HEADERS can discard coalesced DATA in the test client.
    my $frames = $s->read(all => [{ sid => $sid, fin => 1 }],
        wait => $fin ? 3 : 0.1);
    my ($frame) = grep { $_->{type} eq 'HEADERS' && $_->{sid} == $sid } @$frames;
    is_deeply($frame ? [@{$frame->{headers}}{':status', 'x-rate'}] : [],
        [$status, $rate], $label);
}

sub recovered {
    my ($s, $path, $rate, $label) = @_;
    my ($sid, $actual);
    my $deadline = time() + 5;

    # STOP_SENDING can reach nginx while its rate-limit write timer is pending.
    # A RESET_STREAM notification does not imply request cleanup has run yet.
    while (time() < $deadline) {
        $sid = $s->new_stream({ path => $path });
        my $frames = $s->read(all => [{ sid => $sid, fin => 1 }], wait => 0.1);
        my ($frame) = grep { $_->{type} eq 'HEADERS' && $_->{sid} == $sid } @$frames;
        $actual = $frame ? [@{$frame->{headers}}{':status', 'x-rate'}] : [];
        last if @$actual && $actual->[0] == 200 && $actual->[1] == $rate;
        sleep 0.05;
    }

    is_deeply($actual, [200, $rate], $label);
    return $sid;
}
