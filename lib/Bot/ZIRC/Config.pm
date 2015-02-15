package Bot::ZIRC::Config;

use Carp;
use Config::IniFiles;
use File::Path 'make_path';
use File::Spec;

use Moo;
use warnings NONFATAL => 'all';
use namespace::clean;

has 'defaults' => (
	is => 'ro',
	isa => sub { croak "Invalid configuration hashref $_[0]"
		unless defined $_[0] and ref $_[0] eq 'HASH' },
	lazy => 1,
	default => sub { {} },
);

has 'config' => (
	is => 'lazy',
	init_arg => undef,
);

has 'dir' => (
	is => 'ro',
);

has 'file' => (
	is => 'ro',
	isa => sub { croak "Configuration file is unspecified"
		unless defined $_[0] and length $_[0] },
	required => 1,
);

has 'fallback' => (
	is => 'ro',
	isa => sub { croak "Fallback section name cannot be empty"
		unless defined $_[0] and length $_[0] },
	lazy => 1,
	default => 'main',
);

sub BUILD {
	my $self = shift;
	$self->apply_defaults($self->defaults);
}

sub _build_config {
	my $self = shift;
	my $dir = $self->dir;
	my $config_file = $self->file;
	if (defined $dir and length $dir) {
		make_path($dir) if !-e $dir;
		$config_file = File::Spec->catfile($dir, $config_file);
	}
	my %config;
	tie %config, 'Config::IniFiles', (
		-fallback => $self->fallback,
		-nocase => 1,
		-allowcontinue => 1,
		-nomultiline => 1,
		-commentchar => ';',
		-allowedcommentchars => ';',
		-handle_trailing_comment => 1,
	);
	tied(%config)->SetFileName($config_file) // croak
		"Invalid filename $config_file for configuration file";
	tied(%config)->SetWriteMode('0644');
	if (-e $config_file) {
		$self->_read_config(\%config);
	} else {
		$self->_write_config(\%config);
	}
	return \%config;
}

sub _read_config {
	my ($self, $config) = @_;
	my $filename = tied(%$config)->GetFileName;
	my $rc = tied(%$config)->ReadConfig;
	unless (defined $rc) {
		my $err_str = @Config::IniFiles::errors ? "@Config::IniFiles::errors" : "$!";
		warn "Failed to read configuration file $filename: $err_str\n";
	}
	return $self;
}

sub _write_config {
	my ($self, $config) = @_;
	my $filename = tied(%$config)->GetFileName;
	tied(%$config)->WriteConfig($filename) // warn
		"Failed to write configuration file $filename: $!\n";
	return $self;
}

sub _rewrite_config {
	my ($self, $config) = @_;
	my $filename = tied(%$config)->GetFileName;
	tied(%$config)->RewriteConfig // warn
		"Failed to rewrite configuration file $filename: $!\n";
	return $self;
}

sub reload {
	my $self = shift;
	$self->_read_config($self->config)->apply_defaults($self->defaults);
}

sub store {
	my $self = shift;
	$self->_rewrite_config($self->config);
}

sub apply_defaults {
	my ($self, $defaults) = @_;
	$self->apply($defaults, 1);
}

sub apply {
	my ($self, $apply, $no_overwrite) = @_;
	return $self unless defined $apply and keys %$apply;
	foreach my $section_name (keys %$apply) {
		my $section = $apply->{$section_name};
		next unless defined $section;
		if (!ref $section) {
			$section = { $section_name => $section };
			$section_name = $self->fallback;
		}
		croak "Invalid configuration section $section; must be a hash reference"
			unless ref $section eq 'HASH';
		foreach my $key (keys %$section) {
			my $value = $section->{$key};
			croak "Invalid configuration value $value for $key in section $section; " .
				"must be a simple scalar" if ref $value;
			$self->config->{$section_name} //= {};
			next if defined $self->config->{$section_name}{$key} and $no_overwrite;
			$self->config->{$section_name}{$key} = $value;
		}
	}
	return $self;
}

sub set {
	my $self = shift;
	my ($section, $key, $value);
	if (@_ < 3) {
		$section = $self->fallback;
		($key, $value) = @_;
	} else {
		($section, $key, $value) = @_;
	}
	croak "Section and parameter name must be specified"
		unless defined $section and defined $key;
	$self->config->{$section} //= {};
	$self->config->{$section}{$key} = $value;
	return $self;
}

sub get {
	my $self = shift;
	my ($section, $key);
	if (@_ < 2) {
		$section = $self->fallback;
		($key) = @_;
	} else {
		($section, $key) = @_;
	}
	croak "Section and parameter name must be specified"
		unless defined $section and defined $key;
	return undef unless exists $self->config->{$section}
		and exists $self->config->{$section}{$key};
	return $self->config->{$section}{$key};
}

1;
