package Bot::Maverick::Config;

use Carp;
use Config::IniFiles;
use File::Path 'make_path';
use File::Spec;
use Scalar::Util 'blessed';

use Moo;
use namespace::clean;

our $VERSION = '0.20';

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
		unless blessed $_[0] and $_[0]->isa('Bot::Maverick::Config') },
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

sub BUILD {
	my $self = shift;
	$self->fix_fallback($self->defaults);
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
	$self->fix_fallback($apply);
	foreach my $section_name (keys %$apply) {
		my $section = $apply->{$section_name} // next;
		croak "Invalid configuration section $section; must be a hash reference"
			unless ref $section eq 'HASH';
		$self->_set($section_name, $_, $section->{$_}) for keys %$section;
	}
	$self->store;
	return $self;
}

sub set {
	my $self = shift;
	$self->_set(@_);
	$self->store;
}

sub _set {
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

sub set_channel {
	my $self = shift;
	my ($channel, $key, $value) = @_;
	$channel //= 'network';
	croak "Parameter name must be specified" unless defined $key;
	croak "Invalid channel name $channel"
		unless lc $channel eq 'network' or $channel =~ /^#/;
	return $self->set(lc $channel, $key, $value);
}

sub set_channel_default {
	my $self = shift;
	my ($key, $value) = @_;
	croak "Parameter name must be specified" unless defined $key;
	return $self if defined $self->get_channel('network', $key);
	return $self->set('network', $key, $value);
}

sub get_channel {
	my $self = shift;
	my ($channel, $key) = @_;
	croak "Channel and parameter name must be specified"
		unless defined $channel and defined $key;
	return $self->get('network', $key) if lc $channel eq 'network';
	croak "Invalid channel name $channel" unless $channel =~ /^#/;
	return $self->get(lc $channel, $key) // $self->get('network', $key);
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
	return $self->has_defaults_config ? $self->defaults_config->hash : $self->defaults;
}

sub fix_fallback {
	my ($self, $config) = @_;
	my $fallback_name = $self->fallback;
	my %fallback_section;
	foreach my $key (keys %$config) {
		my $value = $config->{$key} // next;
		next if ref $value eq 'HASH'; # skip actual config sections
		croak "Invalid configuration value $value for $key; " .
			"must be a simple scalar" if ref $value;
		$fallback_section{$key} = $value;
	}
	$config->{$fallback_name}{$_} = $fallback_section{$_} for keys %fallback_section;
	return $config;
}

1;

=head1 NAME

Bot::Maverick::Config - Configuration file management for Maverick

=head1 SYNOPSIS

  my $config = Bot::Maverick::Config->new(file => 'bot.conf', defaults => {});
  $config->get('main', 'debug');
  $config->set('main', debug => 1);

=head1 DESCRIPTION

Manages the configuration files for a L<Bot::Maverick> IRC bot.

=head1 ATTRIBUTES

=head2 dir

Directory to store configuration files. Defaults to current directory.

=head2 file

Filename for configuration file. Required.

=head2 defaults

Default configuration specified as a hash reference. Configuration not within a
section will be assumed to be in the L</"fallback"> section. When retrieving
configuration, the value from the defaults hashref is used if it is not set in
the configuration file.

=head2 defaults_config

Default configuration specified as a L<Bot::Maverick::Config> object. When
retrieving configuration, this config object is used if it is not set in the
configuration file.

=head2 fallback

Fallback section name for configuration specified without a section name,
defaults to C<main>.

=head1 METHODS

=head2 reload

Reloads configuration from file.

=head2 store

Stores configuration to file.

=head2 apply

Applies configuration parameters specified as a hash reference, and stores
configuration to file.

=head2 set

Sets configuration parameter and stores configuration to file.

=head2 get

Retrieves configuration parameter.

=head2 set_channel

Sets configuration parameter for a channel.

=head2 set_channel_default

Sets configuration parameter for section C<network>.

=head2 get_channel

Retrieves configuration parameter for a channel section. If the parameter has
not been set for the channel, retrieves the value for section C<network>.

=head2 hash

Returns a hash reference representing all currently set or default
configuration parameters.

=head2 defaults_hash

Returns either the L</"defaults"> hash reference, or a configuration hash
reference generated from the L</"defaults_config"> object.

=head2 fix_fallback

Moves all configuration parameters in the given hashref that are not in a
section to the L</"fallback"> section.

=head1 BUGS

Report any issues on the public bugtracker.

=head1 AUTHOR

Dan Book, C<dbook@cpan.org>

=head1 COPYRIGHT AND LICENSE

Copyright 2015, Dan Book.

This library is free software; you may redistribute it and/or modify it under
the terms of the Artistic License version 2.0.

=head1 SEE ALSO

L<Bot::Maverick>
