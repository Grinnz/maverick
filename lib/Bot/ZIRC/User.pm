package Bot::ZIRC::User;

use Bot::ZIRC::Access;
use Carp;
use List::Util 'any';
use Scalar::Util 'blessed';

use Moo;
use warnings NONFATAL => 'all';
use namespace::clean;

has 'nick' => (
	is => 'rw',
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
	my $host = $self->nick // '';
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

has 'is_idle' => (
	is => 'rw',
	lazy => 1,
	default => 0,
	coerce => sub { $_[0] ? 1 : 0 },
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
	return undef unless exists $self->channels->{lc $channel};
	return $self->channels->{lc $channel}{access} // ACCESS_NONE;
}

sub bot_access {
	my $self = shift;
	my $network = $self->network;
	my $identity = $self->identity // return ACCESS_NONE;
	return ACCESS_BOT_MASTER if lc $identity eq lc ($network->config->get('users','master')//'');
	if (my @admins = split /[\s,]+/, $network->config->get('users','admin')//'') {
		return ACCESS_BOT_ADMIN if any { lc $identity eq lc $_ } @admins;
	}
	if (my @voices = split /[\s,]+/, $network->config->get('users','voice')//'') {
		return ACCESS_BOT_VOICE if any { lc $identity eq lc $_ } @voices;
	}
	return ACCESS_NONE;
}

sub check_access {
	my ($self, $required, $channel, $cb) = @_;
	
	my $nick = $self->nick;
	my $network = $self->network;
	
	$self->logger->debug("Required access is $required");
	return $self->$cb(1) if $required == ACCESS_NONE;
	
	if (defined $channel) {
		# Check for sufficient channel access
		my $channel_access = $self->channel_access($channel);
		$self->logger->debug("$nick has channel access $channel_access");
		return $self->$cb(1) if $channel_access >= $required;
	}
	
	# Check for sufficient bot access
	unless (defined $self->identity) {
		$self->logger->debug("Don't know identity of $nick; rechecking after whois");
		$network->after_whois($nick, sub {
			my ($network, $self) = @_;
			$self->$cb($self->has_bot_access($required));
		});
	}
	
	$self->$cb($self->has_bot_access($required));
}

sub has_bot_access {
	my ($self, $required) = @_;
	my $nick = $self->nick;
	
	my $bot_access = $self->bot_access;
	$self->logger->debug("$nick has bot access $bot_access");
	return $bot_access >= $required ? 1 : 0;
}

1;
