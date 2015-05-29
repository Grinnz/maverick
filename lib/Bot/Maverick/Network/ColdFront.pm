package Bot::Maverick::Network::ColdFront;

use Moo;
use namespace::clean;

extends 'Bot::Maverick::Network';

our $VERSION = '0.20';

after 'register_event_handlers' => sub {
	my $self = shift;
	$self->register_event_handler('irc_307');
};

sub _irc_307 { # RPL_WHOISREGNICK
	my ($self, $message) = @_;
	my ($to, $nick, $lia) = @{$message->{params}};
	$self->logger->debug("Received identity for $nick: $lia");
	$self->user($nick)->identity($nick);
}

1;
