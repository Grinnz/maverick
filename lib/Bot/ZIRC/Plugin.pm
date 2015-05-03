package Bot::ZIRC::Plugin;

use Bot::ZIRC;
use Carp;
use Mojo::IOLoop::ForkCall;
use Scalar::Util 'blessed';

use Moo;
use namespace::clean;

our $VERSION = '0.20';

has 'bot' => (
	is => 'ro',
	isa => sub { croak "Invalid bot object"
		unless blessed $_[0] and $_[0]->isa('Bot::ZIRC') },
	lazy => 1,
	default => sub { Bot::ZIRC->new },
	weak_ref => 1,
	handles => [qw/logger ua/],
);

sub register { die "Method must be overloaded by subclass" }

sub require_helpers { () }

sub ua_error {
	my ($self, $err) = @_;
	return $err->{code}
		? "Transport error $err->{code}: $err->{message}\n"
		: "Connection error: $err->{message}\n";
}

sub fork_call {
	my ($self, @args) = @_;
	my $cb = (@args > 1 and ref $args[-1] eq 'CODE') ? pop @args : undef;
	my $fc = Mojo::IOLoop::ForkCall->new;
	return $fc->run(@args, sub {
		my $fc = shift;
		$self->$cb(@_) if $cb;
	});
}

1;
