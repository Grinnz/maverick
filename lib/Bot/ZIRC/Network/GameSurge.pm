package Bot::ZIRC::Network::GameSurge;

use Moo;
use namespace::clean;

extends 'Bot::ZIRC::Network';

sub do_identify {
	my ($self, $nick, $pass) = @_;
	$self->logger->debug("Identifying with AuthServ as $nick");
	$self->write("authserv auth $nick $pass");
}

1;
