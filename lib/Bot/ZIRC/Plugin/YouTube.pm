package Bot::ZIRC::Plugin::YouTube;

use Mojo::URL;
use Time::Duration 'ago';

use Moo;
use namespace::clean;

with 'Bot::ZIRC::Plugin';

use constant YOUTUBE_API_ENDPOINT => 'https://www.googleapis.com/youtube/v3/';
use constant YOUTUBE_VIDEO_URL => 'https://www.youtube.com/watch';
use constant YOUTUBE_API_KEY_MISSING => 
	"YouTube plugin requires configuration option 'google_api_key' in section 'apis'\n" .
	"See https://developers.google.com/youtube/registering_an_application " .
	"for more information on obtaining a Google API key.\n";

has 'results_cache' => (
	is => 'ro',
	lazy => 1,
	default => sub { {} },
	init_arg => undef,
);

sub register {
	my ($self, $bot) = @_;
	my $api_key = $bot->config->get('apis','google_api_key');
	die YOUTUBE_API_KEY_MISSING unless defined $api_key;
	
	$bot->add_command(
		name => 'youtube',
		help_text => 'Search YouTube videos',
		usage_text => '<search query>',
		tokenize => 0,
		on_run => sub {
			my ($network, $sender, $channel, $query) = @_;
			return 'usage' unless length $query;
			my $api_key = $network->config->get('apis','google_api_key');
			die YOUTUBE_API_KEY_MISSING unless defined $api_key;
			
			my $request = Mojo::URL->new(YOUTUBE_API_ENDPOINT)->path('search')
				->query(key => $api_key, part => 'snippet', q => $query,
					safeSearch => 'strict', type => 'video');
			
			$self->ua->get($request, sub {
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
				my $channel_name = lc ($channel // $sender);
				$self->results_cache->{$network}{$channel_name} = $results;
				my $show_more = @$results;
				display_result($network, $sender, $channel, $first_result, $show_more);
			});
		},
		on_more => sub {
			my ($network, $sender, $channel) = @_;
			my $channel_name = lc ($channel // $sender);
			my $results = $self->results_cache->{$network}{$channel_name};
			return $network->reply($sender, $channel, "No more results for YouTube search")
				unless $results and @$results;
			
			my $next_result = shift @$results;
			my $show_more = @$results;
			display_result($network, $sender, $channel, $next_result, $show_more);
		},
	);
	
	$bot->config->set_channel_default('youtube_trigger', 1);
	
	$bot->add_hook_privmsg(sub {
		my ($network, $sender, $channel, $message) = @_;
		return unless defined $channel;
		return unless $network->config->get_channel($channel, 'youtube_trigger');
		my $api_key = $network->config->get('apis','google_api_key');
		die YOUTUBE_API_KEY_MISSING unless defined $api_key;
		
		return unless $message =~ m!\b(\S+youtube.com/watch\S+)!;
		my $captured = Mojo::URL->new($1);
		my $video_id = $captured->query->param('v') // return;
		my $fragment = $captured->fragment;
		
		$network->logger->debug("Captured YouTube URL $captured with video ID $video_id");
		my $request = Mojo::URL->new(YOUTUBE_API_ENDPOINT)->path('videos')
			->query(key => $api_key, part => 'snippet', id => $video_id);
		
		$self->ua->get($request, sub {
			my ($ua, $tx) = @_;
			if (my $err = $tx->error) {
				my $msg = $err->{code}
					? "$err->{code} response: $err->{message}"
					: "Connection error: $err->{message}";
				return $network->logger->error("Error retrieving YouTube video data: $msg");
			}
			my $results = $tx->res->json->{items};
			return unless $results and @$results;
			my $result = shift @$results;
			display_triggered($network, $sender, $channel, $result, $fragment);
		});
	});
}

sub display_result {
	my ($network, $sender, $channel, $result, $show_more) = @_;
	my $video_id = $result->{id}{videoId} // '';
	my $title = $result->{snippet}{title} // '';
	
	my $url = Mojo::URL->new(YOUTUBE_VIDEO_URL)->query(v => $video_id)->to_string;
	my $ytchannel = $result->{snippet}{channelTitle} // '';
	
	my $description = $result->{snippet}{description} // '';
	$description = substr($description, 0, 200) . '...' if length $description > 200;
	$description = " - $description" if length $description;
	my $if_show_more = $show_more ? " [ $show_more more results, use 'more' command to display ]" : '';
	
	my $b_code = chr 2;
	my $response = "YouTube search result: $b_code$title$b_code - " .
		"published by $b_code$ytchannel$b_code - $url$description$if_show_more";
	$network->reply($sender, $channel, $response);
}

sub display_triggered {
	my ($network, $sender, $channel, $result, $fragment) = @_;
	my $video_id = $result->{id} // '';
	my $title = $result->{snippet}{title} // '';
	
	my $url = Mojo::URL->new(YOUTUBE_VIDEO_URL)->query(v => $video_id);
	$url->fragment($fragment) if defined $fragment;
	$url = $url->to_string;
	my $ytchannel = $result->{snippet}{channelTitle} // '';
	
	my $b_code = chr 2;
	my $response = "YouTube video linked by $sender: $b_code$title$b_code - " .
		"published by $b_code$ytchannel$b_code - $url";
	$network->write(privmsg => $channel, $response);
}

1;
