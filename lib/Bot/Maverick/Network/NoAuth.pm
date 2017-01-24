package Bot::Maverick::Network::NoAuth;

use Moo;
use namespace::clean;

extends 'Bot::Maverick::Network';

our $VERSION = '0.50';

sub identify {}

around 'user' => sub {
	my $orig = shift;
	my $user = $orig->(@_);
	$user->is_registered(1);
	$user->identity($user->nick);
	return $user;
};

1;
