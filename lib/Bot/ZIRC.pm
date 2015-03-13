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
use Mojo::UserAgent;
use Scalar::Util 'blessed';
use Bot::ZIRC::Access qw/:access ACCESS_LEVELS/;
use Bot::ZIRC::Command;
use Bot::ZIRC::Config;
use Bot::ZIRC::Storage;

use Moo;
use namespace::clean;

use Exporter 'import';

our $AUTOLOAD;

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
	is => 'rwp',
	lazy => 1,
	default => sub { {} },
);

has 'plugin_methods' => (
	is => 'ro',
	lazy => 1,
	default => sub { {} },
	init_arg => undef,
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

has 'hooks' => (
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
			ignore_bots => 1,
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

has 'storage_file' => (
	is => 'ro',
	lazy => 1,
	default => 'zirc.json',
);

has 'storage' => (
	is => 'lazy',
	init_arg => undef,
);

sub _build_storage {
	my $self = shift;
	my $storage = Bot::ZIRC::Storage->new(
		dir => $self->config_dir,
		file => $self->storage_file,
	);
	return $storage;
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

has 'ua' => (
	is => 'ro',
	lazy => 1,
	default => sub { Mojo::UserAgent->new },
	init_arg => undef,
);

has 'is_stopping' => (
	is => 'rw',
	lazy => 1,
	coerce => sub { $_[0] ? 1 : 0 },
	default => 0,
	init_arg => undef,
);

has 'watch_timer' => (
	is => 'rwp',
	predicate => 1,
	clearer => 1,
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
	$self->_set_plugins({map { ($_ => 1) } @$plugins}) if ref $plugins eq 'ARRAY';
	$plugins = $self->plugins;
	croak "Plugins must be specified as a hash or array reference"
		unless ref $plugins eq 'HASH';
	$plugins->{Core} //= 1;
	foreach my $plugin_class (keys %$plugins) {
		my $args = delete $plugins->{$plugin_class};
		$self->register_plugin($plugin_class => $args) if $args;
	}
	$self->check_required_methods;
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
	my $config_file = $self->config_file;
	$config_file =~ s/(.+)\.conf/$1-$name.conf/
		or $config_file .= "-$name";
	$self->networks->{$name} = $class->new(name => $name, bot => $self, config => $config, config_file => $config_file);
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
	my ($self, $class, $params) = @_;
	croak "Plugin class not defined" unless defined $class;
	$class = "Bot::ZIRC::Plugin::$class" unless $class =~ /::/;
	return $self if $self->has_plugin($class);
	$self->plugins->{$class} = undef; # Avoid circular dependency issues
	local $@;
	my $plugin = eval {
		eval "require $class; 1" or die $@;
		require Role::Tiny;
		die "$class does not do role Bot::ZIRC::Plugin\n"
			unless Role::Tiny::does_role($class, 'Bot::ZIRC::Plugin');
		my @params = ref $params eq 'HASH' ? %$params : ();
		my $plugin = $class->new(@params, bot => $self);
		$plugin->register($self);
		return $plugin;
	};
	if ($@) {
		my $err = $@;
		delete $self->plugins->{$class};
		croak "Plugin $class could not be registered: $err";
	}
	$self->plugins->{$class} = $plugin;
	return $self;
}

sub has_plugin_method {
	my ($self, $method) = @_;
	croak "Unspecified plugin method" unless defined $method;
	return exists $self->plugin_methods->{$method}
		or !!$self->can($method);
}

sub check_required_methods {
	my $self = shift;
	foreach my $class ($self->get_plugin_classes) {
		my $plugin = $self->get_plugin($class);
		foreach my $method ($plugin->require_methods) {
			die "Plugin $class requires method $method but it has not been loaded\n"
				unless $self->has_plugin_method($method);
		}
	}
	return $self;
}

sub add_plugin_method {
	my ($self, $plugin, $method) = @_;
	my $class = blessed $plugin // croak "Invalid plugin $plugin";
	croak "Invalid plugin method $method"
		unless defined $method and length $method and !ref $method;
	croak "Method $method already exists"
		if exists $self->plugin_methods->{$method} or $self->can($method);
	croak "Method $method is not implemented by plugin $class"
		unless $plugin->can($method);
	$self->plugin_methods->{$method} = $class;
	return $self;
}

# Autoload plugin methods
sub AUTOLOAD {
	my $self = shift;
	my $method = $AUTOLOAD;
	$method =~ s/.*:://;
	unless (ref $self and exists $self->plugin_methods->{$method}) {
		# Emulate standard missing method error
		my ($package, $method) = $AUTOLOAD =~ /^(.*)::([^:]*)/;
		die sprintf qq(Can't locate object method "%s" via package "%s" at %s line %d.\n),
			$method, $package, (caller)[1,2];
	}
	my $class = $self->plugin_methods->{$method};
	my $plugin = $self->get_plugin($class) // croak "Plugin $class is not loaded";
	my $sub = $plugin->can($method)
		// croak "Plugin $class does not implement method $method";
	unshift @_, $plugin;
	goto &$sub;
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

# Hooks

sub get_hooks {
	my ($self, $type) = @_;
	return [] unless defined $type;
	return $self->hooks->{$type} // [];
}

sub add_hook {
	my ($self, $type, $cb) = @_;
	croak "Unspecified hook type" unless defined $type;
	croak "Invalid hook callback $cb" unless ref $cb eq 'CODE';
	push @{$self->hooks->{$type}//=[]}, $cb;
	return $self;
}

sub add_hook_before_command { $_[0]->add_hook(before_command => $_[1]) }
sub add_hook_after_command { $_[0]->add_hook(after_command => $_[1]) }
sub add_hook_privmsg { $_[0]->add_hook(privmsg => $_[1]) }

# Bot actions

sub start {
	my $self = shift;
	$self->logger->debug("Starting bot");
	$self->is_stopping(0);
	$SIG{INT} = $SIG{TERM} = $SIG{QUIT} = sub { $self->sig_stop(@_) };
	$SIG{HUP} = $SIG{USR1} = $SIG{USR2} = sub { $self->sig_reload(@_) };
	$SIG{__WARN__} = sub { my $msg = shift; chomp $msg; $self->logger->warn($msg) };
	
	$_->start for values %{$self->networks}, values %{$self->plugins};
	
	# Make sure perl signals are caught in a timely fashion
	$self->_set_watch_timer(Mojo::IOLoop->recurring(1 => sub {}))
		unless $self->has_watch_timer;
	Mojo::IOLoop->start unless Mojo::IOLoop->is_running;
	return $self;
}

sub stop {
	my ($self, $message) = @_;
	$self->logger->debug("Stopping bot");
	$self->is_stopping(1);
	Mojo::IOLoop->remove($self->watch_timer) if $self->has_watch_timer;
	$self->clear_watch_timer;
	
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
	$_->reload for values %{$self->networks}, values %{$self->plugins};
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
