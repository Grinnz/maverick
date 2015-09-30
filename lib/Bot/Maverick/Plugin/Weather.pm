package Bot::Maverick::Plugin::Weather;

use Carp 'croak';
use Future;
use Mojo::IOLoop;
use Mojo::URL;
use Scalar::Util 'looks_like_number';

use Moo;
with 'Bot::Maverick::Plugin';

our $VERSION = '0.20';

use constant WEATHER_API_ENDPOINT => 'http://api.wunderground.com/api/';
use constant WEATHER_API_AUTOCOMPLETE_ENDPOINT => 'http://autocomplete.wunderground.com/aq';
use constant WEATHER_API_KEY_MISSING =>
	"Weather plugin requires configuration option 'wunderground_api_key' in section 'apis'\n" .
	"See http://www.wunderground.com/weather/api for more information on obtaining a Weather Underground API key.\n";
use constant WEATHER_CACHE_EXPIRATION => 600;

has 'api_key' => (
	is => 'rw',
);

has '_weather_cache' => (
	is => 'ro',
	lazy => 1,
	default => sub { {} },
	init_arg => undef,
);

sub register {
	my ($self, $bot) = @_;
	$self->api_key($bot->config->param('apis','wunderground_api_key')) unless defined $self->api_key;
	die WEATHER_API_KEY_MISSING unless defined $self->api_key;
	
	$bot->add_helper(weather_api_key => sub { $self->api_key });
	$bot->add_helper(weather_cache => sub { $self->_weather_cache });
	$bot->add_helper(weather_autocomplete_location_code => \&_weather_autocomplete_location_code);
	$bot->add_helper(weather_location_data => \&_weather_location_data);
	
	$bot->add_command(
		name => 'weather',
		help_text => 'Display current weather conditions for a location or user',
		usage_text => '[<nick>|<location>]',
		on_run => sub {
			my $m = shift;
			my $target = $m->args;
			$target = $m->sender unless length $target;
			my $future;
			if (exists $m->network->users->{lc $target} and $m->bot->has_helper('geoip_locate_host')) {
				my $hostname = $m->network->user($target)->host;
				return $m->reply("Unable to find hostname for target") unless defined $hostname;
				$future = $m->bot->geoip_locate_host($hostname)->then(sub {
					my $record = shift;
					my @location_parts = ($record->city->name);
					push @location_parts, $record->country->iso_code eq 'US'
						? $record->most_specific_subdivision->iso_code : $record->country->name;
					my $location = join ', ', grep { defined } @location_parts;
					return Future->done($location);
				});
			} else {
				$future = Future->done($target);
			}
			return $future->then(sub {
				my $location = shift;
				return $m->bot->weather_autocomplete_location_code($location);
			})->then(sub {
				my $code = shift;
				return $m->bot->weather_location_data($code);
			})->on_done(sub {
				my $data = shift;
				_display_weather($m, $data);
			})->on_fail(sub { $m->reply("Error retrieving weather for $target: $_[0]") });
		},
	);
	
	$bot->add_command(
		name => 'forecast',
		help_text => 'Display weather forecast for a location or user',
		usage_text => '[<nick>|<location>] [<days>]',
		on_run => sub {
			my $m = shift;
			my $target = $m->args;
			my $max_days = 4;
			if ($target =~ s/(?:^|\s+)(\d)$//) {
				$max_days = $1;
			}
			$target = $m->sender unless length $target;
			my $future;
			if (exists $m->network->users->{lc $target} and $m->bot->has_helper('geoip_locate_host')) {
				my $hostname = $m->network->user($target)->host;
				return $m->reply("Unable to find hostname for target") unless defined $hostname;
				$future = $m->bot->geoip_locate_host($hostname)->then(sub {
					my $record = shift;
					my @location_parts = ($record->city->name);
					push @location_parts, $record->country->iso_code eq 'US'
						? $record->most_specific_subdivision->iso_code : $record->country->name;
					my $location = join ', ', grep { defined } @location_parts;
					return Future->done($location);
				});
			} else {
				$future = Future->done($target);
			}
			return $future->then(sub {
				my $location = shift;
				return $m->bot->weather_autocomplete_location_code($location);
			})->then(sub {
				my $code = shift;
				return $m->bot->weather_location_data($code);
			})->on_done(sub {
				my $data = shift;
				_display_forecast($m, $data, $max_days);
			})->on_fail(sub { $m->reply("Error retrieving forecast for $target: $_[0]") });
		},
	);
}

sub _weather_autocomplete_location_code {
	my ($bot, $query) = @_;
	my $url = Mojo::URL->new(WEATHER_API_AUTOCOMPLETE_ENDPOINT)->query(h => 0, query => $query);
	my $future = Future->new;
	$bot->ua->get($url, sub {
		my ($ua, $tx) = @_;
		return $future->fail($bot->ua_error($tx->error)) if $tx->error;
		my $code = _autocomplete_location_code($tx->res->json) // return $future->fail('Location not found');
		$future->done($code);
	});
	return $future;
}

sub _autocomplete_location_code {
	my ($response) = @_;
	my $locations = $response->{RESULTS} // return undef;
	foreach my $location (@$locations) {
		my ($type, $lat, $lon, $l) = @{$location}{'type','lat','lon','l'};
		next unless $type eq 'city' and defined $lat and $lat >= -90 and $lat <= 90
			and defined $lon and $lon >= -180 and $lon <= 180
			and defined $l and $l =~ m!/q/(.+)!;
		return $1;
	}
	return undef;
}

sub _weather_location_data {
	my ($bot, $code) = @_;
	croak 'Undefined location code' unless defined $code;
	
	my $cached = $bot->weather_cache->{$code};
	if (defined $cached and $cached->{expiration} > time) {
		return Future->done($cached);
	}
	
	die WEATHER_API_KEY_MISSING unless defined $bot->weather_api_key;
	my $url = Mojo::URL->new(WEATHER_API_ENDPOINT)
		->path($bot->weather_api_key."/conditions/forecast/geolookup/q/$code.json");
	my $future = Future->new;
	$bot->ua->get($url, sub {
		my ($ua, $tx) = @_;
		return $future->fail($bot->ua_error($tx->error)) if $tx->error;
		$future->done(_cache_location_data($bot, $code, $tx->res->json));
	});
	return $future;
}

sub _cache_location_data {
	my ($bot, $code, $results) = @_;
	$bot->weather_cache->{$code} = {
		location => $results->{location},
		forecast => $results->{forecast},
		current_observation => $results->{current_observation},
		expiration => time + WEATHER_CACHE_EXPIRATION,
	};
	return $bot->weather_cache->{$code};
}

sub _display_weather {
	my ($m, $data) = @_;
	
	my $location = $data->{location} // $data->{current_observation}{display_location};
	my $location_str = _location_string($location);
	
	my @weather_strings;
	my $current = $data->{current_observation} // {};
	
	my $condition = $current->{weather};
	push @weather_strings, $condition if defined $condition;
	
	my ($temp_f, $temp_c) = @{$current}{'temp_f','temp_c'};
	push @weather_strings, sprintf "%s\xB0F / %s\xB0C",
		$temp_f // '', $temp_c // ''
		if defined $temp_f or defined $temp_c;
	
	my ($feelslike_f, $feelslike_c) = @{$current}{'feelslike_f','feelslike_c'};
	push @weather_strings, sprintf "Feels like %s\xB0F / %s\xB0C",
		$feelslike_f // '', $feelslike_c // ''
		if (defined $feelslike_f or defined $feelslike_c)
		and ($feelslike_f ne $temp_f or $feelslike_c ne $temp_c);
	
	my $precip_in = $current->{precip_today_in};
	push @weather_strings, "Precipitation $precip_in\""
		if looks_like_number $precip_in and $precip_in > 0;
	
	my $wind_speed = $current->{wind_mph};
	my $wind_dir = $current->{wind_dir};
	if (defined $wind_speed) {
		my $wind_str = "Wind ${wind_speed}mph";
		$wind_str = "$wind_str $wind_dir" if defined $wind_dir;
		push @weather_strings, $wind_str
			if looks_like_number $wind_speed and $wind_speed > 0;
	}
	
	my $weather_str = join '; ', @weather_strings;
	
	my $b_code = chr 2;
	$m->reply("Current weather at $b_code$location_str$b_code: $weather_str");
}

sub _display_forecast {
	my ($m, $data, $max_days) = @_;
	
	my $location_str = _location_string($data->{location});
	my @forecast_strings;
	my $forecast_days = $data->{forecast}{simpleforecast}{forecastday};
	$max_days = @$forecast_days if $max_days > @$forecast_days;
	
	my $b_code = chr 2;
	
	foreach my $i (0..$max_days-1) {
		my $day = $forecast_days->[$i] // next;
		my $day_name = $day->{date}{weekday} // '';
		
		my @day_strings;
		my $conditions = $day->{conditions};
		push @day_strings, $conditions if defined $conditions;
		
		my $high = $day->{high};
		if (defined $high) {
			my ($high_f, $high_c) = @{$high}{'fahrenheit','celsius'};
			push @day_strings, sprintf "High %s\xB0F / %s\xB0C",
				$high_f // '', $high_c // '';
		}
		
		my $low = $day->{low};
		if (defined $low) {
			my ($low_f, $low_c) = @{$low}{'fahrenheit','celsius'};
			push @day_strings, sprintf "Low %s\xB0F / %s\xB0C",
				$low_f // '', $low_c // '';
		}
		
		my $day_string = join ', ', @day_strings;
		push @forecast_strings, "$b_code$day_name$b_code: $day_string";
	}
	
	my $forecast_str = join '; ', @forecast_strings;
	$m->reply("Weather forecast for $b_code$location_str$b_code: $forecast_str");
}

sub _location_string {
	my $location = shift // return '';
	my ($city, $state, $zip, $country) = @{$location}{'city','state','zip','country_name'};
	my $location_str = $city // '';
	$location_str .= ", $state" if defined $state and length $state;
	$location_str .= ", $country" if defined $country and length $country;
	$location_str .= " ($zip)" if defined $zip and length $zip and $zip ne '00000';
	return $location_str;
}

1;

=head1 NAME

Bot::Maverick::Plugin::Weather - Weather plugin for Maverick

=head1 SYNOPSIS

 my $bot = Bot::Maverick->new(
   plugins => { Weather => 1 },
 );
 
 # Standalone usage
 my $weather = Bot::Maverick::Plugin::Weather->new(api_key => $api_key);
 my ($err, $location_code) = $weather->weather_autocomplete_location_code($location);
 my ($err, $data) = $weather->weather_location_data($location_code);

=head1 DESCRIPTION

Adds helper methods and commands for retrieving weather and forecast data to a
L<Bot::Maverick> IRC bot.

This plugin requires a Weather Underground API key as the configuration option
C<wunderground_api_key> in the C<apis> section. See
L<http://www.wunderground.com/weather/api> for information on obtaining a
Weather Underground API key.

=head1 ATTRIBUTES

=head2 api_key

API key for Weather Underground API, defaults to value of configuration option
C<wunderground_api_key> in section C<apis>.

=head1 METHODS

=head2 weather_autocomplete_location_code

 my $code = $bot->weather_autocomplete_location_code($query);
 $bot->weather_autocomplete_location_code($query, sub {
   my $code = shift;
 })->catch(sub { $m->reply("Error locating $query: $_[1]") });

Attempt to find a location based on a string. Returns the location code on
success, or throws an exception on error. Pass a callback to perform the query
non-blocking.

=head2 weather_location_data

 my $data = $bot->weather_location_data($code);
 $bot->weather_location_data($code, sub {
   my $data = shift;
 })->catch(sub { $m->reply("Error retrieving weather data: $_[1]") });

Retrieve the weather and forecast data for a location code. Returns a hashref
containing the weather data, consisting of C<location>, C<current_observation>,
and C<forecast>. Throws an exception on error. Pass a callback to perform the
query non-blocking.

=head1 COMMANDS

=head2 weather

 !weather Topeka
 !weather Winnipeg, MB
 !weather 90210
 !weather Cooldude

Retrieve and display current weather information for a location. If a known
nick is given and the L<Bot::Maverick::Plugin::GeoIP> plugin is loaded, that
user's hostname will be geolocated. Defaults to the location of the sender.

=head2 forecast

 !forecast Cooldude
 !forecast Albuquerque 2

Retrieve and display weather forcast for a location. If a known nick is given
and the L<Bot::Maverick::Plugin::GeoIP> plugin is loaded, that user's hostname
will be geolocated. Defaults to the location of the user. Optionally, the
number of forecast days to return can be specified, up to the API's current
limit of 4 days.

=head1 BUGS

Report any issues on the public bugtracker.

=head1 AUTHOR

Dan Book, C<dbook@cpan.org>

=head1 COPYRIGHT AND LICENSE

Copyright 2015, Dan Book.

This library is free software; you may redistribute it and/or modify it under
the terms of the Artistic License version 2.0.

=head1 SEE ALSO

L<Bot::Maverick>
