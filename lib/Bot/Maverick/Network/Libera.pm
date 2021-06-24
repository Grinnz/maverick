package Bot::Maverick::Network::Libera;

use IRC::Utils 'parse_user';

use Moo;
use namespace::clean;

extends 'Bot::Maverick::Network';

our $VERSION = '0.50';

before [qw(_irc_invite _irc_join _irc_kick _irc_mode _irc_nick _irc_notice _irc_part _irc_privmsg _irc_public _irc_quit)] => sub {
	my ($self, $message) = @_;
	my ($nick, undef, $host) = parse_user($message->{prefix});
	if (defined $host and $host =~ m!(\A|/)bot(/|\z)! and !$self->user($nick)->is_bot) {
		$self->logger->debug("Marking $nick as a bot due to /bot/ hostmask");
		$self->user($nick)->is_bot(1);
	}
};

1;
