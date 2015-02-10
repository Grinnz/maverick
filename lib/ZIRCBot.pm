package ZIRCBot;

use Net::DNS::Native; # load early to avoid threading issues

use Carp;
use Config::IniFiles;
use File::Spec;
use File::Path 'make_path';
use IRC::Utils;
use List::Util 'any';
use Mojo::IOLoop;
use Mojo::JSON qw/encode_json decode_json/;
use Mojo::Log;
use Scalar::Util 'blessed';
use ZIRCBot::Access;

use Moo;
use warnings NONFATAL => 'all';
use namespace::clean;

our $VERSION = '0.05';
sub bot_version { return $VERSION }

with 'ZIRCBot::DNS';

has 'irc_role' => (
	is => 'ro',
	lazy => 1,
	default => 'ZIRCBot::IRC',
);

has 'config_dir' => (
	is => 'ro',
	lazy => 1,
	trigger => sub { my ($self, $path) = @_; make_path($path); },
	default => sub { my $path = File::Spec->catfile($ENV{HOME}, '.zircbot'); make_path($path); return $path },
);

has 'config_file' => (
	is => 'ro',
	lazy => 1,
	default => 'zircbot.conf',
);

has 'config' => (
	is => 'rwp',
	lazy => 1,
	default => sub { {} },
);

has 'db_file' => (
	is => 'ro',
	lazy => 1,
	default => 'zircbot.db',
);

has 'db' => (
	is => 'rwp',
	lazy => 1,
	builder => 1,
	init_arg => undef,
);

has 'plugins' => (
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
);

has 'futures' => (
	is => 'ro',
	lazy => 1,
	default => sub { {} },
	init_arg => undef,
);

has 'logger' => (
	is => 'lazy',
	init_arg => undef,
	clearer => 1,
);

sub _build_logger {
	my $self = shift;
	my $path = $self->config->{main}{logfile} || undef;
	my $logger = Mojo::Log->new(path => $path);
	$logger->level('info') unless $self->config->{main}{debug};
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
	
	$self->_load_config($self->config);
	
	my $irc_role = $self->irc_role;
	$irc_role = "ZIRCBot::IRC::$irc_role" unless $irc_role =~ /::/;
	require Role::Tiny;
	Role::Tiny->apply_roles_to_object($self, $irc_role);
}

sub start {
	my $self = shift;
	$SIG{INT} = $SIG{TERM} = $SIG{QUIT} = sub { $self->sig_stop(@_) };
	$SIG{HUP} = $SIG{USR1} = $SIG{USR2} = sub { $self->sig_reload(@_) };
	$SIG{__WARN__} = sub { my $msg = shift; chomp $msg; $self->logger->warn($msg) };
	Mojo::IOLoop->start unless Mojo::IOLoop->is_running;
}

sub stop {
	my $self = shift;
	$self->is_stopping(1);
}

sub sig_stop {
	my ($self, $signal) = @_;
	$self->logger->debug("Received signal SIG$signal, stopping");
	$self->stop;
}

sub sig_reload {
	my ($self, $signal) = @_;
	$self->logger->debug("Received signal SIG$signal, reloading");
	$self->clear_logger;
	$self->_reload_config;
}

sub queue_event_future {
	my ($self, $future, $event, $key) = @_;
	croak 'No future given' unless defined $future;
	croak "Invalid future object $future" unless blessed $future and $future->isa('Future');
	croak 'No event given' unless defined $event;
	my $futures = $self->futures->{$event} //= {};
	my $future_list = defined $key
		? ($futures->{by_key}{lc $key} //= [])
		: ($futures->{list} //= []);
	push @$future_list, ref $future eq 'ARRAY' ? @$future : $future;
	return $self;
}

sub get_event_futures {
	my ($self, $event, $key) = @_;
	croak 'No event given' unless defined $event;
	return undef unless exists $self->futures->{$event};
	my $futures = $self->futures->{$event};
	my $future_list = defined $key
		? delete $futures->{by_key}{lc $key}
		: delete $futures->{list};
	delete $self->futures->{$event} unless exists $futures->{list}
		or keys %{$futures->{by_key}};
	return $future_list // [];
}

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
	my ($self, $class) = @_;
	croak "Plugin class not defined" unless defined $class;
	return $self if $self->has_plugin($class);
	eval "require $class; 1";
	croak $@ if $@;
	require Role::Tiny;
	croak "$class does not do role ZIRCBot::Plugin"
		unless Role::Tiny::does_role($class, 'ZIRCBot::Plugin');
	my $plugin = $class->new;
	$plugin->register($self);
	$self->plugins->{$class} = $plugin;
	return $self;
}

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
	my ($self, $command) = @_;
	croak "Command object not defined" unless defined $command;
	croak "$command is not a ZIRCBot::Command object" unless blessed $command
		and $command->isa('ZIRCBot::Command');
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

sub parse_command {
	my ($self, $irc, $sender, $channel, $message) = @_;
	my $trigger = $self->config->{commands}{trigger};
	my $by_nick = $self->config->{commands}{by_nick};
	my $bot_nick = $irc->nick;
	
	my ($cmd_name, $args_str);
	if ($trigger and $message =~ /^\Q$trigger\E(\w+)\s*(.*?)$/i) {
		($cmd_name, $args_str) = ($1, $2);
	} elsif ($by_nick and $message =~ /^\Q$bot_nick\E[:,]?\s+(\w+)\s*(.*?)$/i) {
		($cmd_name, $args_str) = ($1, $2);
	} elsif (!defined $channel and $message =~ /^(\w+)\s*(.*?)$/) {
		($cmd_name, $args_str) = ($1, $2);
	} else {
		return undef;
	}
	
	my $command = $self->get_command($cmd_name);
	if (!defined $command and $self->config->{commands}{prefixes}) {
		my $cmds = $self->get_commands_by_prefix($cmd_name);
		return undef unless $cmds and @$cmds;
		if (@$cmds > 1) {
			my $suggestions = join ', ', sort @$cmds;
			$irc->write(privmsg => $channel // $sender,
				"Command $cmd_name is ambiguous. Did you mean: $suggestions");
			return undef;
		}
		$command = $self->get_command($cmds->[0]) // return undef;
	}
	
	return undef unless defined $command;
	
	$cmd_name = $command->name;
	unless ($command->is_enabled) {
		$irc->write(privmsg => $sender, "Command $cmd_name is currently disabled.");
		return undef;
	}
	
	$args_str = IRC::Utils::strip_formatting($args_str) if $command->strip_formatting;
	$args_str =~ s/^\s+//;
	$args_str =~ s/\s+$//;
	my @args = split /\s+/, $args_str;
	
	$self->logger->debug("<$sender> [command] $cmd_name $args_str");
	
	return ($command, @args);
}

sub check_command_access {
	my ($self, $irc, $sender, $channel, $command) = @_;
	my $required = $command->required_access;
	$self->logger->debug("Required access is $required");
	return 1 if $required == ACCESS_NONE;
	
	my $user = $self->user($sender);
	# Check for sufficient channel access
	my $channel_access = $user->channel_access($channel);
	$self->logger->debug("$sender has channel access $channel_access");
	return 1 if $channel_access >= $required;
	
	# Check for sufficient bot access
	my $bot_access = $user->bot_access // return undef;
	$self->logger->debug("$sender has bot access $bot_access");
	return 1 if $bot_access >= $required;
	
	$self->logger->debug("$sender does not have access to run the command");
	return 0;
}

sub user_access_level {
	my ($self, $user) = @_;
	croak 'No user nick specified' unless defined $user;
	return ACCESS_BOT_MASTER if lc $user eq lc ($self->config->{users}{master}//'');
	if (my @admins = split /[\s,]+/, $self->config->{users}{admin}) {
		return ACCESS_BOT_ADMIN if any { lc $user eq lc $_ } @admins;
	}
	if (my @voices = split /[\s,]+/, $self->config->{users}{voice}) {
		return ACCESS_BOT_VOICE if any { lc $user eq lc $_ } @voices;
	}
	return ACCESS_NONE;
}

sub _build_config {
	my $self = shift;
	my $config_file = File::Spec->catfile($self->config_dir, $self->config_file);
	my %config;
	tie %config, 'Config::IniFiles', (
		-fallback => 'main',
		-nocase => 1,
		-allowcontinue => 1,
		-nomultiline => 1,
		-handle_trailing_comment => 1,
	);
	tied(%config)->SetFileName($config_file);
	if (-e $config_file) {
		tied(%config)->ReadConfig;
	} else {
		$self->_default_config(\%config);
		tied(%config)->WriteConfig($config_file);
	}
	
	return \%config;
}

sub _default_config {
	my $self = shift;
	my $config_hr = shift;
	%$config_hr = ();
	$config_hr->{main} = {
		'debug' => 1,
		'echo' => 1,
	};
	$config_hr->{irc} = {
		'server' => '',
		'server_pass' => '',
		'port' => 6667,
		'ssl' => 0,
		'realname' => '',
		'nick' => 'ZIRCBot',
		'password' => '',
		'away_msg' => 'I am a bot. Say !help in a channel or in PM for help.',
		'reconnect' => 1,
	};
	$config_hr->{commands} = {
		'trigger' => '!',
		'by_name' => 1,
		'prefixes' => 1,
	};
	$config_hr->{users} = {
		'master' => '',
	};
	$config_hr->{channels} = {
		'autojoin' => '',
	};
	$config_hr->{apis} = {};
	return 1;
}

sub _load_config {
	my $self = shift;
	my $override_config = shift // {};
	croak "Invalid configuration override" unless ref $override_config eq 'HASH';
	$self->_set_config($self->_build_config);
	return 1 unless keys %$override_config;
	foreach my $section (keys %$override_config) {
		$self->config->{$section} //= {};
		next unless ref $override_config->{$section} eq 'HASH';
		foreach my $param (keys %{$override_config->{$section}}) {
			$self->config->{$section}{$param} = $override_config->{$section}{$param};
		}
	}
	$self->_store_config;
}

sub _reload_config {
	my $self = shift;
	tied(%{$self->config})->ReadConfig;
}

sub _store_config {
	my $self = shift;
	tied(%{$self->config})->RewriteConfig;
}

sub _build_db {
	my $self = shift;
	my $db_file = File::Spec->catfile($self->config_dir, $self->db_file);
	my $db;
	if (-e $db_file) {
		open my $db_fh, '<', $db_file or die $!;
		local $/;
		my $db_json = <$db_fh>;
		close $db_fh;
		$db = eval { decode_json $db_json };
		die "Invalid database file $db_file: $@\n" if $@;
	} else {
		$db = {};
		my $db_json = encode_json $db;
		open my $db_fh, '>', $db_file or die $!;
		print $db_fh $db_json;
		close $db_fh;
	}
	return $db;
}

sub _load_db {
	my $self = shift;
	$self->_set_db($self->_build_db);
}

sub _store_db {
	my $self = shift;
	my $db_file = File::Spec->catfile($self->config_dir, $self->db_file);
	my $db_json = encode_json $self->db;
	open my $db_fh, '>', $db_file or die $!;
	print $db_fh $db_json;
	close $db_fh;
	return 1;
}

1;
