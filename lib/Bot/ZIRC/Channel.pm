package Bot::ZIRC::Channel;

use Carp;
use Scalar::Util 'blessed';

use Moo;
use warnings NONFATAL => 'all';
use namespace::clean;

our @CARP_NOT = qw(Bot::ZIRC Bot::ZIRC::Network Bot::ZIRC::Command Bot::ZIRC::User Moo);

has 'name' => (
	is => 'ro',
	required => 1,
);

has 'network' => (
	is => 'ro',
	isa => sub { croak "Invalid network object"
		unless blessed $_[0] and $_[0]->isa('Bot::ZIRC::Network') },
	required => 1,
	weak_ref => 1,
	handles => [qw/logger/],
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

