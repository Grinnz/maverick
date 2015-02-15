package Bot::ZIRC::Network::GameSurge;

use Moo;
use warnings NONFATAL => 'all';
use namespace::clean;

extends 'Bot::ZIRC::Network';

sub do_identify {
	my ($self, $nick, $pass) = @_;
	$self->("Identifying with AuthServ as $nick");
	$self->write(quote => "authserv auth $nick $pass");
}

1;
