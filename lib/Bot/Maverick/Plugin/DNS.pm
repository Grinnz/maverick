package Bot::Maverick::Plugin::DNS;

use Carp;
use Socket qw/AF_INET AF_INET6 getaddrinfo inet_ntop unpack_sockaddr_in unpack_sockaddr_in6/;
use Scalar::Util 'weaken';
use Try::Tiny;

use Moo;
with 'Bot::Maverick::Plugin';

our $VERSION = '0.50';

has 'native' => (
	is => 'rwp',
	lazy => 1,
	coerce => sub { $_[0] ? 1 : 0 },
	default => 1,
);

has '_resolver' => (
	is => 'ro',
	lazy => 1,
	default => sub { Net::DNS::Native->new },
	init_arg => undef,
);

sub BUILD {
	my $self = shift;
	return unless $self->native;
	try { require Net::DNS::Native } catch { warn $_; $self->_set_native(0) };
}

sub register {
	my ($self, $bot) = @_;
	
	$bot->add_helper(dns_native => sub { $self->native });
	$bot->add_helper(_dns_resolver => sub { $self->_resolver });
	$bot->add_helper(dns_resolve => \&_dns_resolve);
	$bot->add_helper(dns_resolve_ips => \&_dns_resolve_ips);
	
	$bot->add_command(
		name => 'dns',
		help_text => 'Resolve the DNS of a user or hostname',
		usage_text => '[<nick>|<hostname>]',
		on_run => sub {
			my $m = shift;
			my ($target) = $m->args_list;
			$target //= $m->sender->nick;
			my ($hostname, $say_result);
			if (exists $m->network->users->{lc $target}) {
				$hostname = $m->network->user($target)->host || 'unknown';
				$say_result = "$target ($hostname)";
			} else {
				$say_result = $hostname = $target;
			}
			
			$m->logger->debug("Resolving $hostname");
			return $m->bot->dns_resolve_ips($hostname)->on_done(sub {
				my $addrs = shift;
				return $m->reply("No DNS info found for $say_result") unless @$addrs;
				my $addr_list = join ', ', @$addrs;
				$m->reply("DNS results for $say_result: $addr_list");
			})->on_fail(sub { $m->reply("Failed to resolve $hostname: $_[0]") });
		},
	);
}

sub _dns_resolve {
	my ($bot, $host) = @_;
	croak "No hostname to resolve" unless defined $host;
	my $future = $bot->new_future;
	if ($bot->dns_native) {
		my $dns = $bot->_dns_resolver;
		my $sock = $dns->getaddrinfo($host);
		$future->on_ready(sub { shift->loop->reactor->remove($sock) });
		weaken(my $weak_f = $future);
		$future->loop->reactor->io($sock, sub {
			my ($err, @results) = $dns->get_result($sock);
			$err ? $weak_f->fail($err) : $weak_f->done(\@results);
		})->watch($sock, 1, 0);
	} else {
		my ($err, @results) = getaddrinfo $host;
		$err ? $future->fail($err) : $future->done(\@results);
	}
	return $future;
}

sub _dns_resolve_ips {
	my ($bot, $host) = @_;
	return $bot->dns_resolve($host)->transform(done => \&_ip_results);
}

sub _ip_results {
	my $results = shift;
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

1;

=head1 NAME

Bot::Maverick::Plugin::DNS - DNS resolver plugin for Maverick

=head1 SYNOPSIS

 my $bot = Bot::Maverick->new(
   plugins => { DNS => 1 },
 );

=head1 DESCRIPTION

Adds helper methods for resolving DNS and a C<dns> command to a
L<Bot::Maverick> IRC bot.

Please note, for non-blocking DNS resolution L<Net::DNS::Native> must be
installed and you must have a perl that is either built with interpreter
threads ("ithreads") or linked to POSIX threads ("pthreads"). See
L<Net::DNS::Native/"INSTALLATION WARNING"> for more details.

=head1 ATTRIBUTES

=head2 native

 my $bot = Bot::Maverick->new(
   plugins => { DNS => { native => 0 } },
 );

If true (default), attempt to use L<Net::DNS::Native> for non-blocking DNS
resolution. If false or if loading L<Net::DNS::Native> fails, DNS resolution
will fallback to a blocking method.

=head1 METHODS

head2 dns_resolve

 my $results = $bot->dns_resolve($hostname)->get;
 my $future = $bot->dns_resolve($hostname)->on_done(sub {
   my $results = shift;
 })->on_fail(sub { $m->reply("DNS error: $_[0]") });

Attempt to resolve a hostname, returning a L<Future::Mojo> with an arrayref of
results in the format returned by C<getaddrinfo> in L<Socket>. The future will
be set to failed on DNS error.

head2 dns_resolve_ips

 my $ips = $bot->dns_resolve_ips($hostname)->get;
 my $future = $bot->dns_resolve_ips($hostname)->on_done(sub {
   my $ips = shift;
 })->on_fail(sub { $m->reply("DNS error: $_[0]") });

Attempt to resolve a hostname with L</"dns_resolve">, returning a
L<Future::Mojo> with the results parsed into an arrayref of IPv4 and IPv6
address strings, with duplicates and other results removed.

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

L<Bot::Maverick>, L<Net::DNS::Native>, L<Socket>
