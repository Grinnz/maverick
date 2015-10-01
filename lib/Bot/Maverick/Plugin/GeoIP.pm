package Bot::Maverick::Plugin::GeoIP;

use Carp 'croak';
use Data::Validate::IP qw/is_ipv4 is_ipv6/;
use GeoIP2::Database::Reader;
use Scalar::Util 'blessed';

use Moo;
with 'Bot::Maverick::Plugin';

our $VERSION = '0.20';

use constant GEOIP_FILE_MISSING =>
	"GeoIP plugin requires a readable GeoLite2 City database file located by the configuration option 'geoip_file' in section 'apis'\n" .
	"See http://dev.maxmind.com/geoip/geoip2/geolite2/ for more information on obtaining a GeoLite2 City database file.\n";

has '_geoip' => (
	is => 'lazy',
	init_arg => undef,
);

sub _build__geoip {
	my $self = shift;
	my $file = $self->bot->config->param('apis', 'geoip_file');
	die GEOIP_FILE_MISSING unless defined $file and length $file and -r $file;
	my ($geoip, $err);
	{
		local $@;
		if (eval { $geoip = GeoIP2::Database::Reader->new(file => $file); 1 }) {
			return $geoip;
		} else {
			$err = $@;
		}
	}
	die $err;
}

sub register {
	my ($self, $bot) = @_;
	my $file = $bot->config->param('apis','geoip_file');
	die GEOIP_FILE_MISSING unless defined $file and length $file and -r $file;
	
	$bot->add_helper(_geoip_resolver => sub { $self->_geoip });
	$bot->add_helper(geoip_locate => \&_geoip_locate);
	$bot->add_helper(geoip_locate_host => \&_geoip_locate_host);
	
	$bot->add_command(
		name => 'locate',
		help_text => 'Locate user or hostname based on IP address',
		usage_text => '[<nick>|<hostname>]',
		on_run => sub {
			my $m = shift;
			my ($target) = $m->args_list;
			$target //= $m->sender->nick;
			my $say_target = my $host = $target;
			if (exists $m->network->users->{lc $target}) {
				$host = $m->network->user($target)->host;
				return $m->reply("Could not find hostname for $target")
					unless defined $host;
				$say_target = "$target ($host)";
			}
			
			return $m->bot->geoip_locate_host($host)->on_done(sub {
				my $record = shift;
				$m->reply("GeoIP location for $say_target: " . _location_str($record));
			})->on_fail(sub { $m->reply("Error locating $say_target: $_[0]") });
		},
	);
}

sub _geoip_locate {
	my ($bot, $ip) = @_;
	die "Invalid IP address $ip\n" unless defined $ip and (is_ipv4 $ip or is_ipv6 $ip);
	my ($record, $err, $errored);
	{
		local $@;
		eval { $record = $bot->_geoip_resolver->city(ip => $ip); 1 } or $errored = 1;
		$err = $@ if $errored;
	}
	if ($errored) {
		die $err->message."\n" if blessed $err and $err->isa('Throwable::Error');
		chomp $err;
		die "$err\n";
	}
	return $record;
}

sub _geoip_locate_host {
	my ($bot, $host) = @_;
	croak 'Undefined hostname' unless defined $host;
	if (is_ipv4 $host or is_ipv6 $host) {
		my $record;
		local $@;
		if (eval { $record = $bot->geoip_locate($host); 1 }) {
			return $bot->new_future->done($record);
		} else {
			chomp(my $err = $@);
			return $bot->new_future->fail($err);
		}
	}
	return $bot->new_future->fail('DNS plugin is required to resolve hostnames')
		unless $bot->has_helper('dns_resolve_ips');
	return $bot->dns_resolve_ips($host)->then(sub {
		my $addrs = shift;
		return $bot->new_future->fail('No DNS results') unless @$addrs;
		my $last_err = 'No valid DNS results';
		my $best_record;
		foreach my $addr (@$addrs) {
			next unless is_ipv4 $addr or is_ipv6 $addr;
			my $record;
			local $@;
			if (eval { $record = $bot->geoip_locate($addr); 1 }) {
				return $bot->new_future->done($record) if defined $record->city->name;
				$best_record //= $record;
			} else {
				chomp($last_err = $@);
			}
		}
		return $bot->new_future->fail($last_err) unless defined $best_record;
		return $bot->new_future->done($best_record);
	});
}

sub _location_str {
	my $record = shift // croak 'No location record passed';
	my @subdivisions = reverse map { $_->name } $record->subdivisions;
	my @location_parts = grep { defined } $record->city->name, @subdivisions, $record->country->name;
	return join ', ', @location_parts;
}

1;

=head1 NAME

Bot::Maverick::Plugin::GeoIP - Geolocation plugin for Maverick

=head1 SYNOPSIS

 my $bot = Bot::Maverick->new(
   plugins => { GeoIP => 1 },
 );

=head1 DESCRIPTION

Adds helper methods for geolocating IP addresses and a C<locate> command to a
L<Bot::Maverick> IRC bot.

This plugin requires that a MaxMind GeoLite2 City database file (binary format)
is present, with the path in the configuration option C<geoip_file> in the
C<apis> section. See L<http://dev.maxmind.com/geoip/geoip2/geolite2/> to obtain
this database file.

For faster GeoIP lookups, you may install L<MaxMind::DB::Reader::XS> which
requires the libmaxminddb library; it will be automatically used if present.

=head1 METHODS

=head2 geoip_locate

 my $record = $bot->geoip_locate($ip);

Attempt to locate an IP address in the GeoIP database. Returns the GeoIP record
as a L<GeoIP2::Model::City> object. Throws an exception on error.

=head2 geoip_locate_host

 my $record = $bot->geoip_locate_host($hostname);
 $bot->geoip_locate_host($hostname, sub {
   my $record = shift;
 })->catch(sub { $m->reply("Error locating $hostname: $_[1]") });

Attempt to resolve a hostname and locate the resulting IP address in the GeoIP
database with L</"geoip_locate">. If a callback is passed, non-blocking DNS
resolution will be used if available. Throws an exception on error. Requires
the L<Bot::Maverick::Plugin::DNS> plugin.

=head1 COMMANDS

=head2 locate

 !locate 8.8.8.8
 !locate google.com
 !locate Fred

Attempt to geolocate an IP address. If given a hostname or known user nick,
and the C<DNS> plugin is loaded, that hostname will first be resolved to an
IP address. Defaults to locating the sender.

=head1 BUGS

Report any issues on the public bugtracker.

=head1 AUTHOR

Dan Book, C<dbook@cpan.org>

=head1 COPYRIGHT AND LICENSE

Copyright 2015, Dan Book.

This library is free software; you may redistribute it and/or modify it under
the terms of the Artistic License version 2.0.

=head1 SEE ALSO

L<Bot::Maverick>, L<Bot::Maverick::Plugin::DNS>, L<GeoIP2::Database::Reader>
