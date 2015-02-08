package ZIRCBot;

use Net::DNS::Native; # load early to avoid threading issues

use Config::IniFiles;
use File::Spec;
use File::Path 'make_path';
use List::Util 'any';
use Mojo::IOLoop;
use Mojo::JSON qw/encode_json decode_json/;
use Mojo::Log;
use ZIRCBot::Access;

use Moo;
use warnings NONFATAL => 'all';
use namespace::clean;

our $VERSION = '0.04';
sub bot_version { return $VERSION }

with 'ZIRCBot::DNS';

has 'irc_role' => (
	is => 'ro',
	lazy => 1,
	default => 'Freenode',
);

has 'nick' => (
	is => 'rwp',
	lazy => 1,
	default => 'ZIRCBot',
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
	is => 'lazy',
	init_arg => undef,
);

has 'db_file' => (
	is => 'ro',
	lazy => 1,
	default => 'zircbot.db',
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
	my $irc_role = $self->irc_role // die 'Invalid IRC handler';
	require Role::Tiny;
	$irc_role = "ZIRCBot::IRC::$irc_role" unless $irc_role =~ /::/;
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

sub user_access_level {
	my ($self, $user) = @_;
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

1;
