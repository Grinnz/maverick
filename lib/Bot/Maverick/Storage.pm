package Bot::Maverick::Storage;

use Carp;
use DBM::Deep;
use File::Path 'make_path';
use File::Spec::Functions 'catfile';

use Moo;
use namespace::clean;

our $VERSION = '0.50';

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
		$path = catfile($dir, $file);
	}
	return DBM::Deep->new($path);
}

sub reload {
	my $self = shift;
	$self->clear_data;
	return $self;
}

1;

=head1 NAME

Bot::Maverick::Storage - persistent storage for Maverick

=head1 SYNOPSIS

  my $storage = Bot::Maverick::Storage->new(file => $filename);
  $storage->data->{things} = [1,2,3];
  say $storage->data->{things}[2];

=head1 DESCRIPTION

Database storage engine for L<Bot::Maverick>, using L<DBM::Deep> to store and
retrieve data in perl data structures.

=head1 ATTRIBUTES

=head2 data

L<DBM::Deep> object used to store and retrieve data.

=head2 dir

Directory to store database file.

=head2 file

Filename of database file, required.

=head1 METHODS

=head2 reload

Reloads L</"data"> object.

=head1 BUGS

Report any issues on the public bugtracker.

=head1 AUTHOR

Dan Book, C<dbook@cpan.org>

=head1 COPYRIGHT AND LICENSE

Copyright 2015, Dan Book.

This library is free software; you may redistribute it and/or modify it under
the terms of the Artistic License version 2.0.

=head1 SEE ALSO

L<Bot::Maverick>, L<DBM::Deep>
