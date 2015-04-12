package Bot::ZIRC::Plugin::Calc;

use Math::Calc::Parser 'calc';

use Moo;
extends 'Bot::ZIRC::Plugin';

sub calc_expression {
	my ($self, $expr) = @_;
	my $result = Math::Calc::Parser->try_evaluate($expr);
	return Math::Calc::Parser->error unless defined $result;
	return (undef, $result);
}

sub register {
	my ($self, $bot) = @_;
	
	$bot->add_plugin_method($self, 'calc_expression');
	
	$bot->add_command(
		name => 'calc',
		help_text => 'Calculate the result of a mathematical expression',
		usage_text => '<expression>',
		tokenize => 0,
		on_run => sub {
			my ($network, $sender, $channel, $expr) = @_;
			return 'usage' unless length $expr;
			my ($err, $result) = $self->calc_expression($expr);
			return $network->reply($sender, $channel, "Error evaluating expression: $err") if $err;
			$network->reply($sender, $channel, "Result: $result");
		},
	);
}

1;

=head1 NAME

Bot::ZIRC::Plugin::Calc - Calculator command plugin for Bot::ZIRC

=head1 SYNOPSIS

 my $bot = Bot::ZIRC->new(
   plugins => { Calc => 1 },
 );

=head1 DESCRIPTION

Adds a C<calc> command to a L<Bot::ZIRC> IRC bot for calculating mathematical
expressions. See L<Math::Calc::Parser> for details on implementation.

=head1 METHODS

=head2 calc_expression

 my ($err, $result) = $bot->calc_expression('3*7');
 die $err if $err;

Calculate the result of the expression using L<Math::Calc::Parser/"evaluate">.
The first return value will be the error message if an error occurs. Otherwise,
the result is returned as the second value.

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

L<Bot::ZIRC>, L<Math::Calc::Parser>
