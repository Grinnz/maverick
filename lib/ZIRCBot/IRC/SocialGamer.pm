package ZIRCBot::IRC::SocialGamer;

use Moose::Role;

with 'ZIRCBot::IRC';

my @irc_events = qw/irc_320/;

around 'get_irc_events' => sub {
	my $orig = shift;
	my $self = shift;
	my @events = $self->$orig;
	push @events, @irc_events;
	return @events;
};

sub irc_320 { # RPL_WHOISIDENTIFIED
}

no Moose::Role;

1;
