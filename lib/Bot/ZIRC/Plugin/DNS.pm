package Bot::ZIRC::Plugin::DNS;

use Carp;
use Mojo::IOLoop;
use Socket qw/AF_INET AF_INET6 getaddrinfo inet_ntop unpack_sockaddr_in unpack_sockaddr_in6/;

use Moo 2;
use namespace::clean;

with 'Bot::ZIRC::Plugin';

has 'native' => (
	is => 'rwp',
	lazy => 1,
	coerce => sub { $_[0] ? 1 : 0 },
	default => 1,
);

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

sub BUILD {
	my $self = shift;
	return unless $self->native;
	eval { require Net::DNS::Native };
	if ($@) {
		warn $@;
		$self->_set_native(0);
	}
}

sub dns_resolve {
	my ($self, $host, $cb) = @_;
	croak "No hostname to resolve" unless defined $host;
	if ($self->native and $cb) {
		croak "Invalid dns_resolve callback" unless ref $cb eq 'CODE';
		my $dns = $self->resolver;
		my $sock = $dns->getaddrinfo($host);
		$self->watchers->{fileno $sock} = $sock;
		Mojo::IOLoop->singleton->reactor->io($sock, sub {
			Mojo::IOLoop->singleton->reactor->remove($sock);
			delete $self->watchers->{fileno $sock};
			$cb->($dns->get_result($sock));
		})->watch($sock, 1, 0);
	} elsif ($cb) {
		$cb->(getaddrinfo $host);
	} else {
		return getaddrinfo $host;
	}
	return undef;
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
	return unless $self->native;
	foreach my $sock (values %{$self->watchers}) {
		Mojo::IOLoop->singleton->reactor->remove($sock);
	}
	$self->clear_watchers;
}

1;
