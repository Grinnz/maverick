package Bot::ZIRC::Command;

use Carp;
use Bot::ZIRC::Access qw/:access valid_access_level/;

use Moo;
use warnings NONFATAL => 'all';
use namespace::clean;

our @CARP_NOT = qw(Bot::ZIRC Bot::ZIRC::IRC Moo);

has 'name' => (
	is => 'ro',
	isa => sub { croak "Invalid command name $_[0]"
		unless defined $_[0] and $_[0] =~ /^\w+$/ },
	required => 1,
);

has 'on_run' => (
	is => 'ro',
	isa => sub { croak "Invalid on_run subroutine $_[0]"
		unless defined $_[0] and ref $_[0] eq 'CODE' },
	required => 1,
);

has 'required_access' => (
	is => 'rw',
	isa => sub { croak "Invalid access level $_[0]"
		unless valid_access_level($_[0]) },
	lazy => 1,
	default => ACCESS_NONE,
);

has 'strip_formatting' => (
	is => 'ro',
	coerce => sub { $_[0] ? 1 : 0 },
	lazy => 1,
	default => 1,
);

has 'is_enabled' => (
	is => 'rw',
	coerce => sub { $_[0] ? 1 : 0 },
	lazy => 1,
	default => 1,
);

has 'default_config' => (
	is => 'ro',
	isa => sub { croak "Invalid config $_[0], must be a hash ref"
		unless defined $_[0] and ref $_[0] eq 'HASH' },
	lazy => 1,
	default => sub { {} },
	init_arg => 'config',
);

has 'help_text' => (
	is => 'ro',
);

# Accessors for use in on_run

has 'config' => (
	is => 'rwp',
	lazy => 1,
	default => sub { {} },
	init_arg => undef,
	clearer => 1,
);

has 'bot' => (
	is => 'rwp',
	weak_ref => 1,
);

has 'irc' => (
	is => 'rwp',
	init_arg => undef,
	clearer => 1,
);

# Methods

sub set_config {
	my ($self, $channel, $key, $value) = @_;
	croak "Undefined config key" unless defined $key;
	croak "Config value must be simple scalar" if ref $value;
	my $db_config = $self->bot->db->{commands}{$self->name}{config} //= {};
	if (defined $channel) {
		$db_config->{channel}{lc $channel}{$key} = $value;
	} else {
		$db_config->{global}{$key} = $value;
	}
	$self->bot->_store_db;
	return $self;
}

sub check_access {
	my ($self, $irc, $sender, $channel) = @_;
	my $bot = $self->bot;
	
	my $required = $self->required_access;
	$bot->logger->debug("Required access is $required");
	return 1 if $required == ACCESS_NONE;
	
	my $user = $bot->user($sender);
	# Check for sufficient channel access
	my $channel_access = $user->channel_access($channel);
	$bot->logger->debug("$sender has channel access $channel_access");
	return 1 if $channel_access >= $required;
	
	# Check for sufficient bot access
	my $bot_access = $user->bot_access // return undef;
	$bot->logger->debug("$sender has bot access $bot_access");
	return 1 if $bot_access >= $required;
	
	$bot->logger->debug("$sender does not have access to run the command");
	return 0;
}

sub prepare_config {
	my ($self, $channel) = @_;
	my $default_config = $self->default_config // {};
	my $db_config = $self->bot->db->{commands}{$self->name}{config};
	my ($bot_config, $channel_config) = ({}, {});
	if (defined $db_config) {
		$bot_config = $db_config->{global} // {};
		if (defined $channel) {
			$channel_config = $db_config->{channel}{lc $channel} // {};
		}
	}
	my %config = (%$default_config, %$bot_config, %$channel_config);
	# Config values must be simple scalars
	delete $config{$_} for grep { ref $config{$_} } keys %config;
	$self->_set_config(\%config);
	return $self;
}

sub run {
	my ($self, $irc, $sender, $channel, @args) = @_;
	$self->_set_irc($irc);
	$self->prepare_config($channel);
	my $on_run = $self->on_run;
	local $@;
	eval { $self->$on_run($sender, $channel, @args); 1 };
	if ($@) {
		my $err = $@;
		chomp $err;
		my $cmd_name = $self->name;
		warn "Error running command $cmd_name: $err\n";
	}
	$self->clear_config;
	$self->clear_irc;
	return $self;
}

1;
