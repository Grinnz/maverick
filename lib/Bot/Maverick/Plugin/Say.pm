package Bot::Maverick::Plugin::Say;

use Bot::Maverick::Access ':access';

use Moo;
with 'Bot::Maverick::Plugin';

our $VERSION = '0.50';

sub register {
	my ($self, $bot) = @_;
	
	$bot->add_command(
		name => 'say',
		help_text => 'Send a message in a channel',
		usage_text => '[<channel>] <message>',
		required_access => ACCESS_BOT_ADMIN,
		on_run => sub {
			my $m = shift;
			my $say_msg = $m->args;
			my $in_chan;
			if ($say_msg =~ s/^(#\S+)\s*//) {
				$in_chan = $1;
			}
			return 'usage' unless $say_msg;
			$m->reply_bare($say_msg, $in_chan);
		},
	);
	
	$bot->add_command(
		name => 'me',
		help_text => 'Send an action message in a channel',
		usage_text => '[<channel>] <message>',
		required_access => ACCESS_BOT_ADMIN,
		on_run => sub {
			my $m = shift;
			my $action_msg = $m->args;
			my $in_chan;
			if ($action_msg =~ s/^(#\S+)\s*//) {
				$in_chan = $1;
			}
			return 'usage' unless $action_msg;
			$m->reply_bare("\x01ACTION $action_msg\x01", $in_chan);
		},
	);
}

1;

=head1 NAME

Bot::Maverick::Plugin::Say - Maverick plugin for repeating messages

=head1 SYNOPSIS

 my $bot = Bot::Maverick->new(
   plugins => { Say => 1 },
 );

=head1 DESCRIPTION

Adds commands for repeating a message to a L<Bot::Maverick> IRC bot.

=head1 COMMANDS

=head2 say

 !say This is a message
 !say #some-channel This is another message

Sends the message, in the current channel if not specified.

=head2 me

 !me This is an action
 !me #some-channel This is another action

Sends the action message, in the current channel if not specified.

=head1 BUGS

Report any issues on the public bugtracker.

=head1 AUTHOR

Dan Book, C<dbook@cpan.org>

=head1 COPYRIGHT AND LICENSE

Copyright 2015, Dan Book.

This library is free software; you may redistribute it and/or modify it under
the terms of the Artistic License version 2.0.

=head1 SEE ALSO

L<Bot::Maverick>
