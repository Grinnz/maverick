package ZIRCBot::IRC::SocialGamer;

use Moo::Role;
use warnings NONFATAL => 'all';

with 'ZIRCBot::IRC';

my @irc_events = qw/irc_320/;

around 'get_irc_events' => sub {
	my $orig = shift;
	my $self = shift;
	return ($self->$orig, @irc_events);
};

sub irc_320 { # RPL_WHOISIDENTIFIED
}

1;
