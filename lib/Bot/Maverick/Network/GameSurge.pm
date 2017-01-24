package Bot::Maverick::Network::GameSurge;

use Moo;
use namespace::clean;

extends 'Bot::Maverick::Network';

our $VERSION = '0.50';

sub identify {
	my ($self, $nick, $pass) = @_;
	$self->logger->debug("Identifying with AuthServ as $nick");
	$self->write("authserv auth $nick $pass");
}

1;
