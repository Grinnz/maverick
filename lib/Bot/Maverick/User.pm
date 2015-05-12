package Bot::Maverick::User;

use Bot::Maverick::Access;
use Carp;
use List::Util 'any';
use Scalar::Util 'blessed';

use Moo;
use namespace::clean;

use overload 'cmp' => sub { $_[2] ? lc $_[1] cmp lc $_[0] : lc $_[0] cmp lc $_[1] },
	'""' => sub { shift->nick }, bool => sub {1}, fallback => 1;

our @CARP_NOT = qw(Bot::Maverick Bot::Maverick::Network Bot::Maverick::Command Bot::Maverick::Channel Moo);

our $VERSION = '0.20';

has 'nick' => (
	is => 'rw',
	isa => sub { croak "Unspecified user nick" unless defined $_[0] },
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

has 'host' => (
	is => 'rw',
);

has 'username' => (
	is => 'rw',
);

has 'realname' => (
	is => 'rw',
);

sub hostmask {
	my $self = shift;
	my $nick = $self->nick // '';
	my $username = $self->username // '';
	my $host = $self->host // '';
	return "$nick!$username\@$host";
}

sub banmask {
	my $self = shift;
	my $host = $self->host // '';
	return "*!*\@$host";
}

has 'is_away' => (
	is => 'rw',
	lazy => 1,
	default => 0,
	coerce => sub { $_[0] ? 1 : 0 },
	init_arg => undef,
	clearer => 1,
);

has 'away_message' => (
	is => 'rw',
	init_arg => undef,
	clearer => 1,
);

has 'is_registered' => (
	is => 'rw',
	lazy => 1,
	default => 0,
	coerce => sub { $_[0] ? 1 : 0 },
	init_arg => undef,
	clearer => 1,
);

has 'identity' => (
	is => 'rw',
	init_arg => undef,
	trigger => sub { $_[0]->is_registered(defined $_[1]) },
	predicate => 1,
	clearer => 1,
);

has 'is_bot' => (
	is => 'rw',
	lazy => 1,
	default => 0,
	coerce => sub { $_[0] ? 1 : 0 },
	init_arg => undef,
	clearer => 1,
);

has 'is_ircop' => (
	is => 'rw',
	lazy => 1,
	default => 0,
	coerce => sub { $_[0] ? 1 : 0 },
	init_arg => undef,
	clearer => 1,
);

has 'ircop_message' => (
	is => 'rw',
	init_arg => undef,
	clearer => 1,
);

has 'idle_time' => (
	is => 'rw',
	init_arg => undef,
	clearer => 1,
);

has 'signon_time' => (
	is => 'rw',
	init_arg => undef,
	clearer => 1,
);

has 'channels' => (
	is => 'ro',
	lazy => 1,
	default => sub { {} },
	init_arg => undef,
	clearer => 1,
);

sub add_channel {
	my $self = shift;
	my $channel = shift // croak 'No channel name provided';
	$self->channels->{lc $channel} = {};
}

sub remove_channel {
	my $self = shift;
	my $channel = shift // croak 'No channel name provided';
	delete $self->channels->{lc $channel};
}

sub channel_access {
	my $self = shift;
	my $channel = shift // croak 'No channel name provided';
	if (@_) {
		$self->channels->{lc $channel}{access} = shift;
	}
	return ACCESS_NONE unless exists $self->channels->{lc $channel};
	return $self->channels->{lc $channel}{access} // ACCESS_NONE;
}

sub bot_access {
	my $self = shift;
	my $network = $self->network;
	my $identity = $self->identity // return ACCESS_NONE;
	return ACCESS_BOT_MASTER if lc $identity eq lc $network->master_user;
	return ACCESS_BOT_ADMIN if $self->is_ircop
		and $network->config->get('users','ircop_admin_override');
	return ACCESS_BOT_ADMIN if any { lc $identity eq lc $_ } $network->admin_users;
	return ACCESS_BOT_VOICE if any { lc $identity eq lc $_ } $network->voice_users;
	return ACCESS_NONE;
}

sub check_access {
	my $self = shift;
	my $cb = pop // croak "No callback specified for check_access";
	my $required = shift // return $self->$cb(0);
	my $channel = shift;
	
	my $network = $self->network;
	
	$self->logger->debug("Required access is $required");
	return $self->$cb(1) if $required == ACCESS_NONE;
	
	if (defined $channel) {
		# Check for sufficient channel access
		my $channel_access = $self->channel_access($channel);
		$self->logger->debug("$self has channel access $channel_access");
		return $self->$cb(1) if $channel_access >= $required;
	}
	
	# Check for sufficient bot access
	unless (defined $self->identity or $self->has_bot_access($required)) {
		$self->logger->debug("Rechecking access for $self after whois");
		return $network->after_whois($self->nick, sub {
			my ($network, $self) = @_;
			$self->$cb($self->has_bot_access($required));
		});
	}
	
	$self->$cb($self->has_bot_access($required));
}

sub has_bot_access {
	my ($self, $required) = @_;
	
	my $bot_access = $self->bot_access;
	$self->logger->debug("$self has bot access $bot_access");
	return $bot_access >= $required ? 1 : 0;
}

1;

=head1 NAME

Bot::Maverick::User - User class for Maverick

=head1 SYNOPSIS

  my $user = Bot::Maverick::User->new(nick => $nick, network => $network);
  if ($user->check_access(ACCESS_CHANNEL_ADMIN, $channel)) {
    say "User has admin access in $channel";
  }

=head1 DESCRIPTION

Represents the current state of an IRC user for a L<Bot::Maverick> IRC bot.

=head1 ATTRIBUTES

=head2 nick

User nick, required.

=head2 network

Weakened reference to the user's L<Bot::Maverick::Network> object.

=head2 host

=head2 username

=head2 realname

=head2 is_away

=head2 away_message

=head2 is_registered

=head2 identity

=head2 is_bot

=head2 is_ircop

=head2 ircop_message

=head2 idle_time

=head2 signon_time

=head2 channels

=head1 METHODS

=head2 hostmask

Returns the user's full hostmask, as C<nick!username@host>.

=head2 banmask

Returns a banmask for the user, as C<*!*@host>.

=head2 channel_access

Set or get user's access level in a channel.

=head2 bot_access

Returns user's bot access level.

=head2 check_access

Returns a boolean whether the user has the specified access level, with an
optional channel name to check channel access.

=head2 has_bot_access

Returns a boolean whether the user has the specified bot access level.

=head1 BUGS

Report any issues on the public bugtracker.

=head1 AUTHOR

Dan Book, C<dbook@cpan.org>

=head1 COPYRIGHT AND LICENSE

Copyright 2015, Dan Book.

This library is free software; you may redistribute it and/or modify it under
the terms of the Artistic License version 2.0.

=head1 SEE ALSO

L<Bot::Maverick>, L<Bot::Maverick::Network>, L<Bot::Maverick::Access>
