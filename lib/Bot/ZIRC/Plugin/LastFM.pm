package Bot::ZIRC::Plugin::LastFM;

use Mojo::URL;
use Time::Duration 'ago';

use Moo;
extends 'Bot::ZIRC::Plugin';

use constant LASTFM_API_ENDPOINT => 'http://ws.audioscrobbler.com/2.0/';
use constant LASTFM_API_KEY_MISSING =>
	"Last.fm plugin requires configuration option 'lastfm_api_key' in section 'apis'\n" .
	"See http://www.last.fm/api/authentication for more information on obtaining a Last.fm API key.\n";

sub register {
	my ($self, $bot) = @_;
	my $api_key = $bot->config->get('apis','lastfm_api_key');
	die LASTFM_API_KEY_MISSING unless defined $api_key;
	
	$bot->add_command(
		name => 'np',
		help_text => 'Show now playing information, or set Last.fm username',
		usage_text => '[<Last.fm username>|set <Last.fm username>]',
		on_run => sub {
			my ($network, $sender, $channel, @args) = @_;
			
			if (@args and lc $args[0] eq 'set') {
				my $username = $args[1];
				return 'usage' unless defined $username and length $username;
				$network->storage->data->{lastfm}{usernames}{lc $sender} = $username;
				$network->storage->store;
				return $network->reply($sender, $channel, "Set Last.fm username of $sender to $username");
			}
			
			my $username = shift @args;
			unless (defined $username) {
				$username = $network->storage->data->{lastfm}{usernames}{lc $sender} // $sender->nick;
			}
			
			my $api_key = $network->config->get('apis','lastfm_api_key');
			die LASTFM_API_KEY_MISSING unless defined $api_key;
			my $request = Mojo::URL->new(LASTFM_API_ENDPOINT)->query(method => 'user.getrecenttracks',
				user => $username, api_key => $api_key, format => 'json', limit => 1);
			
			$network->logger->debug("Retrieving Last.fm recent tracks for $username");
			$self->ua->get($request, sub {
				my ($ua, $tx) = @_;
				return $network->reply($sender, $channel, $self->ua_error($tx->error)) if $tx->error;
				
				my $response = $tx->res->json;
				if ($response->{error}) {
					return $network->reply($sender, $channel,
						"Error retrieving Last.fm user data for $username: $response->{message}");
				}
				
				my $track = $response->{recenttracks}{track};
				$track = shift @$track if ref $track eq 'ARRAY';
				my $username = $response->{recenttracks}{'@attr'}{user} // $username;
				display_result($network, $sender, $channel, $track, $username);
			});
		},
	);
}

sub display_result {
	my ($network, $sender, $channel, $track, $username) = @_;
	my $track_name = $track->{name} // '';
	my $artist = $track->{artist}{'#text'};
	my $album = $track->{album}{'#text'};
	my $nowplaying = $track->{'@attr'}{nowplaying};
	my $played_at = $track->{date}{uts} // time;
	
	my $response = $track_name;
	$response = "$artist - $response" if defined $artist and length $artist;
	$response = "$response (from $album)" if defined $album and length $album;
	$response = $nowplaying ? "Now playing for $username: $response"
		: "Last track played for $username: $response ".ago(time-$played_at);
	
	$network->reply($sender, $channel, $response);
}

1;
