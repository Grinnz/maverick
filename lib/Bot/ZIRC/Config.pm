package Bot::ZIRC::Config;

use Carp;
use Config::IniFiles;
use File::Path 'make_path';
use File::Spec;
use Scalar::Util 'blessed';

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

has 'defaults_config' => (
	is => 'ro',
	isa => sub { croak "Invalid default configuration $_[0]"
		unless blessed $_[0] and $_[0]->isa('Bot::ZIRC::Config') },
	predicate => 1,
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
		-allowempty => 1,
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
	$self->_read_config($self->config);
}

sub store {
	my $self = shift;
	$self->_rewrite_config($self->config);
}

sub apply {
	my ($self, $apply) = @_;
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
		$self->set($section_name, $_, $section->{$_}) for keys %$section;
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
	croak "Invalid configuration value $value for $key in section $section; " .
		"must be a simple scalar" if ref $value;
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
	return $self->config->{$section}{$key} // $self->defaults_hash->{$section}{$key};
}

sub hash {
	my $self = shift;
	my %config_hash;
	my $config = $self->config;
	foreach my $section_name (keys %$config) {
		my $section = $config->{$section_name} // next;
		$config_hash{$section_name}{$_} = $section->{$_} for keys %$section;
	}
	my $defaults = $self->defaults_hash;
	foreach my $section_name (keys %$defaults) {
		my $section = $defaults->{$section_name} // next;
		$config_hash{$section_name}{$_} //= $section->{$_} for keys %$section;
	}
	return \%config_hash;
}

sub defaults_hash {
	my $self = shift;
	if ($self->has_defaults_config) {
		return $self->defaults_config->hash;
	} else {
		my %defaults_hash;
		my $defaults = $self->defaults;
		foreach my $section_name (keys %$defaults) {
			my $section = $defaults->{$section_name};
			unless (ref $section eq 'HASH') {
				$section = {$section_name => $section};
				$section_name = $self->fallback;
			}
			$defaults_hash{$section_name}{$_} = $section->{$_} for keys %$section;
		}
		return \%defaults_hash;
	}
}

1;
