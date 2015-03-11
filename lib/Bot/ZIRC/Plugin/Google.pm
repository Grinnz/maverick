package Bot::ZIRC::Plugin::Google;

use Carp;
use Mojo::URL;

use Moo;
use namespace::clean;

with 'Bot::ZIRC::Plugin';

use constant GOOGLE_API_ENDPOINT => 'https://www.googleapis.com/customsearch/v1';
use constant GOOGLE_API_KEY_MISSING => 
	"Google plugin requires configuration options 'google_api_key' and 'google_cse_id' in section 'apis'\n" .
	"See https://developers.google.com/custom-search/json-api/v1/overview " .
	"for more information on obtaining a Google API key and Custom Search Engine ID.\n";

has 'results_cache' => (
	is => 'ro',
	lazy => 1,
	default => sub { {} },
	init_arg => undef,
);

sub register {
	my ($self, $bot) = @_;
	my $api_key = $bot->config->get('apis','google_api_key');
	my $cse_id = $bot->config->get('apis','google_cse_id');
	die GOOGLE_API_KEY_MISSING unless defined $api_key and defined $cse_id;
	
	$bot->add_command(
		name => 'google',
		help_text => 'Search the web with Google',
		usage_text => '<query>',
		tokenize => 0,
		on_run => sub {
			my ($network, $sender, $channel, $query) = @_;
			return 'usage' unless length $query;
			my $api_key = $network->config->get('apis','google_api_key');
			my $cse_id = $network->config->get('apis','google_cse_id');
			die GOOGLE_API_KEY_MISSING unless defined $api_key and defined $cse_id;
			
			my $request = Mojo::URL->new(GOOGLE_API_ENDPOINT)
				->query(key => $api_key, cx => $cse_id, q => $query, safe => 'high');
			
			$self->ua->get($request, sub {
				my ($ua, $tx) = @_;
				if (my $err = $tx->error) {
					my $msg = $err->{code}
						? "$err->{code} response: $err->{message}"
						: "Connection error: $err->{message}";
					return $network->reply($sender, $channel,
						"Error retrieving Google search results: $msg");
				}
				my $results = $tx->res->json->{items};
				return $network->reply($sender, $channel, "No results for Google search")
					unless $results and @$results;
				
				my $first_result = shift @$results;
				my $channel_name = lc ($channel // $sender);
				$self->results_cache->{web}{$network}{$channel_name} = $results;
				my $show_more = @$results;
				display_result_web($network, $sender, $channel, $first_result, $show_more);
			});
		},
		on_more => sub {
			my ($network, $sender, $channel) = @_;
			my $channel_name = lc ($channel // $sender);
			my $results = $self->results_cache->{web}{$network}{$channel_name};
			return $network->reply($sender, $channel, "No more results for Google search")
				unless $results and @$results;
			
			my $next_result = shift @$results;
			my $show_more = @$results;
			display_result_web($network, $sender, $channel, $next_result, $show_more);
		},
	);
	
	$bot->add_command(
		name => 'image',
		help_text => 'Search for images with Google',
		usage_text => '<query>',
		tokenize => 0,
		on_run => sub {
			my ($network, $sender, $channel, $query) = @_;
			return 'usage' unless length $query;
			my $api_key = $network->config->get('apis','google_api_key');
			my $cse_id = $network->config->get('apis','google_cse_id');
			die GOOGLE_API_KEY_MISSING unless defined $api_key and defined $cse_id;
			
			my $request = Mojo::URL->new(GOOGLE_API_ENDPOINT)
				->query(key => $api_key, cx => $cse_id, q => $query,
				safe => 'high', searchType => 'image');
			
			$self->ua->get($request, sub {
				my ($ua, $tx) = @_;
				if (my $err = $tx->error) {
					my $msg = $err->{code}
						? "$err->{code} response: $err->{message}"
						: "Connection error: $err->{message}";
					return $network->reply($sender, $channel,
						"Error retrieving Google image search results: $msg");
				}
				my $results = $tx->res->json->{items};
				return $network->reply($sender, $channel, "No results for Google image search")
					unless $results and @$results;
				
				my $first_result = shift @$results;
				my $channel_name = lc ($channel // $sender);
				$self->results_cache->{image}{$network}{$channel_name} = $results;
				my $show_more = @$results;
				display_result_image($network, $sender, $channel, $first_result, $show_more);
			});
		},
		on_more => sub {
			my ($network, $sender, $channel) = @_;
			my $channel_name = lc ($channel // $sender);
			my $results = $self->results_cache->{image}{$network}{$channel_name};
			return $network->reply($sender, $channel, "No more results for Google image search")
				unless $results and @$results;
			
			my $next_result = shift @$results;
			my $show_more = @$results;
			display_result_image($network, $sender, $channel, $next_result, $show_more);
		},
	);
}

sub display_result_web {
	my ($network, $sender, $channel, $result, $show_more) = @_;
	my $url = $result->{link} // '';
	my $title = $result->{title} // '';
	my $snippet = $result->{snippet} // '';
	$snippet =~ s/\s?\r?\n/ /g;
	$snippet = substr($snippet, 0, 200) . '...' if length $snippet > 200;
	$snippet = " - $snippet" if length $snippet;
	my $if_show_more = $show_more ? " [ $show_more more results, use 'more' command to display ]" : '';
	
	my $b_code = chr 2;
	my $response = "Google search result: $b_code$title$b_code - " .
		"$url$snippet$if_show_more";
	$network->reply($sender, $channel, $response);
}

sub display_result_image {
	my ($network, $sender, $channel, $result, $show_more) = @_;
	my $url = $result->{link} // '';
	my $title = $result->{title} // '';
	my $context_url = $result->{image}{contextLink} // '';
	my $if_show_more = $show_more ? " [ $show_more more results, use 'more' command to display ]" : '';
	
	my $b_code = chr 2;
	my $response = "Image search result: $b_code$title$b_code - " .
		"$url ($context_url)$if_show_more";
	$network->reply($sender, $channel, $response);
}

1;

