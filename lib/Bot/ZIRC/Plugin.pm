package Bot::ZIRC::Plugin;

use Carp;
use Scalar::Util 'blessed';

use Moo;
use namespace::clean;

has 'bot' => (
	is => 'ro',
	isa => sub { croak "Invalid bot object"
		unless blessed $_[0] and $_[0]->isa('Bot::ZIRC') },
	required => 1,
	weak_ref => 1,
	handles => ['ua'],
);

sub register { die "Method must be overloaded by subclass" }

sub require_methods { () }

sub reload {}
sub start {}
sub stop {}

sub ua_error {
	my $err = shift;
	return $err->{code}
		? "Transport error $err->{code}: $err->{message}"
		: "Connection error: $err->{message}";
}

1;
