package Bot::Maverick::Channel;

use Carp;
use Scalar::Util 'blessed';

use Moo;
use namespace::clean;

use overload 'cmp' => sub { $_[2] ? lc $_[1] cmp lc $_[0] : lc $_[0] cmp lc $_[1] },
	'""' => sub { shift->name }, bool => sub {1}, fallback => 1;

our @CARP_NOT = qw(Bot::Maverick Bot::Maverick::Network Bot::Maverick::Command Bot::Maverick::User Moo);

our $VERSION = '0.20';

has 'name' => (
	is => 'ro',
	isa => sub { croak "Unspecified channel name" unless defined $_[0] },
	required => 1,
);

has 'network' => (
	is => 'ro',
	isa => sub { croak "Invalid network object"
		unless blessed $_[0] and $_[0]->isa('Bot::Maverick::Network') },
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

=head1 NAME

Bot::Maverick::Channel - Channel class for Maverick

=head1 SYNOPSIS

  my $channel = Bot::Maverick::Channel->new(name => '#bots', network => $network);

=head1 DESCRIPTION

Represents the current state of an IRC channel for a L<Bot::Maverick> IRC bot.

=head1 ATTRIBUTES

=head2 name

Channel name. Must be set in constructor.

=head2 network

Weakened reference to the channel's L<Bot::Maverick::Network> object.

=head2 topic

Channel topic.

=head2 topic_info

Array reference containing extra topic info.

=head2 users

Hash reference of user nicks currently in channel.

=head2 modes

Hash reference of modes currently set on channel.

=head1 METHODS

=head2 add_user

  $channel->add_user($nick);

Adds a user nick to channel.

=head2 remove_user

  $channel->remove_user($nick);

Removes a user nick from channel if present.

=head2 rename_user

  $channel->rename_user($from => $to);

Renames a user nick if currently in channel.

=head1 BUGS

Report any issues on the public bugtracker.

=head1 AUTHOR

Dan Book, C<dbook@cpan.org>

=head1 COPYRIGHT AND LICENSE

Copyright 2015, Dan Book.

This library is free software; you may redistribute it and/or modify it under
the terms of the Artistic License version 2.0.

=head1 SEE ALSO

L<Bot::Maverick>, L<Bot::Maverick::Network>
