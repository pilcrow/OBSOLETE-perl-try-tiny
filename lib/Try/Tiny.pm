package Try::Tiny;

use strict;
#use warnings;

use vars qw(@EXPORT @EXPORT_OK $VERSION @ISA);

BEGIN {
	require Exporter;
	@ISA = qw(Exporter);
}

$VERSION = "0.06";

$VERSION = eval $VERSION;

@EXPORT = @EXPORT_OK = qw(try catch finally retry);

$Carp::Internal{+__PACKAGE__}++;

# Need to prototype as @ not $$ because of the way Perl evaluates the prototype.
# Keeping it at $$ means you only ever get 1 sub because we need to eval in a list
# context & not a scalar one

sub try (&;@) {
	my ( $try, @code_refs ) = @_;

	# we need to save this here, the eval block will be in scalar context due
	# to $failed
	my $wantarray = wantarray;

	my ( $catch, $finally );

	# find labeled blocks in the argument list.
	# catch and finally tag the blocks by blessing a scalar reference to them.
	foreach my $code_ref (@code_refs) {
		next unless $code_ref;

		my $ref = ref($code_ref);

		if ( $ref eq 'Try::Tiny::Catch' ) {
			$catch = ${$code_ref};
		} elsif ( $ref eq 'Try::Tiny::Finally' ) {
			$finally = ${$code_ref};
		} else {
			use Carp;
			confess("Unknown code ref type given '${ref}'. Check your usage & try again");
		}
	}

	# set up a scope guard to invoke the finally block at the end
	my $guard = $finally && bless \$finally, "Try::Tiny::ScopeGuard";

	my ( @ret );

	# FIXME consider using local $SIG{__DIE__} to accumulate all errors. It's
	# not perfect, but we could provide a list of additional errors for
	# $catch->();

	TRY_TINY_TRY_LOOP: {
		my $err = _context_eval($wantarray, \@ret, $try);

		if ( defined($err) and $catch ) {
			$err = _call_catch_block($wantarray, \@ret, $catch, $err);
			die($err) if defined($err);
		}
	}

	return $wantarray ? @ret : $ret[0];
}

sub catch (&;@) {
	my ( $block, @rest ) = @_;

	return (
		bless(\$block, 'Try::Tiny::Catch'),
		@rest,
	);
}

sub finally (&;@) {
	my ( $block, @rest ) = @_;

	return (
		bless(\$block, 'Try::Tiny::Finally'),
		@rest,
	);
}

sub retry () {
	# Make sure we're called only in a catch block:
	#
	#   try { ... } catch { ... retry ... };
	#
	# Call frames for a proper invocation look like this:
	#
	# 5. Try::Tiny::try
	# 4. T::T::_call_catch_block .... this is what we look for
	# 3. T::T::_context_eval
	# 2. (eval)
	# 1. ANON ....................... the user-supplied block
	# 0. T::T::retry
	#
	my $callsub = ((caller(4))[3] || '');
	unless ($callsub eq 'Try::Tiny::_call_catch_block') {
		# Error inspired by:  Can't "redo" outside a loop block
		croak q|Can't "retry" outside a "catch" block|;
	}

	goto TRY_TINY_TRY_LOOP;
}

# -- utility routines

sub Try::Tiny::ScopeGuard::DESTROY {
	my $self = shift;
	$$self->();
}

sub _call_catch_block {
	# This sub principally does three things:
	#  1. Set up a call frame reference so that retry() can determine if
	#     it was invoked properly
	#  2. Alias the failure ($@) from try{block} as $_ (via a for loop)
	#  3. Permit the user's catch{block} to call 'when' without an
	#     explicit return
	my ($wantarray, $retref, $catch, $error) = @_;

	for ($error) {
		return _context_eval($wantarray, $retref, $catch, $error);
	}

	return; # catch{block} called when without explicit return.
}

# Invoke user-supplied CODEref and arguments in a given context,
# capturing its return values in an output variable and making a best
# effort to return its exception object, if any.
#
sub _context_eval {
	my ($wantarray, $retref, $code, @args) = @_;
	my $prev_error = $@;    # let the user's CODE see the enclosing $@

	local $@;               # restore $@ when this sub finishes
	my $failed = not eval {
		$@ = $prev_error;

		if ($wantarray) {
			@$retref = $code->(@args);
		} elsif (defined $wantarray) {
			$retref->[0] = $code->(@args);
		} else {
			$code->(@args);
		}

		1;
	};
	return $@ if $failed;
	return;
}

__PACKAGE__

__END__

=pod

=head1 NAME

Try::Tiny - minimal try/catch with proper localization of $@

=head1 SYNOPSIS

	# handle errors with a catch handler
	try {
		die "foo";
	} catch {
		warn "caught error: $_"; # not $@
	};

	# just silence errors
	try {
		die "foo";
	};

=head1 DESCRIPTION

This module provides bare bones C<try>/C<catch>/C<finally>/C<retry> statements
that are designed to minimize common mistakes with eval blocks, and NOTHING
else.

This is unlike L<TryCatch> which provides a nice syntax and avoids adding
another call stack layer, and supports calling C<return> from the C<try> block
to return from the parent subroutine. These extra features come at a cost of a
few dependencies, namely L<Devel::Declare> and L<Scope::Upper> which are
occasionally problematic, and the additional catch filtering uses L<Moose> type
constraints which may not be desirable either.

The main focus of this module is to provide simple and reliable error handling
for those having a hard time installing L<TryCatch>, but who still want to
write correct C<eval> blocks without 5 lines of boilerplate each time.

It's designed to work as correctly as possible in light of the various
pathological edge cases (see L<BACKGROUND>) and to be compatible with any style
of error values (simple strings, references, objects, overloaded objects, etc).

If the C<try> block dies, it returns the value of the last statement executed
in the C<catch> block, if there is one. Otherwise, it returns C<undef> in
scalar context or the empty list in list context. The following two examples
both assign C<"bar"> to C<$x>.

	my $x = try { die "foo" } catch { "bar" };

	my $x = eval { die "foo" } || "bar";

You can add C<finally> blocks making the following true.

	my $x;
	try { die 'foo' } finally { $x = 'bar' };
	try { die 'foo' } catch { warn "Got a die: $_" } finally { $x = 'bar' };

C<finally> blocks are always executed, making them suitable for cleanup code
which cannot be handled using L<local|perlfunc/local>.

The retry subroutine, when called from within a C<catch> block, terminates the
current C<catch> block and restarts its C<try> block.

=head1 EXPORTS

All functions are exported by default using L<Exporter>.

If you need to rename the C<try>, C<catch>, C<finally> or C<retry> keywords,
consider using L<Sub::Import> to get L<Sub::Exporter>'s flexibility.

=over 4

=item try (&;@)

Takes one mandatory try subroutine, an optional catch subroutine & finally
subroutine.

The mandatory subroutine is evaluated in the context of an C<eval> block.

If no error occurred the value from the first block is returned, preserving
list/scalar context.

If there was an error and the second subroutine was given it will be invoked
with the error in C<$_> (localized) and as that block's first and only
argument.

C<$@> does B<not> contain the error. Inside the C<catch> block it has the same
value it had before the C<try> block was executed.

Note that the error may be false, but if that happens the C<catch> block will
still be invoked.

Once all execution is finished then the finally block if given will execute.

=item catch (&;$)

Intended to be used in the second argument position of C<try>.

Returns a reference to the subroutine it was given but blessed as
C<Try::Tiny::Catch> which allows try to decode correctly what to do
with this code reference.

	catch { ... }

Inside the catch block the caught error is stored in C<$_>, while previous
value of C<$@> is still available for use.  This value may or may not be
meaningful depending on what happened before the C<try>, but it might be a good
idea to preserve it in an error stack.

For code that captures C<$@> when throwing new errors (i.e.
L<Class::Throwable>), you'll need to do:

	local $@ = $_;

=item finally (&;$)

  try     { ... }
  catch   { ... }
  finally { ... };

Or

  try     { ... }
  finally { ... };

Or even

  try     { ... }
  finally { ... }
  catch   { ... };

Intended to be the second or third element of C<try>.  C<finally> blocks are
always executed in the event of a successful C<try> or if C<catch> is run. This
allows you to locate cleanup code which cannot be done via
L<local()|perlfunc/local> e.g., closing a file handle.

B<You must always do your own error handling in the C<finally> block>.
C<Try::Tiny> will not do anything about handling possible errors coming from
code located in these blocks.

In the same way C<catch()> blesses the code reference this subroutine does the
same except it bless them as C<Try::Tiny::Finally>.

=item retry

Intended to be called I<inside the top scope> of a C<catch> block.

This function never returns.  Instead, it restarts the C<try> block if called
from within the top scope of a C<catch> block, or raises an exception if
called anywhere else.  For example:

  try     { ... }
  catch   { retry unless $ok; }  # Correct!
  finally { ... };

  try     { retry unless $ok; }; # Incorrect - must be called in catch block
  try     { ... }
  finally { retry unless $ok; }; # Incorrect - must be called in catch block

  sub handle_error { retry; }
  try     { ... }
  catch   { handle_error(); };   # Incorrect - must be called in top scope
                                 # of catch block

=back

=head1 BACKGROUND

There are a number of issues with C<eval>.

=head2 Clobbering $@

When you run an eval block and it succeeds, C<$@> will be cleared, potentially
clobbering an error that is currently being caught.

This causes action at a distance, clearing previous errors your caller may have
not yet handled.

C<$@> must be properly localized before invoking C<eval> in order to avoid this
issue.

More specifically, C<$@> is clobbered at the beginning of the C<eval>, which
also makes it impossible to capture the previous error before you die (for
instance when making exception objects with error stacks).

For this reason C<try> will actually set C<$@> to its previous value (before
the localization) in the beginning of the C<eval> block.

=head2 Localizing $@ silently masks errors

Inside an eval block C<die> behaves sort of like:

	sub die {
		$@ = $_[0];
		return_undef_from_eval();
	}

This means that if you were polite and localized C<$@> you can't die in that
scope, or your error will be discarded (printing "Something's wrong" instead).

The workaround is very ugly:

	my $error = do {
		local $@;
		eval { ... };
		$@;
	};

	...
	die $error;

=head2 $@ might not be a true value

This code is wrong:

	if ( $@ ) {
		...
	}

because due to the previous caveats it may have been unset.

C<$@> could also be an overloaded error object that evaluates to false, but
that's asking for trouble anyway.

The classic failure mode is:

	sub Object::DESTROY {
		eval { ... }
	}

	eval {
		my $obj = Object->new;

		die "foo";
	};

	if ( $@ ) {

	}

In this case since C<Object::DESTROY> is not localizing C<$@> but still uses
C<eval>, it will set C<$@> to C<"">.

The destructor is called when the stack is unwound, after C<die> sets C<$@> to
C<"foo at Foo.pm line 42\n">, so by the time C<if ( $@ )> is evaluated it has
been cleared by C<eval> in the destructor.

The workaround for this is even uglier than the previous ones. Even though we
can't save the value of C<$@> from code that doesn't localize, we can at least
be sure the eval was aborted due to an error:

	my $failed = not eval {
		...

		return 1;
	};

This is because an C<eval> that caught a C<die> will always return a false
value.

=head1 SHINY SYNTAX

Using Perl 5.10 you can use L<perlsyn/"Switch statements">.

The C<catch> block is invoked in a topicalizer context (like a C<given> block),
but note that you can't return a useful value from C<catch> using the C<when>
blocks without an explicit C<return>.

This is somewhat similar to Perl 6's C<CATCH> blocks. You can use it to
concisely match errors:

	try {
		require Foo;
	} catch {
		when (/^Can't locate .*?\.pm in \@INC/) { } # ignore
		default { die $_ }
	};

=head1 CAVEATS

=over 4

=item *

C<@_> is not available, you need to name your args:

	sub foo {
		my ( $self, @args ) = @_;
		try { $self->bar(@args) }
	}

=item *

C<return> returns from the C<try> block, not from the parent sub (note that
this is also how C<eval> works, but not how L<TryCatch> works):

	sub bar {
		try { return "foo" };
		return "baz";
	}

	say bar(); # "baz"

=item *

C<try> introduces another caller stack frame. L<Sub::Uplevel> is not used. L<Carp>
will not report this when using full stack traces, though, because
C<%Carp::Internal> is used. This lack of magic is considered a feature.

=item *

The value of C<$_> in the C<catch> block is not guaranteed to be the value of
the exception thrown (C<$@>) in the C<try> block.  There is no safe way to
ensure this, since C<eval> may be used unhygenically in destructors.  The only
guarantee is that the C<catch> will be called if an exception is thrown.

=item *

The return value of the C<catch> block is not ignored, so if testing the result
of the expression for truth on success, be sure to return a false value from
the C<catch> block:

	my $obj = try {
		MightFail->new;
	} catch {
		...

		return; # avoid returning a true value;
	};

	return unless $obj;

=item *

C<$SIG{__DIE__}> is still in effect.

Though it can be argued that C<$SIG{__DIE__}> should be disabled inside of
C<eval> blocks, since it isn't people have grown to rely on it. Therefore in
the interests of compatibility, C<try> does not disable C<$SIG{__DIE__}> for
the scope of the error throwing code.

=item *

Lexical C<$_> may override the one set by C<catch>.

For example Perl 5.10's C<given> form uses a lexical C<$_>, creating some
confusing behavior:

	given ($foo) {
		when (...) {
			try {
				...
			} catch {
				warn $_; # will print $foo, not the error
				warn $_[0]; # instead, get the error like this
			}
		}
	}

=back

=head1 SEE ALSO

=over 4

=item L<TryCatch>

Much more feature complete, more convenient semantics, but at the cost of
implementation complexity.

=item L<autodie>

Automatic error throwing for builtin functions and more. Also designed to
work well with C<given>/C<when>.

=item L<Throwable>

A lightweight role for rolling your own exception classes.

=item L<Error>

Exception object implementation with a C<try> statement. Does not localize
C<$@>.

=item L<Exception::Class::TryCatch>

Provides a C<catch> statement, but properly calling C<eval> is your
responsibility.

The C<try> keyword pushes C<$@> onto an error stack, avoiding some of the
issues with C<$@>, but you still need to localize to prevent clobbering.

=back

=head1 LIGHTNING TALK

I gave a lightning talk about this module, you can see the slides (Firefox
only):

L<http://nothingmuch.woobling.org/talks/takahashi.xul?data=yapc_asia_2009/try_tiny.txt>

Or read the source:

L<http://nothingmuch.woobling.org/talks/yapc_asia_2009/try_tiny.yml>

=head1 VERSION CONTROL

L<http://github.com/nothingmuch/try-tiny/>

=head1 AUTHOR

Yuval Kogman E<lt>nothingmuch@woobling.orgE<gt>

=head1 COPYRIGHT

	Copyright (c) 2009 Yuval Kogman. All rights reserved.
	This program is free software; you can redistribute
	it and/or modify it under the terms of the MIT license.

=cut

