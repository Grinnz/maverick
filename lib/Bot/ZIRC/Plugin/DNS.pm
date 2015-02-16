package Bot::ZIRC::Plugin::DNS;

use Mojo::IOLoop;
use Net::DNS::Native;
use Scalar::Util 'weaken';

use Moo;
use warnings NONFATAL => 'all';
use namespace::clean;

with 'Bot::ZIRC::Plugin';

has 'resolver' => (
	is => 'ro',
	lazy => 1,
	default => sub { Net::DNS::Native->new },
	init_arg => undef,
);

has 'watchers' => (
	is => 'ro',
	lazy => 1,
	default => sub { {} },
	init_arg => undef,
	clearer => 1,
);

sub dns_resolve {
	my ($self, $host, $future) = @_;
	
	my $dns = $self->resolver;
	my $sock = $dns->getaddrinfo($host);
	$self->watchers->{fileno $sock} = $sock;
	weaken $self;
	Mojo::IOLoop->singleton->reactor->io($sock, sub {
		Mojo::IOLoop->singleton->reactor->remove($sock);
		delete $self->watchers->{fileno $sock};
		$future->done($dns->get_result($sock));
	})->watch($sock, 1, 0);
}

sub register {
	my ($self, $bot) = @_;
	
	$bot->add_command(
		name => 'dns',
		help_text => 'Resolve the DNS of a user or hostname',
		usage_text => '(<nick>|<hostname>)',
		on_run => sub {
			my ($network, $sender, $channel, $target) = @_;
			return 'usage' unless $target;
			
		},
	);
}

sub stop {
	my $self = shift;
	foreach my $sock (values %{$self->watchers}) {
		Mojo::IOLoop->singleton->reactor->remove($sock);
	}
	$self->clear_watchers;
}

1;
