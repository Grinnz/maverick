package Bot::Maverick::Network::Libera;

use Moo;
use namespace::clean;

extends 'Bot::Maverick::Network';

our $VERSION = '0.50';

after '_irc_rpl_whoreply' => sub {
	my ($self, $message) = @_;
	my ($to, $channel, $username, $host, $server, $nick, $state, $realname) = @{$message->{params}};
	if ($host =~ m!/bot/!) {
		$self->logger->debug("Received /bot/ hostmask for $nick");
		$self->user($nick)->is_bot(1);
	}
};

after '_irc_rpl_whoisuser' => sub {
	my ($self, $message) = @_;
	my ($to, $nick, $username, $host, $star, $realname) = @{$message->{params}};
	if ($host =~ m!/bot/!) {
		$self->logger->debug("Received /bot/ hostmask for $nick");
		$self->user($nick)->is_bot(1);
	}
};

1;
