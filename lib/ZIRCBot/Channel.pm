package ZIRCBot::Channel;

use Carp;

use Moo;
use warnings NONFATAL => 'all';
use namespace::clean;

has 'name' => (
	is => 'ro',
	required => 1,
);

has 'topic' => (
	is => 'rw',
);

has 'topic_info' => (
	is => 'rw',
	lazy => 1,
	default => sub { [] },
	init_arg => undef,
);

has 'users' => (
	is => 'ro',
	lazy => 1,
	default => sub { {} },
	init_arg => undef,
	clearer => 1,
);

has 'modes' => (
	is => 'ro',
	lazy => 1,
	default => sub { {} },
	init_arg => undef,
);

sub add_user {
	my $self = shift;
	my $nick = shift // croak 'No user nick specified';
	$self->users->{lc $nick} = {};
}

sub remove_user {
	my $self = shift;
	my $nick = shift // croak 'No user nick specified';
	delete $self->users->{lc $nick};
}

sub rename_user {
	my $self = shift;
	my $from = shift // croak 'No user nick specified';
	my $to = shift // croak 'No new nick specified';
	$self->users->{lc $to} = delete $self->users->{lc $from};
}

1;

