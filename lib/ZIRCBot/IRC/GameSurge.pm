package ZIRCBot::IRC::GameSurge;

use Moo::Role;
use warnings NONFATAL => 'all';

with 'ZIRCBot::IRC';

sub identify {
	my $self = shift;
	my $irc = $self->irc;
	my $nick = $self->config->{irc}{nick};
	my $pass = $self->config->{irc}{password};
	if (length $nick and length $pass) {
		$irc->yield(quote => "authserv auth $nick $pass");
	}
}

1;
