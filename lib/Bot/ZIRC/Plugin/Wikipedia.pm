package Bot::ZIRC::Plugin::Wikipedia;

use Mojo::URL;

use Moo;
with 'Bot::ZIRC::Plugin';

use constant WIKIPEDIA_API_ENDPOINT => 'http://en.wikipedia.org/w/api.php';

has 'results_cache' => (
	is => 'ro',
	lazy => 1,
	default => sub { {} },
	init_arg => undef,
);

sub register {
	my ($self, $bot) = @_;
	
	$bot->add_command(
		name => 'wikipedia',
		help_text => 'Search Wikipedia articles',
		usage_text => '<query>',
		tokenize => 0,
		on_run => sub {
			my ($network, $sender, $channel, $query) = @_;
			return 'usage' unless length $query;
			
			my $url = Mojo::URL->new(WIKIPEDIA_API_ENDPOINT)
				->query(format => 'json', action => 'opensearch', search => $query);
			$network->ua->get($url, sub {
				my ($ua, $tx) = @_;
				return $network->reply($sender, $channel, ua_error($tx->error)) if $tx->error;
				
				my $titles = $tx->res->json->[1];
				return $network->reply($sender, $channel, "No results for Wikipedia search")
					unless defined $titles and @$titles;
				
				my $first_title = shift @$titles;
				my $channel_name = lc ($channel // $sender);
				$self->results_cache->{$network}{$channel_name} = $titles;
				my $show_more = @$titles;
				display_wiki_page($network, $sender, $channel, $first_title, $show_more);
			});
		},
		on_more => sub {
			my ($network, $sender, $channel) = @_;
			my $channel_name = lc ($channel // $sender);
			my $titles = $self->results_cache->{$network}{$channel_name};
			return $network->reply($sender, $channel, "No more results for Wikipedia search")
				unless $titles and @$titles;
			
			my $next_title = shift @$titles;
			my $show_more = @$titles;
			display_wiki_page($network, $sender, $channel, $next_title, $show_more);
		},
	);
}

sub display_wiki_page {
	my ($network, $sender, $channel, $title, $show_more) = @_;
	
	my $if_show_more = $show_more ? " [ $show_more more results, use 'more' command to display ]" : '';
	my $url = Mojo::URL->new(WIKIPEDIA_API_ENDPOINT)
		->query(format => 'json', action => 'query', redirects => 1, prop => 'extracts|info',
		explaintext => 1, exsectionformat => 'plain', exchars => 250, inprop => 'url', titles => $title);
	$network->ua->get($url, sub {
		my ($ua, $tx) = @_;
		return $network->reply($sender, $channel, ua_error($tx->error)) if $tx->error;
		
		my $pages = $tx->res->json->{query}{pages};
		my $page = (values %$pages)[0];
		return $network->reply("Wikipedia page $title not found$if_show_more")
			unless defined $page;
		
		my $title = $page->{title};
		my $url = $page->{fullurl};
		my $extract = $page->{extract};
		$extract =~ s/\n/ /g;
		
		my $b_code = chr 2;
		my $response = "Wikipedia search result: $b_code$title$b_code - $url - $extract$if_show_more";
		return $network->reply($sender, $channel, $response);
	});
}

1;
