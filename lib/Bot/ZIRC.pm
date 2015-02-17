package Bot::ZIRC;

use Net::DNS::Native; # load early to avoid threading issues

use Carp;
use Exporter;
use File::Spec;
use IRC::Utils;
use List::Util 'any';
use Mojo::IOLoop;
use Mojo::JSON qw/encode_json decode_json/;
use Mojo::Log;
use Scalar::Util 'blessed';
use Bot::ZIRC::Access qw/:access ACCESS_LEVELS/;
use Bot::ZIRC::Command;
use Bot::ZIRC::Config;

use Moo;
use warnings NONFATAL => 'all';
use namespace::clean;

use Exporter 'import';

our @EXPORT_OK = keys %{ACCESS_LEVELS()};
our %EXPORT_TAGS = (
	access => [keys %{ACCESS_LEVELS()}],
);

our $VERSION = '0.06';
sub bot_version { return $VERSION }

our @CARP_NOT = qw(Bot::ZIRC::Network Bot::ZIRC::Command Bot::ZIRC::User Bot::ZIRC::Channel Moo);

has 'networks' => (
	is => 'ro',
	lazy => 1,
	default => sub { {} },
);

has 'plugins' => (
	is => 'ro',
	lazy => 1,
	default => sub { {} },
);

has 'commands' => (
	is => 'ro',
	lazy => 1,
	default => sub { {} },
	init_arg => undef,
);

has 'command_prefixes' => (
	is => 'ro',
	lazy => 1,
	default => sub { {} },
	init_arg => undef,
	clearer => 1,
);

has 'command_hooks' => (
	is => 'ro',
	lazy => 1,
	default => sub { {} },
	init_arg => undef,
);

has 'init_config' => (
	is => 'ro',
	isa => sub { croak "Invalid configuration hash $_[0]"
		unless defined $_[0] and ref $_[0] eq 'HASH' },
	lazy => 1,
	default => sub { {} },
	init_arg => 'config',
);

has 'config_dir' => (
	is => 'ro',
	lazy => 1,
	coerce => sub { defined $_[0] ? $_[0] : '' },
	default => '',
);

has 'config_file' => (
	is => 'ro',
	lazy => 1,
	default => 'zirc.conf',
);

sub config_defaults {
	{
		main => {
			debug => 1,
			echo => 1,
			assert_plugins => 1,
		},
		irc => {
			server => '',
			server_pass => '',
			port => 6667,
			ssl => 0,
			realname => '',
			nick => 'ZIRCBot',
			password => '',
			away_msg => 'I am a bot. Say !help in a channel or in PM for help.',
			reconnect => 1,
		},
		users => {
			master => '',
			ircop_admin_override => 1,
		},
		channels => {
			autojoin => '',
		},
		commands => {
			prefixes => 1,
			trigger => '!',
			by_nick => 1,
		},
		apis => {},
	};
}

has 'config' => (
	is => 'lazy',
	init_arg => undef,
);

sub _build_config {
	my $self = shift;
	my $config = Bot::ZIRC::Config->new(
		dir => $self->config_dir,
		file => $self->config_file,
		defaults => $self->config_defaults,
	);
	$config->apply($self->init_config)->store if %{$self->init_config};
	return $config;
}

has 'logger' => (
	is => 'lazy',
	init_arg => undef,
	clearer => 1,
);

sub _build_logger {
	my $self = shift;
	my $path = $self->config->get('logfile') || undef;
	my $logger = Mojo::Log->new(path => $path);
	$logger->level('info') unless $self->config->get('debug');
	return $logger;
}

has 'is_stopping' => (
	is => 'rw',
	lazy => 1,
	coerce => sub { $_[0] ? 1 : 0 },
	default => 0,
	init_arg => undef,
);

sub BUILD {
	my $self = shift;
	
	my $networks = $self->networks;
	croak "Networks must be specified as a hash reference"
		unless ref $networks eq 'HASH';
	croak "No networks have been specified" unless keys %$networks;
	$self->add_network($_ => delete $networks->{$_}) for keys %$networks;
	
	my $plugins = $self->plugins;
	%$plugins = map { ($_ => 1) } @$plugins if ref $plugins eq 'ARRAY';
	croak "Plugins must be specified as a hash or array reference"
		unless ref $plugins eq 'HASH';
	$plugins->{Core} //= 1;
	foreach my $plugin_class (keys %$plugins) {
		my $args = delete $plugins->{$plugin_class};
		$self->register_plugin($plugin_class => $args) if $args;
	}
}

# Networks

sub get_network_names {
	my $self = shift;
	return keys %{$self->networks};
}

sub add_network {
	my ($self, $name, $config) = @_;
	croak "Network name is unspecified" unless defined $name;
	croak "Network name $name contains invalid characters" unless $name =~ /^[-.\w]+$/;
	croak "Network $name already exists" if exists $self->networks->{$name};
	croak "Invalid configuration for network $name" unless ref $config eq 'HASH';
	my $class = delete $config->{class} // 'Bot::ZIRC::Network';
	$class = "Bot::ZIRC::Network::$class" unless $class =~ /::/;
	local $@;
	eval "require $class; 1" or croak $@;
	$self->networks->{$name} = $class->new(name => $name, bot => $self, config => $config);
	return $self;
}

# Plugins

sub get_plugin_classes {
	my $self = shift;
	return keys %{$self->plugins};
}

sub has_plugin {
	my ($self, $class) = @_;
	return undef unless defined $class;
	return exists $self->plugins->{$class};
}

sub get_plugin {
	my ($self, $class) = @_;
	return undef unless defined $class and exists $self->plugins->{$class};
	return $self->plugins->{$class};
}

sub register_plugin {
	my ($self, $class, $config) = @_;
	croak "Plugin class not defined" unless defined $class;
	$class = "Bot::ZIRC::Plugin::$class" unless $class =~ /::/;
	return $self if $self->has_plugin($class);
	local $@;
	my $plugin = eval {
		eval "require $class; 1" or die $@;
		require Role::Tiny;
		die "$class does not do role Bot::ZIRC::Plugin\n"
			unless Role::Tiny::does_role($class, 'Bot::ZIRC::Plugin');
		my $plugin = $class->new;
		$plugin->register($self, $config);
		return $plugin;
	};
	if ($@) {
		my $err = $@;
		if ($self->config->get('assert_plugins')) {
			die "Plugin $class could not be registered: $err";
		} else {
			warn "Plugin $class could not be registered: $err";
			return $self;
		}
	}
	$self->plugins->{$class} = $plugin;
	return $self;
}

# Commands

sub get_command_names {
	my $self = shift;
	return keys %{$self->commands};
}

sub get_command {
	my ($self, $name) = @_;
	return undef unless defined $name and exists $self->commands->{lc $name};
	return $self->commands->{lc $name};
}

sub get_commands_by_prefix {
	my ($self, $prefix) = @_;
	return [] unless defined $prefix and exists $self->command_prefixes->{lc $prefix};
	return $self->command_prefixes->{lc $prefix};
}

sub add_command {
	my $self = shift;
	my $command;
	if (blessed $_[0] and $_[0]->isa('Bot::ZIRC::Command')) {
		$command = shift;
		$command->_set_bot($self);
	} elsif (!ref $_[0] or ref $_[0] eq 'HASH') {
		my %params = ref $_[0] eq 'HASH' ? %{$_[0]} : @_;
		$command = Bot::ZIRC::Command->new(%params, bot => $self);
	} else {
		croak "$_[0] is not a Bot::ZIRC::Command object";
	}
	my $name = $command->name;
	croak "Command $name already exists" if exists $self->commands->{lc $name};
	$self->commands->{lc $name} = $command;
	$self->add_command_prefixes($name);
	return $self;
}

sub add_command_prefixes {
	my ($self, $name) = @_;
	croak "Command name not defined" unless defined $name;
	$name = lc $name;
	foreach my $len (1..length $name) {
		my $prefix = substr $name, 0, $len;
		my $prefixes = $self->command_prefixes->{$prefix} //= [];
		push @$prefixes, $name;
	}
	return $self;
}

sub reload_command_prefixes {
	my $self = shift;
	$self->clear_command_prefixes;
	$self->add_command_prefixes($_) for $self->get_command_names;
}

sub add_command_hook_before {
	my ($self, $cb) = @_;
	croak "Invalid before-command hook $cb" unless ref $cb eq 'CODE';
	my $before_hooks = $self->command_hooks->{before} //= [];
	push @$before_hooks, $cb;
}

sub add_command_hook_after {
	my ($self, $cb) = @_;
	croak "Invalid after-command hook $cb" unless ref $cb eq 'CODE';
	my $after_hooks = $self->command_hooks->{after} //= [];
	push @$after_hooks, $cb;
}

# Bot actions

sub start {
	my $self = shift;
	$self->logger->debug("Starting bot");
	$self->is_stopping(0);
	$SIG{INT} = $SIG{TERM} = $SIG{QUIT} = sub { $self->sig_stop(@_) };
	$SIG{HUP} = $SIG{USR1} = $SIG{USR2} = sub { $self->sig_reload(@_) };
	$SIG{__WARN__} = sub { my $msg = shift; chomp $msg; $self->logger->warn($msg) };
	$_->start for values %{$self->networks};
	$_->start for values %{$self->plugins};
	Mojo::IOLoop->start unless Mojo::IOLoop->is_running;
	return $self;
}

sub stop {
	my ($self, $message) = @_;
	$self->logger->debug("Stopping bot");
	$self->is_stopping(1);
	$_->stop for values %{$self->plugins};
	Mojo::IOLoop->delay(sub {
		my $delay = shift;
		$_->stop($message, $delay->begin) for values %{$self->networks};
	}, sub { Mojo::IOLoop->stop });
	return $self;
}

sub reload {
	my $self = shift;
	$self->clear_logger;
	$self->logger->debug("Reloading bot");
	$self->config->reload;
	$_->reload for values %{$self->networks};
	$_->reload for values %{$self->plugins};
	return $self;
}

sub sig_stop {
	my ($self, $signal) = @_;
	$self->logger->debug("Received signal SIG$signal, stopping");
	$self->stop;
}

sub sig_reload {
	my ($self, $signal) = @_;
	$self->logger->debug("Received signal SIG$signal, reloading");
	$self->reload;
}

1;
