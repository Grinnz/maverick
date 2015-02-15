package Bot::ZIRC::Command;

use Bot::ZIRC::Access qw/:access valid_access_level/;
use Carp;
use Scalar::Util 'blessed';

use Moo;
use warnings NONFATAL => 'all';
use namespace::clean;

our @CARP_NOT = qw(Bot::ZIRC Bot::ZIRC::Network Moo);

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
	isa => sub { croak "Invalid bot reference $_[0]"
		unless blessed $_[0] and $_[0]->isa('Bot::ZIRC') },
	weak_ref => 1,
);

# Methods

sub get_config {
	my ($self, $channel, $key) = @_;
	croak "Undefined config key" unless defined $key;
	$self->prepare_config($channel);
	my $value = $self->config->{$key};
	$self->clear_config;
	return $value;
}

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
	my ($self, $network, $sender, $channel) = @_;
	
	my $required = $self->required_access;
	$network->logger->debug("Required access is $required");
	return 1 if $required == ACCESS_NONE;
	
	my $user = $network->user($sender);
	# Check for sufficient channel access
	my $channel_access = $user->channel_access($channel);
	$network->logger->debug("$sender has channel access $channel_access");
	return 1 if $channel_access >= $required;
	
	# Check for sufficient bot access
	my $bot_access = $user->bot_access // return undef;
	$network->logger->debug("$sender has bot access $bot_access");
	return 1 if $bot_access >= $required;
	
	$network->logger->debug("$sender does not have access to run the command");
	return 0;
}

sub prepare_config {
	my ($self, $network, $channel) = @_;
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
	my ($self, $network, $sender, $channel, @args) = @_;
	$self->prepare_config($network, $channel);
	my $on_run = $self->on_run;
	local $@;
	local $SIG{__WARN__} = sub { my $msg = shift; chomp $msg; $network->logger->warn($msg) };
	eval { $self->$on_run($network, $sender, $channel, @args); 1 };
	if ($@) {
		my $err = $@;
		chomp $err;
		my $cmd_name = $self->name;
		$network->logger->error("Error running command $cmd_name: $err");
	}
	$self->clear_config;
	return $self;
}

1;
