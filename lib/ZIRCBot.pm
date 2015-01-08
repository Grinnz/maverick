package ZIRCBot;

use Config::IniFiles;
use JSON;
use File::Spec;
use File::Path 'make_path';
use POE qw/Component::Client::DNS/;
use Scalar::Util 'blessed';

use Moo;
use warnings NONFATAL => 'all';
use namespace::clean;

use version 0.77; our $VERSION = version->declare('v0.2.0');
sub bot_version { return $VERSION }

with 'ZIRCBot::DNS';

my @poe_events = qw/_start sig_terminate/;

my %irc_handlers = (
	'socialgamer' => 'ZIRCBot::IRC::SocialGamer',
	'freenode' => 'ZIRCBot::IRC::Freenode',
	'gamesurge' => 'ZIRCBot::IRC::GameSurge',
);

sub get_irc_handler {
	my $type = shift // return undef;
	return undef unless exists $irc_handlers{$type};
	return $irc_handlers{$type};
}

has 'irc_handler' => (
	is => 'ro',
	isa => sub { die 'Invalid IRC handler' unless get_irc_handler($_[0]) },
	default => 'socialgamer',
);

has 'nick' => (
	is => 'rwp',
	default => 'ZIRCBot',
);

has 'config_dir' => (
	is => 'ro',
	trigger => sub { my ($self, $path) = @_; make_path($path); },
	default => sub { my $path = File::Spec->catfile($ENV{HOME}, '.zircbot'); make_path($path); return $path },
);

has 'config_file' => (
	is => 'ro',
	default => 'zircbot.conf',
);

has 'db_file' => (
	is => 'ro',
	default => 'zircbot.db',
);

has 'config' => (
	is => 'lazy',
	init_arg => undef,
);

has 'db' => (
	is => 'lazy',
	init_arg => undef,
);

has 'commands' => (
	is => 'ro',
	lazy => 1,
	default => sub { {} },
	init_arg => undef,
);

has 'irc' => (
	is => 'lazy',
	isa => sub { die 'Invalid IRC object' unless defined $_[0] and blessed $_[0] and $_[0]->isa('POE::Component::IRC') },
	init_arg => undef,
);

has 'resolver' => (
	is => 'lazy',
	isa => sub { die 'Invalid resolver object' unless defined $_[0] and blessed $_[0] and $_[0]->isa('POE::Component::Client::DNS') },
	init_arg => undef,
);

has 'is_stopping' => (
	is => 'rw',
	coerce => sub { $_[0] ? 1 : 0 },
	default => 0,
	init_arg => undef,
);

sub BUILD {
	my $self = shift;
	
	my $irc_handler = $self->irc_handler;
	my $irc_role = get_irc_handler($irc_handler);
	die "Could not find role for IRC handler $irc_handler\n" unless $irc_role;
	require Role::Tiny;
	Role::Tiny->apply_roles_to_object($self, $irc_role);
}

sub get_poe_events {
	my $self = shift;
	return (@poe_events, $self->get_irc_events, $self->get_dns_events);
}

sub create_poe_session {
	my $self = shift;
	my @session_events = $self->get_poe_events;
	POE::Session->create(
		object_states => [
			$self => \@session_events,
		],
	);
}

sub _start {
	my $self = $_[OBJECT];
	my $kernel = $_[KERNEL];
	
	$kernel->sig(TERM => 'sig_terminate');
	$kernel->sig(INT => 'sig_terminate');
	$kernel->sig(QUIT => 'sig_terminate');
	
	$self->hook_start;
}

sub hook_start {
}

sub sig_terminate {
	my $self = $_[OBJECT];
	my $kernel = $_[KERNEL];
	my $signal = $_[ARG0];
	
	$self->print_debug("Received signal SIG$signal");
	$self->is_stopping(1);
	$self->hook_stop;
	$kernel->sig_handled;
}

sub hook_stop {
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
	);
	tied(%config)->SetFileName($config_file);
	if (-e $config_file) {
		tied(%config)->ReadConfig;
	} else {
		$self->_init_config(\%config);
		tied(%config)->WriteConfig($config_file);
	}
	
	return \%config;
}

sub _reload_config {
	my $self = shift;
	tied(%{$self->config})->ReadConfig;
}

sub _store_config {
	my $self = shift;
	tied(%{$self->config})->RewriteConfig;
}

sub _init_config {
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
		'flood' => 0,
		'away_msg' => 'I am a bot. Say !help in a channel or in PM for help.',
		'reconnect' => 1,
	};
	$config_hr->{commands} = {
		'trigger' => '!',
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

sub _store_db {
	my $self = shift;
	my $db_file = File::Spec->catfile($self->config_dir, $self->db_file);
	my $db_json = encode_json $self->db;
	open my $db_fh, '>', $db_file or die $!;
	print $db_fh $db_json;
	close $db_fh;
	return 1;
}

sub print_debug {
	my $self = shift;
	$self->print_log(@_) if $self->config->{main}{debug};
}

sub print_echo {
	my $self = shift;
	$self->print_log(@_) if $self->config->{main}{echo};
}

sub print_log {
	my $self = shift;
	my @msgs = @_;
	my $localtime = scalar localtime;
	print "[ $localtime ] $_\n" foreach @msgs;
	return 1;
}

1;
