#!/usr/bin/perl

# Tests for ngx_http_limit_traffic_rate_filter_module.

###############################################################################

use warnings;
use strict;

use IO::Select;
use IO::Socket::INET;
use Time::HiRes qw/ time /;
use Test::More;

BEGIN { use FindBin; chdir($FindBin::Bin); }

use Test::Nginx qw/ :DEFAULT http_content /;

###############################################################################

select STDERR; $| = 1;
select STDOUT; $| = 1;

my $t = Test::Nginx->new()->has(qw/http
	ngx_http_limit_traffic_rate_filter_module/)->plan(14);

$t->write_file_expand('nginx.conf', <<'EOF');

%%TEST_GLOBALS%%

daemon off;

events {
}

http {
    %%TEST_GLOBALS_HTTP%%

    limit_traffic_rate_zone rate $arg_key 1m;

    server {
        listen       127.0.0.1:8080;
        server_name  localhost;

        sendfile off;
        postpone_output 0;
        limit_traffic_rate rate 10k;

        location = /data {
            alias %%TESTDIR%%/data;
        }

        location = /slower {
            limit_traffic_rate rate 5k;
            alias %%TESTDIR%%/data;
        }
    }

    server {
        listen       127.0.0.1:8081;
        server_name  localhost;

        sendfile off;
        postpone_output 0;

        location = /data {
            alias %%TESTDIR%%/data;
        }
    }
}

EOF

$t->write_file('data', 'X' x 20000);
$t->run();

###############################################################################

my ($response, $elapsed) = timed_get('/data?key=one', 8080);
is(http_content($response), 'X' x 20000,
	'inherited traffic limit preserves response body');
cmp_ok($elapsed, '>=', 0.9, 'inherited traffic limit delays response');

($response, $elapsed) = timed_get('/data', 8080);
is(http_content($response), 'X' x 20000,
	'empty shared key preserves response body');
cmp_ok($elapsed, '<', 0.9, 'empty shared key bypasses traffic limit');

($response, $elapsed) = timed_get('/data?key=none', 8081);
is(http_content($response), 'X' x 20000,
	'unconfigured server preserves response body');
cmp_ok($elapsed, '<', 0.9, 'unconfigured server is not limited');

($response, $elapsed) = timed_get('/slower?key=override', 8080);
is(http_content($response), 'X' x 20000,
	'location traffic limit preserves response body');
cmp_ok($elapsed, '>=', 1.8, 'location traffic limit overrides inherited rate');

my ($same, $same_elapsed) = download_pair('shared', 'shared');
is(http_content($same->[0]), 'X' x 20000,
	'first shared-key download preserves response body');
is(http_content($same->[1]), 'X' x 20000,
	'second shared-key download preserves response body');
cmp_ok($same_elapsed, '>=', 2.5,
	'shared-key downloads divide the aggregate rate');

my ($separate, $separate_elapsed) = download_pair('left', 'right');
is(http_content($separate->[0]), 'X' x 20000,
	'first distinct-key download preserves response body');
is(http_content($separate->[1]), 'X' x 20000,
	'second distinct-key download preserves response body');
cmp_ok($same_elapsed - $separate_elapsed, '>=', 0.8,
	'distinct keys receive independent traffic limits');

###############################################################################

sub timed_get {
	my ($uri, $port) = @_;
	my $start = time();
	my $response = http_get($uri,
		PeerAddr => '127.0.0.1:' . port($port));

	return ($response, time() - $start);
}


sub download_pair {
	my ($first_key, $second_key) = @_;
	my @keys = ($first_key, $second_key);
	my (@sockets, @responses);

	for my $i (0 .. 1) {
		my $socket = IO::Socket::INET->new(
			PeerAddr => '127.0.0.1',
			PeerPort => port(8080),
			Proto => 'tcp',
		) or die "connect failed: $!";

		$socket->blocking(0);
		$sockets[$i] = $socket;
		$responses[$i] = '';
	}

	for my $i (0 .. 1) {
		my $request = "GET /data?key=$keys[$i] HTTP/1.1\x0d\x0a"
			. "Host: localhost\x0d\x0aConnection: close\x0d\x0a\x0d\x0a";
		my $offset = 0;

		while ($offset < length $request) {
			my $n = syswrite($sockets[$i], $request,
				length($request) - $offset, $offset);
			die "write failed: $!" unless defined $n;
			$offset += $n;
		}
	}

	my $start = time();
	my $select = IO::Select->new(@sockets);
	my %index = map { fileno($sockets[$_]) => $_ } 0 .. 1;

	while ($select->count) {
		my @ready = $select->can_read(15);
		die 'timed out reading concurrent downloads' unless @ready;

		for my $socket (@ready) {
			my $buffer = '';
			my $n = sysread($socket, $buffer, 16384);
			die "read failed: $!" unless defined $n;

			if ($n == 0) {
				$select->remove($socket);
				close $socket;
				next;
			}

			$responses[$index{fileno($socket)}] .= $buffer;
		}
	}

	return (\@responses, time() - $start);
}

###############################################################################
