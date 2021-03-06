package Bot::Maverick::Plugin::Calc;

use Carp 'croak';
use Math::Calc::Parser 'calc';
use Try::Tiny;

use Moo;
with 'Bot::Maverick::Plugin';

our $VERSION = '0.50';

sub register {
	my ($self, $bot) = @_;
	
	$bot->add_helper(calc_expression => sub {
		my ($bot, $expr) = @_;
		croak 'Undefined expression to evaluate' unless defined $expr;
		return Math::Calc::Parser->evaluate($expr);
	});
	
	$bot->add_command(
		name => 'calc',
		help_text => 'Calculate the result of a mathematical expression',
		usage_text => '<expression>',
		on_run => sub {
			my $m = shift;
			my $expr = $m->args;
			return 'usage' unless length $expr;
			try {
				my $result = $m->bot->calc_expression($expr);
				$m->reply("Result: $result");
			} catch {
				$m->reply("Error evaluating expression: $_");
			};
		},
	);
}

1;

=head1 NAME

Bot::Maverick::Plugin::Calc - Calculator command plugin for Maverick

=head1 SYNOPSIS

 my $bot = Bot::Maverick->new(
   plugins => { Calc => 1 },
 );

=head1 DESCRIPTION

Adds a C<calc> command to a L<Bot::Maverick> IRC bot for calculating
mathematical expressions. See L<Math::Calc::Parser> for details on
implementation.

=head1 METHODS

=head2 calc_expression

 my $result = $bot->calc_expression('3*7');

Calculate the result of the expression using L<Math::Calc::Parser/"evaluate">.
Returns the result of the expression or throws an exception on error.

=head1 COMMANDS

=head2 calc

 !calc log 5

Evaluate the expression with L</"calc_expression"> and display the result.

=head1 BUGS

Report any issues on the public bugtracker.

=head1 AUTHOR

Dan Book, C<dbook@cpan.org>

=head1 COPYRIGHT AND LICENSE

Copyright 2015, Dan Book.

This library is free software; you may redistribute it and/or modify it under
the terms of the Artistic License version 2.0.

=head1 SEE ALSO

L<Bot::Maverick>, L<Math::Calc::Parser>
