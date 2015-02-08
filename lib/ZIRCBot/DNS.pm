package ZIRCBot::DNS;

use Mojo::IOLoop;
use Net::DNS::Native;
use Scalar::Util 'weaken';

use Moo::Role;
use warnings NONFATAL => 'all';

has 'resolver' => (
	is => 'lazy',
	init_arg => undef,
);

has 'watchers' => (
	is => 'ro',
	lazy => 1,
	default => sub { {} },
	init_arg => undef,
	clearer => 1,
);

sub _build_resolver {
	my $self = shift;
	return Net::DNS::Native->new;
}

after 'stop' => sub {
	my $self = shift;
	foreach my $sock (values %{$self->watchers}) {
		Mojo::IOLoop->singleton->reactor->remove($sock);
	}
	$self->clear_watchers;
};

sub dns_resolve {
	my ($self, $host, $cb) = @_;
	
	my $dns = $self->resolver;
	my $sock = $dns->getaddrinfo($host);
	$self->watchers->{fileno $sock} = $sock;
	weaken $self;
	Mojo::IOLoop->singleton->reactor->io($sock, sub {
		Mojo::IOLoop->singleton->reactor->remove($sock);
		delete $self->watchers->{fileno $sock};
		$self->$cb($dns->get_result($sock));
	})->watch($sock, 1, 0);
	Mojo::IOLoop->start unless Mojo::IOLoop->is_running;
}

1;
