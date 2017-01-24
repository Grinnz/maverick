package Bot::Maverick::Network::SocialGamer;

use Moo;
use namespace::clean;

extends 'Bot::Maverick::Network';

our $VERSION = '0.50';

after 'register_event_handlers' => sub {
	my $self = shift;
	$self->register_event_handler('irc_320');
};

sub _irc_320 { # RPL_WHOISIDENTIFIED
	my ($self, $message) = @_;
	my ($to, $nick, $lia) = @{$message->{params}};
	if ($lia =~ /is logged in as ([[:graph:]]+)/) {
		my $identity = $1;
		$self->logger->debug("Received identity for $nick: $identity");
		$self->user($nick)->identity($identity);
	}
}

1;
