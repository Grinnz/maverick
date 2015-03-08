package Bot::ZIRC::Storage;

use Carp;
use File::Path 'make_path';
use File::Spec;

use Moo 2;
use namespace::clean;

has 'data' => (
	is => 'rwp',
	lazy => 1,
	builder => 1,
	init_arg => undef,
);

has 'dir' => (
	is => 'ro',
);

has 'file' => (
	is => 'ro',
	isa => sub { croak "Storage file is unspecified"
		unless defined $_[0] and length $_[0] },
	required => 1,
);

sub _build_data {
	my $self = shift;
	my $dir = $self->dir;
	my $storage_file = $self->file;
	if (defined $dir and length $dir) {
		make_path($dir) if !-e $dir;
		$storage_file = File::Spec->catfile($dir, $storage_file);
	}
	if (-e $storage_file) {
		return $self->_load($storage_file);
	} else {
		return {};
	}
}

sub reload {
	my $self = shift;
	my $dir = $self->dir;
	my $storage_file = $self->file;
	$storage_file = File::Spec->catfile($dir, $storage_file) if defined $dir and length $dir;
	$self->_set_data($self->_load($storage_file));
	return $self;
}

sub store {
	my $dir = $self->dir;
	my $storage_file = $self->file;
	$storage_file = File::Spec->catfile($dir, $storage_file) if defined $dir and length $dir;
	$self->_store($storage_file, $self->data);
	return $self;
}

sub _load {
	my ($self, $file) = @_;
	die "Unable to read storage file $file" unless -r $file;
	open my $fh, '<', $file or die "Unable to read storage file $file: $!\n";
	my $encoded = do { local $/; readline $fh };
	my $data;
	eval { $data = decode_json $encoded; 1 } or die "Invalid storage data: $@";
	die "Storage data is not a hashref" unless ref $data eq 'HASH';
	return $data;
}

sub _store {
	my ($self, $file, $data) = @_;
	my $encoded;
	eval { $encoded = encode_json $data; 1 } or die "Error encoding storage data: $@";
	open my $fh, '>', $file or die "Unable to write storage file $file: $!\n";
	print $fh $encoded;
	return $self;
}

1;
