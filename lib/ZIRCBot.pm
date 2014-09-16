package ZIRCBot;

use Moose;
use Config::IniFiles;
use JSON;
use File::Spec;
use File::Path qw/make_path/;
use POE qw/Component::IRC Component::Client::DNS/;

use version 0.77; our $VERSION = version->declare('v0.1.0');

has 'config' => (
	is => 'ro',
	isa => 'HashRef',
	builder => '_load_config',
	lazy => 1,
	init_arg => undef,
);

has 'db' => (
	is => 'ro',
	isa => 'HashRef',
	builder => '_load_db',
	lazy => 1,
	init_arg => undef,
);

has 'commands' => (
	is => 'ro',
	isa => 'HashRef[ZIRCBot::Command]',
	builder => '_load_commands',
	lazy => 1,
	init_arg => undef,
	traits => ['Hash'],
	handles => {
		command => 'get',
	},
);

has 'irc' => (
	is => 'ro',
	isa => 'POE::Component::IRC',
	builder => '_spawn_irc',
	lazy => 1,
	init_arg => undef,
	handles => [qw/yield/],
);

has 'resolver' => (
	is => 'ro',
	isa => 'POE::Component::Client::DNS',
	default => sub { POE::Component::Client::DNS->spawn },
	handles => {
		resolve_dns => 'resolve',
	},
);

has 'nick' => (
	is => 'ro',
	isa => 'Str',
	writer => '_set_nick',
	default => 'ZIRCBot',
);

has 'config_dir' => (
	is => 'ro',
	isa => 'Str',
	trigger => sub { my ($self, $path) = @_; make_path($path); },
	default => sub { my $path = File::Spec->catfile($ENV{HOME}, '.zircbot'); make_path($path); return $path },
);

has 'config_file' => (
	is => 'ro',
	isa => 'Str',
	default => 'zircbot.conf',
);

has 'db_file' => (
	is => 'ro',
	isa => 'Str',
	default => 'zircbot.db',
);

sub _load_config {
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

sub _load_db {
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

sub _load_commands {
	return {};
}

sub _spawn_irc {
	my $self = shift;
	my $server = $self->config->{irc}{server};
	die "IRC server is not configured\n" unless length $server;
	my $irc = POE::Component::IRC->spawn(
		Nick => $self->config->{irc}{nick} // 'ZIRCBot',
		Server => $self->config->{irc}{server},
		Port => $self->config->{irc}{port} // 6667,
		Password => $self->config->{irc}{server_pass} // '',
		UseSSL => $self->config->{irc}{ssl} // 0,
		Ircname => $self->config->{irc}{realname} // '',
		Username => $self->config->{irc}{nick} // 'ZIRCBot',
		Flood => $self->config->{irc}{flood} // 0,
		Resolver => $self->resolver,
	) or die $!;
}

no Moose;
__PACKAGE__->meta->make_immutable;

1;
