package Bot::ZIRC::Storage;

use Carp;
use DBM::Deep;
use File::Path 'make_path';
use File::Spec;

use Moo;
use namespace::clean;

has 'data' => (
	is => 'lazy',
	clearer => 1,
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
	my $file = $self->file;
	my $path = $file;
	if (defined $dir and length $dir) {
		make_path($dir) if !-e $dir;
		$path = File::Spec->catfile($dir, $file);
	}
	return DBM::Deep->new($path);
}

sub reload {
	my $self = shift;
	$self->clear_data;
	return $self;
}

1;
