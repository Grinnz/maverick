package Bot::Maverick;

use Try::Tiny;

# Use JSON::MaybeXS for JSON API processing if available
BEGIN { try { require Mojo::JSON::MaybeXS } }

use Carp;
use IRC::Utils;
use Future::Mojo;
use List::Util 'any';
use Module::Runtime 'use_module';
use Mojo::File 'curfile';
use Mojo::IOLoop;
use Mojo::IOLoop::Subprocess::Sereal;
use Mojo::Log;
use Mojo::UserAgent;
use Scalar::Util qw(blessed weaken);
use Bot::Maverick::Access qw/:access ACCESS_LEVELS/;
use Bot::Maverick::Command;
use Bot::Maverick::Config;
use Bot::Maverick::Storage;

use Moo;
use namespace::clean;

use Autoload::AUTOCAN;
use Exporter 'import';

with 'Role::EventEmitter';

our @EXPORT_OK = keys %{ACCESS_LEVELS()};
our %EXPORT_TAGS = (
	access => [keys %{ACCESS_LEVELS()}],
);

our $VERSION = '0.50';
sub bot_version { return $VERSION }

our @CARP_NOT = qw(Bot::Maverick::Network Bot::Maverick::Command Bot::Maverick::User Bot::Maverick::Channel Moo);

sub _config_defaults {
	{
		main => {
			debug => 0,
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

has 'name' => (
	is => 'ro',
	isa => sub { croak "Invalid bot name $_[0]"
		unless defined $_[0] and IRC::Utils::is_valid_nick_name $_[0] },
	lazy => 1,
	default => 'Maverick',
);

has 'networks' => (
	is => 'ro',
	lazy => 1,
	default => sub { {} },
);

has '_init_plugins' => (
	is => 'ro',
	lazy => 1,
	default => sub { {} },
	clearer => 1,
	init_arg => 'plugins',
);

has 'helpers' => (
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

has '_command_prefixes' => (
	is => 'ro',
	lazy => 1,
	default => sub { {} },
	init_arg => undef,
);

has 'handlers' => (
	is => 'ro',
	lazy => 1,
	default => sub { [] },
	init_arg => undef,
);

has '_init_config' => (
	is => 'ro',
	isa => sub { croak "Invalid configuration hash $_[0]"
		unless defined $_[0] and ref $_[0] eq 'HASH' },
	predicate => 1,
	clearer => 1,
	init_arg => 'config',
);

has 'config_dir' => (
	is => 'ro',
	lazy => 1,
	coerce => sub { defined $_[0] ? $_[0] : '' },
	default => sub { curfile->dirname->dirname->dirname },
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
	my $config = Bot::Maverick::Config->new(
		dir => $self->config_dir,
		file => $self->config_file,
		defaults_hash => $self->_config_defaults,
	);
	if ($self->_has_init_config) {
		$config->apply($self->_init_config);
		$self->_clear_init_config;
	}
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
	my $storage = Bot::Maverick::Storage->new(
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
	my $path = $self->config->param('main', 'logfile') || undef;
	my $logger = Mojo::Log->new(path => $path);
	$logger->level('info') unless $self->config->param('main', 'debug');
	return $logger;
}

has 'ua' => (
	is => 'ro',
	lazy => 1,
	default => sub { Mojo::UserAgent->new->max_redirects(3) },
	init_arg => undef,
);

has 'ua_no_redirect' => (
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

has '_watch_timer' => (
	is => 'rwp',
	predicate => 1,
	clearer => 1,
	init_arg => undef,
);

has '_futures' => (
	is => 'ro',
	lazy => 1,
	default => sub { {} },
	init_arg => undef,
);

sub BUILD {
	my $self = shift;
	
	my $networks = $self->networks;
	croak "Networks must be specified as a hash reference"
		unless ref $networks eq 'HASH';
	croak "No networks have been specified" unless keys %$networks;
	$self->add_network($_ => delete $networks->{$_}) for keys %$networks;
	
	my $plugins = $self->_init_plugins;
	$plugins = {map { ($_ => 1) } @$plugins} if ref $plugins eq 'ARRAY';
	croak "Plugins must be specified as a hash or array reference"
		unless ref $plugins eq 'HASH';
	$plugins->{Core} //= 1;
	foreach my $plugin_class (keys %$plugins) {
		my $args = $plugins->{$plugin_class};
		$self->add_plugin($plugin_class => $args) if $args;
	}
	$self->_clear_init_plugins;
}

# Networks

sub add_network {
	my ($self, $name, $attrs) = @_;
	croak "Network name is unspecified" unless defined $name;
	croak "Network name $name contains invalid characters" if $name =~ /[^-.\w]/;
	croak "Network $name already exists" if exists $self->networks->{lc $name};
	my $class = $attrs->{class} // 'Bot::Maverick::Network';
	$class = "Bot::Maverick::Network::$class" unless $class =~ /::/;
	my %params = (name => $name, bot => $self);
	$params{config} = $attrs->{config} if defined $attrs->{config};
	try {
		my $network = use_module($class)->new(%params);
		$self->networks->{lc $name} = $network;
	} catch {
		croak "Network class $class could not be loaded: $_";
	};
	return $self;
}

# Plugins

sub add_plugin {
	my ($self, $class, $params) = @_;
	croak "Plugin class not defined" unless defined $class;
	$class = "Bot::Maverick::Plugin::$class" unless $class =~ /::/;
	my @params = ref $params eq 'HASH' ? %$params : ();
	try {
		my $plugin = use_module($class)->new(@params, bot => $self);
		die "$class does not perform the role Bot::Maverick::Plugin\n"
			unless $plugin->can('does') and $plugin->does('Bot::Maverick::Plugin');
		$plugin->register($self);
	} catch {
		croak "Plugin $class could not be registered: $_";
	};
	return $self;
}

sub has_helper {
	my ($self, $helper) = @_;
	croak "Unspecified helper method" unless defined $helper;
	return (exists $self->helpers->{$helper}
		or !!$self->can($helper));
}

sub add_helper {
	my ($self, $helper, $code) = @_;
	croak "Invalid helper method $helper"
		unless defined $helper and length $helper and !ref $helper;
	croak "Method $helper already exists"
		if exists $self->helpers->{$helper} or $self->can($helper);
	$self->helpers->{$helper} = $code;
	return $self;
}

# Autoload helper methods
sub AUTOCAN {
	my ($self, $method) = @_;
	return undef unless ref $self;
	return $self->helpers->{$method};
}

# Commands

sub get_command {
	my ($self, $name) = @_;
	return undef unless defined $name and exists $self->commands->{lc $name};
	return $self->commands->{lc $name};
}

sub get_commands_by_prefix {
	my ($self, $prefix) = @_;
	return [] unless defined $prefix and exists $self->_command_prefixes->{lc $prefix};
	return $self->_command_prefixes->{lc $prefix} // [];
}

sub add_command {
	my $self = shift;
	my $command;
	if (blessed $_[0] and $_[0]->isa('Bot::Maverick::Command')) {
		$command = shift;
	} elsif (!ref $_[0] or ref $_[0] eq 'HASH') {
		my %params = ref $_[0] eq 'HASH' ? %{$_[0]} : @_;
		$command = Bot::Maverick::Command->new(%params);
	} else {
		croak "$_[0] is not a Bot::Maverick::Command object";
	}
	my $name = $command->name;
	croak "Command $name already exists" if exists $self->commands->{lc $name};
	$self->commands->{lc $name} = $command;
	$self->_add_command_prefixes($name);
	return $self;
}

sub remove_command {
	my ($self, $name) = @_;
	croak "Command name not defined" unless defined $name;
	$self->_remove_command_prefixes($name);
	delete $self->commands->{lc $name};
	return $self;
}

sub _add_command_prefixes {
	my ($self, $name) = @_;
	croak "Command name not defined" unless defined $name;
	$name = lc $name;
	foreach my $len (1..length $name) {
		my $prefix = substr $name, 0, $len;
		my $prefixes = $self->_command_prefixes->{$prefix} //= [];
		push @$prefixes, $name;
	}
	return $self;
}

sub _remove_command_prefixes {
	my ($self, $name) = @_;
	croak "Command name not defined" unless defined $name;
	$name = lc $name;
	foreach my $len (1..length $name) {
		my $prefix = substr $name, 0, $len;
		my $prefixes = $self->_command_prefixes->{$prefix} //= [];
		@$prefixes = grep { $_ ne $name } @$prefixes;
		delete $self->_command_prefixes->{$prefix} unless @$prefixes;
	}
	return $self;
}

sub add_handler {
	my ($self, $code) = @_;
	push @{$self->handlers}, $code;
	return $self;
}

# Bot actions

sub start {
	my $self = shift;
	$self->logger->debug("Starting bot");
	$self->is_stopping(0);
	$SIG{INT} = $SIG{TERM} = $SIG{QUIT} = sub { $self->_sig_stop(@_) };
	$SIG{HUP} = $SIG{USR1} = $SIG{USR2} = sub { $self->_sig_reload(@_) };
	$SIG{__WARN__} = sub { my $msg = shift; chomp $msg; $self->logger->warn($msg) };
	
	$self->emit('start');
	
	# Make sure perl signals are caught in a timely fashion
	$self->_set__watch_timer(Mojo::IOLoop->recurring(1 => sub {}))
		unless $self->_has_watch_timer;
	Mojo::IOLoop->start unless Mojo::IOLoop->is_running;
	return $self;
}

sub stop {
	my ($self, $message) = @_;
	$self->logger->debug("Stopping bot");
	$self->is_stopping(1);
	Mojo::IOLoop->remove($self->_watch_timer) if $self->_has_watch_timer;
	$self->_clear_watch_timer;
	$self->emit(stop => $message);
	return $self;
}

sub reload {
	my $self = shift;
	$self->logger->debug("Reloading bot");
	$self->config->reload;
	$self->emit('reload');
	$self->clear_logger;
	return $self;
}

sub _sig_stop {
	my ($self, $signal) = @_;
	$self->logger->debug("Received signal SIG$signal, stopping");
	$self->stop;
}

sub _sig_reload {
	my ($self, $signal) = @_;
	$self->logger->debug("Received signal SIG$signal, reloading");
	$self->reload;
}

# Utility methods

sub loop { Mojo::IOLoop->singleton }

sub new_future {
	my $self = shift;
	return Future::Mojo->new;
}

sub timer_future {
	my ($self, $delay) = @_;
	return Future::Mojo->new_timer($delay);
}

sub adopt_future {
	my ($self, $future) = @_;
	my $key = "$future";
	$self->_futures->{$key} = $future;
	my $cancel = $self->once(stop => sub { $future->cancel });
	weaken $cancel;
	$future->on_ready(sub {
		my $future = shift;
		$self->unsubscribe(stop => $cancel) if $cancel;
		delete $self->_futures->{$key};
	});
	return $future;
}

sub callback_to_future {
	my ($self, $code) = @_;
	my $future = $self->new_future;
	weaken(my $weak_f = $future);
	$code->(sub {
		return unless $weak_f;
		my ($inv, $err, @res) = @_;
		$err ? $weak_f->fail($err) : $weak_f->done(@res);
	});
	return $future;
}

sub fork_call {
	my ($self, @args) = @_;
	return $self->callback_to_future(sub { Mojo::IOLoop->$_subprocess(@args, shift) });
}

my %methods = map { ($_ => 1) } qw(get post head put delete patch);
sub ua_request {
	my ($self, $method, @args) = @_;
	my $ua = $self->ua;
	if ($method eq 'no_redirect') {
		$method = shift @args;
		$ua = $self->ua_no_redirect;
	}
	if (exists $methods{lc $method}) {
		$method = lc $method;
	} else {
		unshift @args, $method;
		$method = 'get';
	}
	my $future = $self->new_future;
	weaken(my $weak_f = $future);
	$ua->$method(@args, sub {
		return unless $weak_f;
		my ($ua, $tx) = @_;
		if (my $err = $tx->error) {
			chomp($err = $self->ua_error($err));
			$weak_f->fail($err);
		} else {
			$weak_f->done($tx->res, $tx);
		}
	});
	return $future;
}

sub ua_error {
	my ($self, $err) = @_;
	return $err->{code}
		? "HTTP error $err->{code}: $err->{message}\n"
		: "Connection error: $err->{message}\n";
}

1;

=head1 NAME

Bot::Maverick - Mojo::IRC Bot framework

=head1 SYNOPSIS

  use Bot::Maverick;
  
  my $bot = Bot::Maverick->new(
    name => 'MyIRCBot',
    networks => {
      libera => {
        class => 'Libera',
        irc => { server => 'irc.libera.chat' },
      },
    },
  );
  
  $bot->start;

=head1 DESCRIPTION

L<Bot::Maverick> is an IRC bot framework built on L<Mojo::IRC> that supports
connecting to multiple networks and is designed to be configurable and
customizable via plugins. A core set of plugins is included from
L<Bot::Maverick::Plugin::Core> which includes basic administrative and
configuration commands, and additional plugins can be registered that may
implement any functionality from adding more commands to hooking into message
events and more.

=head1 CONFIGURATION

L<Bot::Maverick> is configured by INI files: one global configuration file and
a network configuration file for each network it connects to. The global
configuration file is used as a default configuration for each network. Any
configuration specified in the constructor or when adding a network will be
written to the configuration files, overriding existing configuration.

Configuration INI files are organized into sections, and all parameters must be
within a section.

=head2 main

=head2 irc

=head2 network

=head2 channels

=head2 users

=head2 commands

=head2 apis

=head1 NETWORKS

IRC networks are represented by L<Bot::Maverick::Network> (or subclassed)
objects that handle all communication with that network. Networks can be
specified in the bot's constructor, or added later with the L</"network">
method.

=head1 PLUGINS

Plugins are L<Moo> objects that compose the role L<Bot::Maverick::Plugin>. They
are registered by calling the required method C<register> and may add commands,
hooks, or anything else to the bot instance. A plugin may also register a
method of its own as a "helper method" which then can be called on the bot
instance from elsewhere. The plugin object is passed as the invocant of the
registered helper method.

=head1 COMMANDS

Commands are represented by L<Bot::Maverick::Command> objects which define the
properties of the command and a callback "on_run" that is called when the
command is invoked by a IRC user.

=head1 HANDLERS

Handlers are callbacks which are run in order for any received message which is
not a command. If the handler returns a true value, further handlers will not
be called.

=head1 HOOKS

Hooks are subroutines which are run whenever a specific action occurs. They are
a powerful way to add global functionality.

=head2 start

  $bot->on(start => sub { my ($bot) = @_; ... });

Emitted when the bot is started.

=head2 stop

  $bot->on(stop => sub { my ($bot) = @_; ... });

Emitted when the bot is stopped.

=head2 reload

  $bot->on(reload => sub { my ($bot) = @_; ... });

Emitted when the bot is reloaded.

=head2 privmsg

  $bot->on(privmsg => sub { my ($bot, $m) = @_; ... });

The C<privmsg> hook is called whenever the bot receives a channel or private
message ("privmsg") from an IRC user, and the message is not a command, and no
message handlers return true. The callback will receive the L<Bot::Maverick>
object and the L<Bot::Maverick::Message> object containing the message details.

=head2 before_command

  $bot->on(before_command => sub { my ($bot, $m) = @_; ... });

The C<before_command> hook is called before a recognized command is executed.
The callback will receive the L<Bot::Maverick> object and the
L<Bot::Maverick::Message> object containing the message details.

=head2 after_command

  $bot->on(after_command => sub { my ($bot, $m) = @_; ... });

The C<after_command> hook is called after a command has been executed. The
callback will receive the L<Bot::Maverick> object and the
L<Bot::Maverick::Message> object containing the message details.

=head1 METHODS

=head2 new

Constructs a new L<Bot::Maverick> object instance. Accepts values for the following
attributes:

=over

=item name

  name => 'Botzilla',

Name for the bot, defaults to C<Maverick>. The bot's name is used as a default
nick for networks where it is not configured, as well as lowercased for the
default filenames for configuration and other files. For example, a bot named
C<Fred> will (by default) use the configuration file C<fred.conf>, network
configuration files C<fred-E<lt>networkE<gt>.conf>, and database file
C<fred.db>.

=item networks

  networks => { libera => { class => 'Libera', config => { debug => 1 } } },

Hash reference that must contain at least one network to connect to. Keys are
names which will be used to identify the network as well as lowercased to
define the default network configuration filename. Values are hash references
containing an optional object C<class> (defaults to L<Bot::Maverick::Network>)
and configuration for the network. The C<class> will be appended to
C<Bot::Maverick::Network::> if it does not contain C<::>.

=item plugins

  plugins => [qw/DNS GeoIP/],
  plugins => { Core => 0, DNS => { native => 0 }, GeoIP => 1 },

Plugins to register with the bot, specified as plugin class names, which are
appended to C<Bot::Maverick::Plugin::> if they do not contain C<::>. May be
specified as an array reference to simply include the list of plugins, or as a
hash reference to configure the plugins. If the hash value is false, the plugin
will be not be registered. If the value is a hash reference, it will be passed
to the plugin's constructor. See L<Bot::Maverick::Plugin> for documentation on
Maverick plugins.

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

=head2 add_network

  $bot = $bot->add_network(libera => { class => 'Libera' });

Adds a network for the bot to connect to. See L</"NETWORKS">.

=head2 add_plugin

  $bot = $bot->add_plugin(DNS => { native => 0 });

Registers a plugin with optional hashref of parameters to pass to the plugin's
C<register> method. See L</"PLUGINS">.

=head2 add_helper

  $bot = $bot->add_helper(DNS => 'dns_resolve');

Adds a helper method to the bot, so that it may be called on the bot via
L</"AUTOLOAD">.

=head2 has_helper

  my $bool = $bot->has_helper('dns_resolve');

Returns a boolean value that is true if the specified helper method is
available.

=head2 add_command

  $bot = $bot->add_command(Bot::Maverick::Command->new(...));
  $bot = $bot->add_command(...);

Adds a L<Bot::Maverick::Command> to the bot, or passes the arguments to
construct a new L<Bot::Maverick::Command> and add it to the bot. See
L</"COMMANDS">.

=head2 get_command

  my $command = $bot->get_command('say');

Returns the L<Bot::Maverick::Command> object representing the command, or
C<undef> if the command does not exist.

=head2 get_commands_by_prefix

  my $commands = $bot->get_commands_by_prefix('wo');

Returns an array reference of command objects matching a prefix, if any.

=head2 remove_command

  $bot = $bot->remove_command('locate');

Removes a command from the bot by name if it exists.

=head2 loop

  my $loop = $bot->loop;

Returns the L<Mojo::IOLoop> singleton used for the bot's operation.

=head2 new_future

  my $future = $bot->new_future;

Returns a L<Future::Mojo> initialized with the L<Mojo::IOLoop> singleton.

=head2 timer_future

  my $future = $bot->timer_future(1);

Returns a L<Future::Mojo> initialized with the L<Mojo::IOLoop> singleton, which
will be set to done after the specified delay in seconds.

=head2 adopt_future

  $future = $bot->adopt_future($future);

Stores a reference to the passed L<Future> object which will be cleared once
the future is ready. Stored futures will be cancelled if the bot is stopped.

=head2 ua_request

  my $future = $bot->ua_request($url);
  my $future = $bot->ua_request(post => $url, {Authorization => 'open sesame'}, json => [1,2,3]);

Runs a non-blocking L<Mojo::UserAgent> request and returns a L<Future::Mojo>
that will be set to failed on connection or HTTP error, and otherwise will be
set to done with the L<Mojo::Message::Response>. The first argument can
optionally be a request method (defaults to C<get>), and the remaining
arguments are passed to L<Mojo::UserAgent>.

=head2 fork_call

  my $future = $bot->fork_call(sub { return 'foo' });

Runs a code ref in a forked process using L<Mojo::IOLoop::Subprocess::Sereal>
and returns a L<Future::Mojo> that will be set to failed if the code throws an
exception, and otherwise will be set to done with the returned values.

=head1 BUGS

Report any issues on the public bugtracker.

=head1 AUTHOR

Dan Book, C<dbook@cpan.org>

=head1 COPYRIGHT AND LICENSE

Copyright 2015, Dan Book.

This library is free software; you may redistribute it and/or modify it under
the terms of the Artistic License version 2.0.

=head1 SEE ALSO

L<Bot::Maverick::Network>, L<Bot::Maverick::Plugin>, L<Mojo::IRC>
