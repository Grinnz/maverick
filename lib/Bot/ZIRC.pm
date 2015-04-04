package Bot::ZIRC;

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

our $VERSION = '0.10';
sub bot_version { return $VERSION }

our @CARP_NOT = qw(Bot::ZIRC::Network Bot::ZIRC::Command Bot::ZIRC::User Bot::ZIRC::Channel Moo);

has 'name' => (
	is => 'ro',
	isa => sub { croak "Invalid bot name $_[0]"
		unless defined $_[0] and IRC::Utils::is_valid_nick_name $_[0] },
	lazy => 1,
	default => 'ZIRC',
);

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
	default => sub { lc($_[0]->name) . '.conf' },
);

has 'config' => (
	is => 'lazy',
	init_arg => undef,
);

sub _build_config {
	my $self = shift;
	my $config = Bot::ZIRC::Config->new(
		dir => $self->config_dir,
		file => $self->config_file,
		defaults => $self->_config_defaults,
	);
	$config->apply($self->init_config)->store if %{$self->init_config};
	return $config;
}

has 'storage_file' => (
	is => 'ro',
	lazy => 1,
	default => sub { lc($_[0]->name) . '.db' },
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
		die "$class is not a Bot::ZIRC::Plugin\n"
			unless "$class"->isa('Bot::ZIRC::Plugin');
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
	} elsif (!ref $_[0] or ref $_[0] eq 'HASH') {
		my %params = ref $_[0] eq 'HASH' ? %{$_[0]} : @_;
		$command = Bot::ZIRC::Command->new(%params);
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

sub _config_defaults {
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

1;

=head1 NAME

Bot::ZIRC - Mojo::IRC Bot framework

=head1 SYNOPSIS

  use Bot::ZIRC;
  
  my $bot = Bot::ZIRC->new(
    name => 'MyIRCBot',
    networks => {
      freenode => {
        class => 'Freenode',
        irc => { server => 'chat.freenode.net' },
      },
    },
  );
  
  $bot->start;

=head1 DESCRIPTION

L<Bot::ZIRC> is an IRC bot framework built on L<Mojo::IRC> that supports
connecting to multiple networks and is designed to be configurable and
customizable via plugins. A core set of plugins is included from
L<Bot::ZIRC::Plugin::Core> which includes basic administrative and
configuration commands, and additional plugins can be registered that may
implement any functionality from adding more commands to hooking into message
events and more.

=head1 CONFIGURATION

L<Bot::ZIRC> is configured by INI files: one global configuration file and a
network configuration file for each network it connects to. The global
configuration file is used as a default configuration for each network. Any
configuration specified in the constructor or when adding a network will be
written to the configuration files, overriding existing configuration.

Configuration INI files are organized into sections; the C<[main]> section is
the default for any configuration not in a section.

=head2 main

=head2 irc

=head2 network

=head2 channels

=head2 users

=head2 commands

=head2 apis

=head1 NETWORKS

IRC networks are represented by L<Bot::ZIRC::Network> (or subclassed) objects
that handle all communication with that network. Networks can be specified in
the bot's constructor, or added later with the L</"add_network"> method. The
network object is provided to command and hook callbacks and can be used to
send responses or perform actions.

=head1 PLUGINS

Plugins are L<Moo> objects that subclass L<Bot::ZIRC::Plugin>. They are
registered by calling the required method C<register> and may add commands,
hooks, or anything else to the bot instance. A plugin may also register a
method of its own as a "plugin method" which then can be called on the bot
instance from elsewhere. Plugin objects are stored in the bot instance and are
passed as the invocant of plugin methods called on the bot.

=head1 COMMANDS

Commands are represented by L<Bot::ZIRC::Command> objects which define the
properties of the command and a callback "on_run" that is called when the
command is invoked by a IRC user.

=head1 HOOKS

Hooks are subroutines which are run whenever a specific action occurs. They are
a powerful way to add global functionality.

=head2 privmsg

  $bot->add_hook(privmsg => sub { my ($network, $sender, $channel, $message) = @_; ... });

The C<privmsg> hook is called whenever the bot receives a channel or private
message ("privmsg") from an IRC user. The callback will receive the appropriate
L<Bot::ZIRC::Network> object, the sender as a L<Bot::ZIRC::User> object, the
channel as a L<Bot::ZIRC::Channel> object (or undefined for private messages),
and the message string.

=head2 before_command

  $bot->add_hook(before_command => sub { my ($command, $network, $sender, $channel, @args) = @_; ... });

The C<before_command> hook is called before a recognized command is executed.
The callback will receive the L<Bot::ZIRC::Command> object, the appropriate
L<Bot::ZIRC::Network> object, the sender as a L<Bot::ZIRC::User> object, the
channel as a L<Bot::ZIRC::Channel> object (or undefined for private messages),
and the command arguments as they will be received by the command.

=head2 after_command

  $bot->add_hook(after_command => sub { my ($command, $network, $sender, $channel, @args) = @_; ... });

The C<after_command> hook is called after a command has been executed. The
callback will receive the L<Bot::ZIRC::Command> object, the appropriate
L<Bot::ZIRC::Network> object, the sender as a L<Bot::ZIRC::User> object, the
channel as a L<Bot::ZIRC::Channel> object (or undefined for private messages),
and the command arguments as they were received by the command.

=head1 METHODS

=head2 new

Constructs a new L<Bot::ZIRC> object instance. Accepts values for the following
attributes:

=over

=item name

  name => 'Botzilla',

Name for the bot, defaults to C<ZIRC>. The bot's name is used as a default nick
for networks where it is not configured, as well as lowercased for the default
filenames for configuration and other files. For example, a bot named C<Fred>
will (by default) use the configuration file C<fred.conf>, network
configuration files C<fred-E<lt>networkE<gt>.conf>, and database file
C<fred.db>.

=item networks

  networks => { freenode => { class => 'Freenode', debug => 1 } },

Hash reference that must contain at least one network to connect to. Keys are
names which will be used to identify the network as well as lowercased to
define the default network configuration filename. Values are hash references
containing an optional object C<class> (defaults to L<Bot::ZIRC::Network>) and
configuration for the network. The C<class> will be appended to
C<Bot::ZIRC::Network::> if it does not contain C<::>.

=item plugins

  plugins => [qw/DNS GeoIP/],
  plugins => { Core => 0, DNS => { native => 0 }, GeoIP => 1 },

Plugins to register with the bot, specified as plugin class names, which are
appended to C<Bot::ZIRC::Plugin::> if they do not contain C<::>. May be
specified as an array reference to simply include the list of plugins, or as a
hash reference to configure the registration of plugins. If the hash value is
false, the plugin will be not be registered; otherwise, the value will be
passed to the plugin's C<register> method. See L<Bot::ZIRC::Plugin> for
documentation on ZIRC plugins.

=item config

  config => { debug => 1, irc => { nick => 'OtherGuy' } },

Global configuration that will override any defaults or existing global
configuration file. To override configuration for a specific network, see the
C<networks> attribute.

=item config_dir

  config_dir => "$HOME/.mybot",

Directory to store configuration and other files. Defaults to current
directory.

=item config_file

  config_file => 'myconfig.conf',

Filename for main configuration file. Defaults to bot's name, lowercased and
appended with C<.conf>. Network configuration filenames default to bot's name,
lowercased and appended with lowercased C<-E<lt>networkE<gt>.conf>.

=item storage_file

  storage_file => 'mystuff.db',

Filename for database storage file. Defaults to bot's name, lowercased and
appended with C<.db>.

=item logger

  logger => Mojo::Log->new('/var/log/botstuff.log')->level('warn'),

Logger object that will be used for all debug, informational and warning
output. Can be any type of logger that has C<debug>, C<info>, C<warn>,
C<error>, and C<fatal> methods, such as L<Mojo::Log>. Defaults to logging to
the file specified by the configuration C<logfile>, or STDERR otherwise.

=back

=head2 start

Start the bot and connect to configured networks. Blocks until the bot is told
to stop.

=head2 stop

Disconnect from all networks and stop the bot.

=head2 reload

Reloads configuration and reopens log handles.

=head2 get_network_names

  my @names = $bot->get_network_names;

Returns a list of all configured network names.

=head2 add_network

  $bot = $bot->add_network(freenode => { class => 'Freenode' });

Adds a network for the bot to connect to. See L</"NETWORKS">.

=head2 get_plugin_classes

  my @classes = $bot->get_plugin_classes;

Returns a list of all registered plugin classes.

=head2 has_plugin

  my $bool = $bot->has_plugin('DNS');

Returns a boolean value that is true if the plugin has been registered.

=head2 get_plugin

  my $plugin = $bot->get_plugin('DNS');

Returns the plugin object if it has been registered, or C<undef> otherwise.

=head2 register_plugin

  $bot = $bot->register_plugin(DNS => { native => 0 });

Registers a plugin with optional hashref of parameters to pass to the plugin's
C<register> method. See L</"PLUGINS">.

=head2 add_plugin_method

  $bot = $bot->add_plugin_method(DNS => 'dns_resolve');

Adds a plugin method to the bot, so that it may be called on the bot via
L</"AUTOLOAD">.

=head2 has_plugin_method

  my $bool = $bot->has_plugin_method('dns_resolve');

Returns a boolean value that is true if the specified plugin method is
available.

=head2 get_command_names

  my @names = $bot->get_command_names;

Returns a list of all commands.

=head2 get_command

  my $command = $bot->get_command('say');

Returns the L<Bot::ZIRC::Command> object representing the command, or C<undef>
if the command does not exist.

=head2 add_command

  $bot = $bot->add_command(Bot::ZIRC::Command->new(...));
  $bot = $bot->add_command(...);

Adds a L<Bot::ZIRC::Command> to the bot, or passes the arguments to construct a
new L<Bot::ZIRC::Command> and add it to the bot. See L</"COMMANDS">.

=head2 add_hook

  $bot = $bot->add_hook(privmsg => sub { warn $_[1] });

Adds a hook to be executed when a certain event occurs. See L</"HOOKS">.

=head1 BUGS

Report any issues on the public bugtracker.

=head1 AUTHOR

Dan Book, C<dbook@cpan.org>

=head1 COPYRIGHT AND LICENSE

Copyright 2015, Dan Book.

This library is free software; you may redistribute it and/or modify it under
the terms of the Artistic License version 2.0.

=head1 SEE ALSO

L<Bot::ZIRC::Network>, L<Bot::ZIRC::Plugin>, L<Mojo::IRC>
