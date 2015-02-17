package Bot::ZIRC::Plugin::DNSNative;

use Mojo::IOLoop;
use Net::DNS::Native;
use Socket qw/AF_INET AF_INET6 inet_ntop unpack_sockaddr_in unpack_sockaddr_in6/;

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
	my ($self, $host, $cb) = @_;
	my $dns = $self->resolver;
	my $sock = $dns->getaddrinfo($host);
	$self->watchers->{fileno $sock} = $sock;
	Mojo::IOLoop->singleton->reactor->io($sock, sub {
		Mojo::IOLoop->singleton->reactor->remove($sock);
		delete $self->watchers->{fileno $sock};
		$cb->($dns->get_result($sock)) if $cb;
	})->watch($sock, 1, 0);
	return $self;
}

sub register {
	my ($self, $bot) = @_;
	
	$bot->add_plugin_method($self, 'dns_resolve');
	
	$bot->add_command(
		name => 'dns',
		help_text => 'Resolve the DNS of a user or hostname',
		usage_text => '[<nick>|<hostname>]',
		on_run => sub {
			my ($network, $sender, $channel, $target) = @_;
			$target //= "$sender";
			my ($hostname, $say_result);
			if (exists $network->users->{lc $target}) {
				$hostname = $network->user($target)->host || 'unknown';
				$say_result = "$target ($hostname)";
			} else {
				$say_result = $hostname = $target;
			}
			
			$network->logger->debug("Resolving $hostname");
			$network->bot->dns_resolve($hostname, sub {
				my ($err, @results) = @_;
				return $network->reply($sender, $channel, "Failed to resolve $hostname: $err") if $err;
				my %results;
				foreach my $result (@results) {
					next unless $result->{family} == AF_INET or $result->{family} == AF_INET6;
					my $unpacked = $result->{family} == AF_INET6
						? unpack_sockaddr_in6 $result->{addr}
						: unpack_sockaddr_in $result->{addr};
					my $addr = inet_ntop $result->{family}, $unpacked;
					$results{$addr} = 1 if $addr;
				}
				return $network->reply($sender, $channel, "No DNS info found for $say_result") unless %results;
				my $addr_list = join ', ', sort keys %results;
				$network->reply($sender, $channel, "DNS results for $say_result: $addr_list");
			});
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
