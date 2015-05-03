package Bot::ZIRC::Network::SocialGamer;

use Moo;
use namespace::clean;

extends 'Bot::ZIRC::Network';

our $VERSION = '0.20';

my @irc_events = qw/irc_320/;

around 'get_irc_events' => sub {
	my $orig = shift;
	my $self = shift;
	return ($self->$orig, @irc_events);
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
