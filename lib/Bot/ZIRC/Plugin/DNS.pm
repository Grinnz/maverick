package Bot::ZIRC::Plugin::DNS;

use Carp;
use Mojo::IOLoop;
use Socket qw/AF_INET AF_INET6 getaddrinfo inet_ntop unpack_sockaddr_in unpack_sockaddr_in6/;

use Moo;
extends 'Bot::ZIRC::Plugin';

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

sub dns_ip_results {
	my ($self, $results) = @_;
	my %found;
	my @parsed;
	foreach my $result (@$results) {
		next unless defined $result and defined $result->{family} and defined $result->{addr};
		next unless $result->{family} == AF_INET or $result->{family} == AF_INET6;
		my $unpacked = $result->{family} == AF_INET6
			? unpack_sockaddr_in6 $result->{addr}
			: unpack_sockaddr_in $result->{addr};
		my $addr = inet_ntop $result->{family}, $unpacked;
		push @parsed, $addr unless $found{$addr};
		$found{$addr} = 1;
	}
	return \@parsed;
}

sub register {
	my ($self, $bot) = @_;
	
	$bot->add_plugin_method($self, 'dns_resolve');
	$bot->add_plugin_method($self, 'dns_ip_results');
	
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
			$self->bot->dns_resolve($hostname, sub {
				my ($err, @results) = @_;
				return $network->reply($sender, $channel, "Failed to resolve $hostname: $err") if $err;
				my $addrs = $self->bot->dns_ip_results(\@results);
				return $network->reply($sender, $channel, "No DNS info found for $say_result") unless @$addrs;
				my $addr_list = join ', ', @$addrs;
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

=head1 NAME

Bot::ZIRC::Plugin::DNS - DNS resolver plugin for Bot::ZIRC

=head1 SYNOPSIS

 my $bot = Bot::ZIRC->new(
   plugins => { DNS => 1 },
 );

=head1 DESCRIPTION

Adds plugin methods for resolving DNS and a C<dns> command to a L<Bot::ZIRC>
IRC bot.

Please note, for non-blocking DNS resolution L<Net::DNS::Native> must be
installed and you must have a perl that is either built with interpreter
threads ("ithreads") or linked to POSIX threads ("pthreads"). See
L<Net::DNS::Native/"INSTALLATION WARNING"> for more details.

=head1 ATTRIBUTES

=head2 native

 my $bot = Bot::ZIRC->new(
   plugins => { DNS => { native => 0 } },
 );

If true (default), attempt to use L<Net::DNS::Native> for non-blocking DNS
resolution. If false or if loading L<Net::DNS::Native> fails, DNS resolution
will fallback to a blocking method.

=head1 METHODS

head2 dns_resolve

 my ($err, $results) = $bot->dns_resolve($hostname);
 $bot->dns_resolve($hostname, sub {
   my ($err, $results) = @_;
 });

Attempt to resolve a hostname, returning any error as the first return value
and an arrayref of results as the second return value, in the format returned
by C<getaddrinfo> in L<Socket>.

head2 dns_ip_results

 my $ips = $bot->dns_ip_results($results);

Translate an arrayref of C<getaddrinfo> results such as returned by
L</"dns_resolve"> into an arrayref of IPv4 or IPv6 address strings, removing
duplicates and unknown results.

=head1 COMMANDS

=head2 dns

 !dns google.com
 !dns Fred

Attempt to resolve the IP address(es) of a hostname. If given a known user
nick, uses their hostname. Defaults to using sender's hostname.

=head1 BUGS

Report any issues on the public bugtracker.

=head1 AUTHOR

Dan Book, C<dbook@cpan.org>

=head1 COPYRIGHT AND LICENSE

Copyright 2015, Dan Book.

This library is free software; you may redistribute it and/or modify it under
the terms of the Artistic License version 2.0.

=head1 SEE ALSO

L<Bot::ZIRC>, L<Net::DNS::Native>, L<Socket>
