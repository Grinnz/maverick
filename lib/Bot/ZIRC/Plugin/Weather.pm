package Bot::ZIRC::Plugin::Weather;

use Carp;
use Mojo::IOLoop;
use Mojo::URL;
use Scalar::Util 'looks_like_number';

use Moo 2;
use namespace::clean;

use constant WEATHER_API_ENDPOINT => 'http://api.wunderground.com/api/';
use constant WEATHER_API_AUTOCOMPLETE_ENDPOINT => 'http://autocomplete.wunderground.com/aq';
use constant WEATHER_API_KEY_MISSING =>
	"Weather plugin requires configuration option 'wunderground_api_key' in section 'apis'\n" .
	"See http://www.wunderground.com/weather/api for more information on obtaining a Weather Underground API key.\n";
use constant WEATHER_CACHE_EXPIRATION => 600;

with 'Bot::ZIRC::Plugin';

has 'weather_cache' => (
	is => 'ro',
	lazy => 1,
	default => sub { {} },
	init_arg => undef,
);

sub register {
	my ($self, $bot) = @_;
	my $api_key = $bot->config->get('apis','wunderground_api_key');
	die WEATHER_API_KEY_MISSING unless defined $api_key;
	
	$bot->add_command(
		name => 'weather',
		help_text => 'Display current weather conditions for a location or user',
		usage_text => '[<nick>|<location>]',
		tokenize => 0,
		on_run => sub {
			my ($network, $sender, $channel, $target) = @_;
			$target = $sender unless length $target;
			if (exists $network->users->{lc $target}) {
				return $network->reply($sender, $channel, "GeoIP plugin is required to display weather for a user")
					unless $network->bot->has_plugin_method('geoip_locate_host');
				my $hostname = $network->user($target)->host;
				return $network->reply($sender, $channel, "Unable to find hostname for $target")
					unless defined $hostname;
				
				Mojo::IOLoop->delay(sub {
					$network->bot->geoip_locate_host($hostname, shift->begin(0));
				}, sub {
					my ($delay, $err, $record) = @_;
					return $network->reply($sender, $channel, "Error locating $target: $err") if $err;
					my @location_parts = ($record->city->name);
					push @location_parts, $record->country->iso_code eq 'US'
						? $record->most_specific_subdivision->iso_code : $record->country->name;
					my $location = join ', ', grep { defined } @location_parts;
					$self->weather_autocomplete_location_code($location, $delay->begin(0));
				}, sub {
					my ($delay, $err, $code) = @_;
					return $network->reply($sender, $channel, "Error locating $target: $err") if $err;
					$self->weather_location_data($code, $delay->begin(0));
				}, sub {
					my ($delay, $err, $data) = @_;
					return $network->reply($sender, $channel, "Error retrieving weather data for $target: $err") if $err;
					return display_weather($network, $channel, $sender, $data);
				});
			} else {
				Mojo::IOLoop->delay(sub {
					$self->weather_autocomplete_location_code($target, shift->begin(0));
				}, sub {
					my ($delay, $err, $code) = @_;
					return $network->reply($sender, $channel, "Error locating $target: $err") if $err;
					$self->weather_location_data($code, $delay->begin(0));
				}, sub {
					my ($delay, $err, $data) = @_;
					return $network->reply($sender, $channel, "Error retrieving weather data for $target: $err") if $err;
					return display_weather($network, $channel, $sender, $data);
				});
			}
		},
	);
}

sub weather_autocomplete_location_code {
	my ($self, $query, $cb) = @_;
	my $url = Mojo::URL->new(WEATHER_API_AUTOCOMPLETE_ENDPOINT)->query(h => 0, query => $query);
	$self->ua->get($url, sub {
		my ($ua, $tx) = @_;
		if (my $err = $tx->error) {
			return $cb->($err->{code}
				? "$err->{code} response: $err->{message}"
				: "Connection error: $err->{message}");
		}
		my $locs = $tx->res->json->{RESULTS};
		return $cb->('No results') unless defined $locs;
		foreach my $loc (@$locs) {
			next unless $loc->{type} eq 'city' and defined $loc->{lat} and defined $loc->{lon}
				and $loc->{lat} >= -90 and $loc->{lat} <= 90
				and $loc->{lon} >= -180 and $loc->{lon} <= 180
				and defined $loc->{l} and $loc->{l} =~ m!/q/(.+)!;
			return $cb->(undef, $1);
		}
		return $cb->('No results');
	});
}

sub weather_location_data {
	my ($self, $code, $cb) = @_;
	my $cached = $self->weather_cache->{$code};
	return $cb->(undef, $cached) if defined $cached and $cached->{expiration} <= time;
	
	my $api_key = $self->bot->config->get('apis','wunderground_api_key');
	die WEATHER_API_KEY_MISSING unless defined $api_key;
	my $url = Mojo::URL->new(WEATHER_API_ENDPOINT)->path("$api_key/conditions/forecast/geolookup/q/$code.json");
	$self->ua->get($url, sub {
		my ($ua, $tx) = @_;
		if (my $err = $tx->error) {
			return $cb->($err->{code}
				? "$err->{code} response: $err->{message}"
				: "Connection error: $err->{message}");
		}
		my $results = $tx->res->json;
		$self->weather_cache->{$code} = {
			location => $results->{location},
			forecast => $results->{forecast},
			current_observation => $results->{current_observation},
			expiration => time + WEATHER_CACHE_EXPIRATION,
		};
		$cb->(undef, $self->weather_cache->{$code});
	});
}

sub display_weather {
	my ($network, $channel, $sender, $data) = @_;
	
	my $location = $data->{location} // $data->{current_observation}{display_location};
	my $location_str = '';
	if (defined $location) {
		my ($city, $state, $zip, $country) = @{$location}{'city','state','zip','country_name'};
		$location_str .= $city if defined $city;
		$location_str .= ", $state" if defined $state and length $state;
		$location_str .= ", $country" if defined $country and length $country;
		$location_str .= " ($zip)" if defined $zip and length $zip and $zip ne '00000';
	}
	
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
	$network->reply($sender, $channel, "Current weather at $b_code$location_str$b_code: $weather_str");
}

1;
