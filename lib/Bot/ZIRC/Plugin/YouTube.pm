package Bot::ZIRC::Plugin::YouTube;

use Carp;
use Mojo::Date;
use Mojo::URL;
use Mojo::UserAgent;
use Time::Duration 'ago';

use Moo;
use warnings NONFATAL => 'all';
use namespace::clean;

with 'Bot::ZIRC::Plugin';

use constant YOUTUBE_API_ENDPOINT => 'https://www.googleapis.com/youtube/v3/';
use constant YOUTUBE_VIDEO_URL => 'https://www.youtube.com/watch';
use constant YOUTUBE_API_KEY_MISSING => 
	"YouTube plugin requires configuration option 'youtube_api_key' in section 'apis'\n" .
	"See https://developers.google.com/youtube/registering_an_application " .
	"for more information on obtaining a YouTube API key.\n";

has 'results_cache' => (
	is => 'ro',
	lazy => 1,
	default => sub { {} },
	init_arg => undef,
);

sub register {
	my ($self, $bot) = @_;
	my $api_key = $bot->config->get('apis','youtube_api_key');
	die YOUTUBE_API_KEY_MISSING unless defined $api_key;
	
	my $ua = Mojo::UserAgent->new;
	
	$bot->add_command(
		name => 'youtube',
		help_text => 'Search YouTube videos',
		usage_text => '<search query>',
		tokenize => 0,
		on_run => sub {
			my ($network, $sender, $channel, $query) = @_;
			return 'usage' unless length $query;
			my $api_key = $network->config->get('apis','youtube_api_key');
			die YOUTUBE_API_KEY_MISSING unless defined $api_key;
			my $nick = $sender->nick;
			my $url = Mojo::URL->new(YOUTUBE_API_ENDPOINT)->path('search')
				->query(key => $api_key, part => 'snippet', q => $query,
					safeSearch => 'strict', type => 'video');
			$ua->catch(sub {
				my ($ua, $err) = @_;
				$network->logger->error($err);
				$network->reply($sender, $channel, "Internal error");
			})->get($url, sub {
				my ($ua, $tx) = @_;
				if (my $err = $tx->error) {
					my $msg = $err->{code}
						? "$err->{code} response: $err->{message}"
						: "Connection error: $err->{message}";
					return $network->reply($sender, $channel,
						"Error retrieving YouTube search results: $msg");
				}
				my $results = $tx->res->json->{items};
				return $network->reply($sender, $channel, "No results for YouTube search")
					unless $results and @$results;
				my $first_result = shift @$results;
				my $network_name = $network->name;
				my $channel_name = lc ($channel // $sender->nick);
				$self->results_cache->{$network_name}{$channel_name} = $results;
				my $show_more = @$results;
				display_result($network, $sender, $channel, $first_result, $show_more);
			});
		},
		on_more => sub {
			my ($network, $sender, $channel) = @_;
			my $network_name = $network->name;
			my $channel_name = lc ($channel // $sender->nick);
			my $results = $self->results_cache->{$network_name}{$channel_name};
			return $network->reply($sender, $channel, "No more results for YouTube search")
				unless $results and @$results;
			my $next_result = shift @$results;
			my $show_more = @$results;
			display_result($network, $sender, $channel, $next_result, $show_more);
		},
	);
}

sub display_result {
	my ($network, $sender, $channel, $result, $show_more) = @_;
	my $video_id = $result->{id}{videoId} // '';
	my $title = $result->{snippet}{title} // '';
	my $url = Mojo::URL->new(YOUTUBE_VIDEO_URL)->query(v => $video_id)->to_string;
	my $ytchannel = $result->{snippet}{channelTitle} // '';
	my $published = $result->{snippet}{publishedAt};
	$published = defined $published ? ago(time - Mojo::Date->new($published)->epoch) : undef;
	my $description = $result->{snippet}{description} // '';
	$description = substr($description, 0, 200) . '...' if length $description > 200;
	$description = " - $description" if length $description;
	my $if_show_more = $show_more ? " [ $show_more more results, use 'more' command to display ]" : '';
	my $b_code = chr 2;
	my $response = "YouTube search result: $b_code$title$b_code - $url - " .
		"published by $b_code$ytchannel$b_code $published$description$if_show_more";
	$network->reply($sender, $channel, $response);
}

1;
