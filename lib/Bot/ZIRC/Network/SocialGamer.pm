package Bot::ZIRC::Network::SocialGamer;

use Moo;
use warnings NONFATAL => 'all';
use namespace::clean;

extends 'Bot::ZIRC::Network';

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
		my $user = $self->user($nick);
		$user->is_registered(1);
		$user->identity($identity);
		$user->bot_access($self->user_access_level($identity));
	}
}

1;
