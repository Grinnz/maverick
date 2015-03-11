package Bot::ZIRC::Plugin;

use Carp;
use Scalar::Util 'blessed';
use Moo::Role;

requires 'register';

has 'bot' => (
	is => 'ro',
	isa => sub { croak "Invalid bot object"
		unless blessed $_[0] and $_[0]->isa('Bot::ZIRC') },
	required => 1,
	weak_ref => 1,
	handles => ['ua'],
);

sub require_methods { () }

sub reload {}
sub start {}
sub stop {}

1;
