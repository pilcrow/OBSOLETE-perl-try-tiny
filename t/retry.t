#!/usr/bin/perl

use strict;
#use warnings;

use Test::More tests => 16;

BEGIN { use_ok 'Try::Tiny' };

sub will_explode { retry; }
my $i;

eval { will_explode; };
ok($@, 'Cannot retry outside catch (in subroutine)');

try {
	$i = 1 + 1;
	retry;
} catch {
	ok($_, 'Cannot retry outside catch (in try {})');
} finally {
	pass('Moved into finally after retry-exception');
};

$i = 0;
$@ = 'Initial error';
try {
	$i += 1;
	ok($@ =~ /Initial error/, '$@ preserved in try block');
	die('Argh');
} catch {
	ok($_ =~ /Argh/, 'catch-block error ($_) is as thrown in try {}');
	retry if $i < 5;
} finally {
	is($i, 5, 'retry-d operation repeated correctly');
};

ok($@ =~ /Initial error/, '$@ preserved after several retries');

1;
