#!/usr/bin/perl

# Reject duplicate values for one zone and one condition at the same level.

use warnings;
use strict;

use Test::More;

BEGIN { use FindBin; chdir($FindBin::Bin); }

use Test::Nginx;

my $t = Test::Nginx->new()->has(qw/http
    ngx_http_limit_traffic_rate_filter_module/);
my @cases = (
    ['limit_traffic_rate zone=one rate=1k; limit_traffic_rate zone=one rate=2k;', qr/is duplicate/],
    ['limit_traffic_rate zone=one rate=1k; limit_traffic_rate zone=two rate=2k;', undef],
    ['limit_traffic_rate zone=missing rate=1k;', qr/zero size shared memory zone/],
    ['limit_traffic_rate rate=2k zone=one;', undef],
    ['limit_traffic_rate_zone shared zone=literal:1m; '
        . 'limit_traffic_rate zone=literal rate=1k;', undef],
    ['limit_traffic_rate_zone "$arg_key:$arg_group" zone=compound:1m;', undef],
    ['limit_traffic_rate_zone "" zone=empty:1m;', undef],
    ['limit_traffic_rate_zone $arg_key zone=:1m;', qr/invalid zone name/],
    ['limit_traffic_rate_zone $arg_key zone=bad;', qr/invalid zone size/],
    ['limit_traffic_rate_zone $arg_key zone=bad:;', qr/invalid zone size/],
    ['limit_traffic_rate_zone $arg_key zone=bad:1x;', qr/invalid zone size/],
    ['limit_traffic_rate_zone $arg_key bad=1m;', qr/invalid parameter/],
    ['limit_traffic_rate zone= rate=1k;', qr/invalid zone name/],
    ['limit_traffic_rate zone=one rate=;', qr/invalid rate/],
    ['limit_traffic_rate zone=one rate=0;', qr/invalid rate/],
    ['limit_traffic_rate zone=one rate=-1;', qr/invalid rate/],
    ['limit_traffic_rate zone=one rate=1x;', qr/invalid rate/],
    ['limit_traffic_rate zone=one rate=$arg_rate;', qr/invalid rate/],
    ['limit_traffic_rate zone=one zone=two;', qr/duplicate parameter/],
    ['limit_traffic_rate rate=1k rate=2k;', qr/duplicate parameter/],
    ['limit_traffic_rate zone=one other=1k;', qr/invalid parameter/],
    ['limit_traffic_rate zone=one;', qr/invalid number of arguments/],
    ['limit_traffic_rate one 1k;', qr/invalid parameter/],
    ['limit_traffic_rate_zone old $arg_key 1m;',
        qr/invalid number of arguments/],
);

my $expr = $t->has_module('ngx_expr_module');
if ($expr) {
    push @cases,
        ['when a { limit_traffic_rate zone=one rate=1k; limit_traffic_rate zone=one rate=2k; }',
            qr/is duplicate/],
        ['when a { limit_traffic_rate zone=one rate=1k; } '
            . 'when a { limit_traffic_rate zone=one rate=2k; }', qr/is duplicate/],
        ['when a { limit_traffic_rate zone=one rate=1k; limit_traffic_rate zone=two rate=2k; }',
            undef],
        ['when a { limit_traffic_rate zone=one rate=1k; } '
            . 'when a { limit_traffic_rate zone=two rate=2k; }', undef],
        ['when a { limit_traffic_rate zone=one rate=1k; } limit_traffic_rate zone=one rate=2k;',
            undef],
        ['when a { limit_traffic_rate zone=one rate=0; }', qr/invalid rate/],
        ['when a { limit_traffic_rate_zone $arg_key zone=three:1m; }',
            qr/directive is not allowed here/];
}

$t->plan(scalar @cases);
my $nginx = $ENV{TEST_NGINX_BINARY};
my $dir = $t->testdir();

for my $case (@cases) {
    my ($directives, $error) = @$case;
    my $condition = $expr ? 'expr a str_eq $arg_a 1;' : '';
    $t->write_file_expand('nginx.conf', <<EOF);
%%TEST_GLOBALS%%
events {}
http {
    %%TEST_GLOBALS_HTTP%%
    limit_traffic_rate_zone \$arg_key zone=one:1m;
    limit_traffic_rate_zone \$arg_key zone=two:1m;
    $condition
    $directives
    server { listen 127.0.0.1:8080; }
}
EOF
    my $output = `"$nginx" -t -p "$dir/" -c nginx.conf 2>&1`;
    my $status = $?;
    if (defined $error) {
        ok($status != 0 && $output =~ $error, $directives) or diag($output);
    } else {
        is($status, 0, $directives) or diag($output);
    }
}
