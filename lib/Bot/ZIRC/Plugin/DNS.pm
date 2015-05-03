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
	my $err;
	{
		local $@;
		eval { require Net::DNS::Native; 1 } or $err = $@;
	}
	if (defined $err) {
		warn $err;
		$self->_set_native(0);
	}
}

sub register {
	my ($self, $bot) = @_;
	
	$bot->add_helper($self, 'dns_resolve');
	$bot->add_helper($self, 'dns_resolve_ips');
	
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
			$self->bot->dns_resolve_ips($hostname, sub {
				my $addrs = shift;
				return $m->reply("No DNS info found for $say_result") unless @$addrs;
				my $addr_list = join ', ', @$addrs;
				$m->reply("DNS results for $say_result: $addr_list");
			})->catch(sub { $m->reply("Failed to resolve $hostname: $_[1]") });
		},
	);
	
	$bot->on(stop => sub { $self->stop });
}

sub dns_resolve {
	my ($self, $host, $cb) = @_;
	croak "No hostname to resolve" unless defined $host;
	unless ($cb) {
		my ($err, @results) = getaddrinfo $host;
		if ($err) {
			chomp $err;
			die "$err\n";
		}
		return \@results;
	}
	croak "Invalid dns_resolve callback" unless ref $cb eq 'CODE';
	return Mojo::IOLoop->delay(sub {
		my $delay = shift;
		if ($self->native) {
			my $dns = $self->resolver;
			my $sock = $dns->getaddrinfo($host);
			$self->watchers->{fileno $sock} = $sock;
			my $next = $delay->begin(0);
			Mojo::IOLoop->singleton->reactor->io($sock, sub {
				Mojo::IOLoop->singleton->reactor->remove($sock);
				delete $self->watchers->{fileno $sock};
				$next->($dns->get_result($sock));
			})->watch($sock, 1, 0);
		} else {
			$delay->pass(getaddrinfo $host);
		}
	}, sub {
		my ($delay, $err, @results) = @_;
		if ($err) {
			chomp $err;
			die "$err\n";
		}
		$cb->(\@results);
	});
}

sub dns_resolve_ips {
	my ($self, $host, $cb) = @_;
	return $self->_ip_results($self->dns_resolve($host)) unless $cb;
	return $self->dns_resolve($host, sub { $cb->($self->_ip_results($_[0])) });
}

sub _ip_results {
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

Adds helper methods for resolving DNS and a C<dns> command to a L<Bot::ZIRC>
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

 my $results = $bot->dns_resolve($hostname);
 $bot->dns_resolve($hostname, sub {
   my $results = shift;
 })->catch(sub { $m->reply("DNS error: $_[1]") });

Attempt to resolve a hostname, returning an arrayref of results in the format
returned by C<getaddrinfo> in L<Socket>. Pass a callback to run the query
non-blocking if possible. Throws an exception on DNS error.

head2 dns_resolve_ips

 my $ips = $bot->dns_resolve_ips($hostname);
 $bot->dns_resolve_ips($hostname, sub {
   my $ips = shift;
 })->catch(sub { $m->reply("DNS error: $_[1]") });

Attempt to resolve a hostname with L</"dns_resolve">, returning an arrayref of
IPv4 and IPv6 address strings with duplicates and other results removed.

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
