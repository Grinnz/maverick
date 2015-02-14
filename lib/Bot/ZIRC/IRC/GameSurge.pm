package Bot::ZIRC::IRC::GameSurge;

use Moo::Role;
use warnings NONFATAL => 'all';

with 'Bot::ZIRC::IRC';

sub irc_identify {
	my ($self, $irc) = @_;
	my $nick = $self->config->{irc}{nick};
	my $pass = $self->config->{irc}{password};
	if (defined $nick and length $nick and defined $pass and length $pass) {
		$self->("Identifying with NickServ as $nick");
		$irc->write(quote => "authserv auth $nick $pass");
	}
}

1;
