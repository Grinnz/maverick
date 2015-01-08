package ZIRCBot::DNS;

use POE qw/Component::Client::DNS/;

use Moo::Role;
use warnings NONFATAL => 'all';

my @dns_events = qw/dns_response/;
sub get_dns_events { @dns_events }

sub _build_resolver {
	my $self = shift;
	return POE::Component::Client::DNS->spawn;
}

after 'hook_stop' => sub {
	my $self = shift;
	$self->resolver->shutdown;
};

sub dns_resolve {
	my $self = shift;
	my ($host, $type, $context) = @_;
	return unless defined $host;
	
	$context //= {};
	
	my %options;
	$options{host} = $host;
	$options{type} = $type if defined $type;
	$options{context} = $context;
	$options{event} = 'dns_response';
	
	my $response = $self->resolver->resolve(%options);
	
	if ($response) {
		POE::Kernel->yield(dns_response => $response);
	}
}

sub dns_response {
	my $self = $_[OBJECT];
	my $response = $_[ARG0];
}

1;
