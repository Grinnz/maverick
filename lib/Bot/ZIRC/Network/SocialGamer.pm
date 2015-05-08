package Bot::ZIRC::Network::SocialGamer;

use Moo;
use namespace::clean;

extends 'Bot::ZIRC::Network';

our $VERSION = '0.20';

after 'register_event_handlers' => sub {
	my $self = shift;
	$self->register_event_handler('irc_320');
};

sub irc_320 { # RPL_WHOISIDENTIFIED
	my ($self, $message) = @_;
	my ($to, $nick, $lia) = @{$message->{params}};
	if ($lia =~ /is logged in as ([[:graph:]]+)/) {
		my $identity = $1;
		$self->logger->debug("Received identity for $nick: $identity");
		$self->user($nick)->identity($identity);
	}
}

1;
