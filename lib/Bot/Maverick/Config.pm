package Bot::Maverick::Config;

use Carp;
use Config::IniFiles;
use File::Path 'make_path';
use File::Spec;
use File::Temp;
use Scalar::Util 'blessed';

use Moo;
use namespace::clean;

our $VERSION = '0.20';

has 'dir' => (
	is => 'ro',
);

has 'file' => (
	is => 'ro',
	isa => sub { croak "Configuration filename must not be empty"
		unless defined $_[0] and length $_[0] },
	predicate => 1,
);

has 'ini' => (
	is => 'lazy',
	isa => sub { croak "Invalid configuration INI object $_[0]"
		unless blessed $_[0] and $_[0]->isa('Config::IniFiles') },
	predicate => 1,
	clearer => 1,
);

has 'defaults' => (
	is => 'rwp',
	isa => sub { croak "Invalid configuration defaults object $_[0]"
		unless blessed $_[0] and $_[0]->isa('Bot::Maverick::Config') },
	predicate => 1,
);

has '_defaults_hash' => (
	is => 'ro',
	isa => sub { croak "Invalid configuration defaults $_[0]"
		unless defined $_[0] and ref $_[0] eq 'HASH' },
	init_arg => 'defaults_hash',
	predicate => 1,
	clearer => 1,
);

has '_defaults_tempfile' => (
	is => 'rwp',
	init_arg => undef,
);

sub BUILD {
	my $self = shift;
	croak "Filename or INI object must be specified" unless $self->has_file or $self->has_ini;
	if ($self->_has_defaults_hash and !$self->has_defaults) {
		my $tmp = File::Temp->new;
		my $params = $self->_ini_params;
		$params->{-file} = $tmp->filename;
		my $defaults_ini = Config::IniFiles->new(%$params);
		my $defaults_config = Bot::Maverick::Config->new(ini => $defaults_ini);
		$defaults_config->apply($self->_defaults_hash);
		$defaults_config->_set__defaults_tempfile($tmp); # Keep temp file around with object
		$self->_clear_defaults_hash;
		$self->_set_defaults($defaults_config);
	}
}

sub _ini_params {
	+{
		-allowempty => 1,
		-nomultiline => 1,
		-commentchar => ';',
		-allowedcommentchars => ';',
		-handle_trailing_comment => 1,
	}
}

sub _build_ini {
	my $self = shift;
	my $dir = $self->dir;
	my $config_file = $self->file;
	if (defined $dir and length $dir) {
		make_path($dir) if !-e $dir;
		$config_file = File::Spec->catfile($dir, $config_file);
	}
	my $params = $self->_ini_params;
	$params->{-import} = $self->defaults->ini if $self->has_defaults;
	my $ini = Config::IniFiles->new(%$params);
	$ini->SetFileName($config_file) // croak
		"Invalid filename $config_file for configuration file";
	$ini->SetWriteMode('0644');
	if (-e $config_file) {
		$self->_read_ini($ini);
	} else {
		$self->_write_ini($ini);
	}
	return $ini;
}

sub _read_ini {
	my ($self, $ini) = @_;
	my $filename = $ini->GetFileName;
	my $rc = $ini->ReadConfig;
	unless (defined $rc) {
		my $err_str = @Config::IniFiles::errors ? "@Config::IniFiles::errors" : "$!";
		warn "Failed to read configuration file $filename: $err_str\n";
	}
	return $self;
}

sub _write_ini {
	my ($self, $ini) = @_;
	my $filename = $ini->GetFileName;
	$ini->WriteConfig($filename, -delta => 1) // warn
		"Failed to write configuration file $filename: $!\n";
	return $self;
}

sub reload {
	my $self = shift;
	$self->_read_ini($self->ini);
}

sub store {
	my $self = shift;
	$self->_write_ini($self->ini);
}

sub apply {
	my ($self, $apply) = @_;
	return $self unless defined $apply and keys %$apply;
	foreach my $section_name (keys %$apply) {
		my $section = $apply->{$section_name} // next;
		croak "Invalid configuration section $section; must be a hash reference"
			unless ref $section eq 'HASH';
		foreach my $key (keys %$section) {
			my @values = ref $section->{$key} eq 'ARRAY' ? @{$section->{$key}} : $section->{$key};
			$self->ini->newval($section_name, $key, @values);
		}
	}
	$self->store;
	return $self;
}

sub param {
	my ($self, $section, $key) = (shift, shift, shift);
	croak "Section and parameter name must be specified"
		unless defined $section and defined $key;
	if (@_) {
		my $value = shift;
		$self->ini->newval($section, $key, "$value");
		$self->store;
		return $self;
	} else {
		my $value = $self->ini->val($section, $key);
		return $value;
	}
}

sub multi_param {
	my ($self, $section, $key) = (shift, shift, shift);
	croak "Section and parameter name must be specified"
		unless defined $section and defined $key;
	if (@_) {
		my @values = @_;
		@values = @{$values[0]} if ref $values[0] eq 'ARRAY';
		$self->ini->newval($section, $key, @values);
		$self->store;
		return $self;
	} else {
		my @values = $self->ini->val($section, $key);
		return \@values;
	}
}

sub channel_param {
	my ($self, $channel, $key) = (shift, shift, shift);
	croak "Parameter name must be specified" unless defined $key;
	$channel //= 'network';
	croak "Invalid channel name $channel"
		unless $channel eq 'network' or $channel =~ /^#/;
	$self->param(lc $channel, $key, @_);
	if (@_) {
		my $value = shift;
		return $self->param(lc $channel, $key, $value);
	} else {
		return $self->param(lc $channel, $key) // $self->param('network', $key);
	}
}

sub channel_default {
	my $self = shift;
	return $self->channel_param('network', @_);
}

sub to_hash {
	my $self = shift;
	my %config_hash;
	my $ini = $self->ini;
	foreach my $section_name ($ini->Sections) {
		$config_hash{$section_name}{$_} = $ini->val($section_name, $_)
			foreach $ini->Parameters($section_name);
	}
	return \%config_hash;
}

1;

=head1 NAME

Bot::Maverick::Config - Configuration file management for Maverick

=head1 SYNOPSIS

  my $config = Bot::Maverick::Config->new(file => 'bot.conf');
  my $debug = $config->param('main', 'debug');
  $config->param('main', debug => 1);

=head1 DESCRIPTION

Manages the configuration files for a L<Bot::Maverick> IRC bot.

=head1 ATTRIBUTES

=head2 dir

Directory to store configuration files. Defaults to current directory.

=head2 file

Filename for configuration file. Required if L</"ini"> is not set.

=head2 ini

Underlying L<Config::IniFiles> object.

=head2 defaults

Default configuration specified as a L<Bot::Maverick::Config> object. If
specified, the C<defaults> object will provide default values for any
parameters that are not set in this object. Default values will not be written
to this object's configuration file unless explicitly set.

=head1 METHODS

=head2 new

Construct a new L<Bot::Maverick::Config> object. Either L</"file"> or L</"ini">
must be passed. In addition to standard attributes, the parameter
C<defaults_hash> may be passed, with the value as a hash reference used to
create a L<Bot::Maverick::Config> object to use for L</"defaults">.

=head2 reload

Reloads configuration from file.

=head2 store

Stores configuration to file.

=head2 apply

Applies configuration parameters specified as a hash reference, and stores
configuration to file.

=head2 param

Gets or sets configuration parameter. Note that the value that is set will be
stringified. Retrieving a multi-value parameter with this method will return
the values joined into a single string with newlines. Setting a configuration
parameter will also store the configuration to file.

=head2 multi_param

Gets or sets multi-value configuration parameter. Values to set can be passed
as a list or array reference. Retrieved values will be returned as an array
reference.

=head2 channel_param

Gets or sets configuration parameter for a channel, using the C<network>
section for default values.

=head2 channel_default

Sets configuration parameter for section C<network>.

=head2 to_hash

Returns a hash reference representing all currently set or default
configuration parameters, organized into hash references by section.
Multi-value parameters will have their values joined into a single string with
newlines.

=head1 BUGS

Report any issues on the public bugtracker.

=head1 AUTHOR

Dan Book, C<dbook@cpan.org>

=head1 COPYRIGHT AND LICENSE

Copyright 2015, Dan Book.

This library is free software; you may redistribute it and/or modify it under
the terms of the Artistic License version 2.0.

=head1 SEE ALSO

L<Bot::Maverick>, L<Config::IniFiles>
