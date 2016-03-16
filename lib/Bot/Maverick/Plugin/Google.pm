package Bot::Maverick::Plugin::Google;

use Carp 'croak';
use Lingua::EN::Number::Format::MixWithWords 'format_number_mix';
use List::UtilsBy 'max_by';
use Mojo::URL;

use Moo;
with 'Bot::Maverick::Plugin';

our $VERSION = '0.20';

use constant GOOGLE_API_ENDPOINT => 'https://www.googleapis.com/customsearch/v1';
use constant GOOGLE_COMPLETE_ENDPOINT => 'http://google.com/complete/search';
use constant GOOGLE_API_KEY_MISSING => 
	"Google plugin requires configuration options 'google_api_key' and 'google_cse_id' in section 'apis'\n" .
	"See https://developers.google.com/custom-search/json-api/v1/overview " .
	"for more information on obtaining a Google API key and Custom Search Engine ID.\n";

has 'api_key' => (
	is => 'rw',
);

has 'cse_id' => (
	is => 'rw',
);

has '_results_cache' => (
	is => 'ro',
	lazy => 1,
	default => sub { {} },
	init_arg => undef,
);

sub register {
	my ($self, $bot) = @_;
	$self->api_key($bot->config->param('apis','google_api_key')) unless defined $self->api_key;
	$self->cse_id($bot->config->param('apis','google_cse_id')) unless defined $self->cse_id;
	die GOOGLE_API_KEY_MISSING unless defined $self->api_key and defined $self->cse_id;
	
	$bot->add_helper(_google_results_cache => sub { $self->_results_cache });
	$bot->add_helper(google_api_key => sub { $self->api_key });
	$bot->add_helper(google_cse_id => sub { $self->cse_id });
	$bot->add_helper(google_search_web => \&_google_search_web);
	$bot->add_helper(google_search_web_count => \&_google_search_web_count);
	$bot->add_helper(google_search_image => \&_google_search_image);
	$bot->add_helper(google_complete => \&_google_complete);
	
	$bot->add_command(
		name => 'google',
		help_text => 'Search the web with Google',
		usage_text => '<query>',
		on_run => sub {
			my $m = shift;
			my $query = $m->args;
			return 'usage' unless length $query;
			
			return $m->bot->google_search_web($query)->on_done(sub {
				my $results = shift;
				return $m->reply("No results for Google search") unless @$results;
				
				my $first_result = shift @$results;
				my $channel_name = lc ($m->channel // $m->sender);
				$m->bot->_google_results_cache->{web}{$m->network}{$channel_name} = $results;
				$m->show_more(scalar @$results);
				_google_result_web($m, $first_result);
			})->on_fail(sub { $m->reply("Google search error: $_[0]") });
		},
		on_more => sub {
			my $m = shift;
			my $channel_name = lc ($m->channel // $m->sender);
			my $results = $m->bot->_google_results_cache->{web}{$m->network}{$channel_name} // [];
			return $m->reply("No more results for Google search") unless @$results;
			
			my $next_result = shift @$results;
			$m->show_more(scalar @$results);
			_google_result_web($m, $next_result);
		},
	);
	
	$bot->add_command(
		name => 'image',
		help_text => 'Search for images with Google',
		usage_text => '<query>',
		on_run => sub {
			my $m = shift;
			my $query = $m->args;
			return 'usage' unless length $query;
			
			return $m->bot->google_search_image($query)->on_done(sub {
				my $results = shift;
				return $m->reply("No results for Google image search") unless @$results;
				
				my $first_result = shift @$results;
				my $channel_name = lc ($m->channel // $m->sender);
				$m->bot->_google_results_cache->{image}{$m->network}{$channel_name} = $results;
				$m->show_more(scalar @$results);
				_google_result_image($m, $first_result);
			})->on_fail(sub { $m->reply("Google search error: $_[0]") });
		},
		on_more => sub {
			my $m = shift;
			my $channel_name = lc ($m->channel // $m->sender);
			my $results = $m->bot->_google_results_cache->{image}{$m->network}{$channel_name} // [];
			return $m->reply("No more results for Google image search") unless @$results;
			
			my $next_result = shift @$results;
			$m->show_more(scalar @$results);
			_google_result_image($m, $next_result);
		},
	);
	
	$bot->add_command(
		name => 'gif',
		help_text => 'Search for animated images with Google',
		usage_text => '<query>',
		on_run => sub {
			my $m = shift;
			my $query = $m->args;
			return 'usage' unless length $query;
			
			return $m->bot->google_search_image($query, 1)->on_done(sub {
				my $results = shift;
				return $m->reply("No results for Google image search") unless @$results;
				
				my $first_result = shift @$results;
				my $channel_name = lc ($m->channel // $m->sender);
				$m->bot->_google_results_cache->{gif}{$m->network}{$channel_name} = $results;
				$m->show_more(scalar @$results);
				_google_result_image($m, $first_result);
			})->on_fail(sub { $m->reply("Google search error: $_[0]") });
		},
		on_more => sub {
			my $m = shift;
			my $channel_name = lc ($m->channel // $m->sender);
			my $results = $m->bot->_google_results_cache->{gif}{$m->network}{$channel_name} // [];
			return $m->reply("No more results for Google image search") unless @$results;
			
			my $next_result = shift @$results;
			$m->show_more(scalar @$results);
			_google_result_image($m, $next_result);
		},
	);
	
	$bot->add_command(
		name => 'fight',
		help_text => 'Compare two or more searches in a Google fight',
		usage_text => '<query1> (vs.|versus) <query2> [(vs.|versus) <query3> ...]',
		on_run => sub {
			my $m = shift;
			my $args = $m->args;
			my @challengers;
			while ($args =~ /\s*(".+?"|.+?)(?:\s+(?:vs\.?|versus)\s+|\s*$)/g) {
				push @challengers, $1;
			}
			return 'usage' unless @challengers > 1;
			my @futures = map { $m->bot->google_search_web_count($_) } @challengers;
			return $m->bot->new_future->needs_all(@futures)->on_done(sub {
				my %counts;
				foreach my $challenger (@challengers) {
					my $count = shift;
					$counts{$challenger} = $count // 0;
				}
				my @winners = max_by { $counts{$_} } @challengers;
				$_ = format_number_mix(
					num => $_,
					num_decimal => 1,
					min_format => 1000,
					scale => 'short',
				) foreach values %counts;
				my $reply_str = join '; ', map { "$_: $counts{$_}" } @challengers;
				my $winner_str = @winners > 1 ? 'Tie between '.join(' / ', @winners) : "Winner: $winners[0]";
				$m->reply("Google Fight! $reply_str. $winner_str!");
			})->on_fail(sub { $m->reply("Google search error: $_[0]") });
		},
	);
	
	$bot->add_command(
		name => 'complete',
		help_text => 'Get Google auto-complete suggestions',
		usage_text => '<snippet>',
		on_run => sub {
			my $m = shift;
			my $query = $m->args;
			return 'usage' unless length $query;
			
			return $m->bot->google_complete($query)->on_done(sub {
				my $suggestions = shift;
				return $m->reply("No Google auto-complete suggestions") unless @$suggestions;
				
				my $channel_name = lc ($m->channel // $m->sender);
				$m->bot->_google_results_cache->{complete}{$m->network}{$channel_name} = $suggestions;
				
				my @show_suggestions = splice @$suggestions, 0, 5;
				$m->show_more(scalar @$suggestions);
				my $suggest_str = join ' | ', @show_suggestions;
				$m->reply("Suggested completions: $suggest_str");
			})->on_fail(sub { $m->reply("Google search error: $_[0]") });
		},
		on_more => sub {
			my $m = shift;
			my $channel_name = lc ($m->channel // $m->sender);
			my $suggestions = $m->bot->_google_results_cache->{complete}{$m->network}{$channel_name} // [];
			return $m->reply("No more Google auto-complete suggestions") unless @$suggestions;
			
			my @show_suggestions = splice @$suggestions, 0, 5;
			$m->show_more(scalar @$suggestions);
			my $suggest_str = join ' | ', @show_suggestions;
			$m->reply("Suggested completions: $suggest_str");
		},
	);
}

sub _google_search_web {
	my ($bot, $query) = @_;
	croak 'Undefined search query' unless defined $query;
	die GOOGLE_API_KEY_MISSING unless defined $bot->google_api_key and defined $bot->google_cse_id;
	
	my $request = Mojo::URL->new(GOOGLE_API_ENDPOINT)->query(key => $bot->google_api_key,
		cx => $bot->google_cse_id, q => $query, safe => 'high');
	return $bot->ua_request($request)->transform(done => sub { shift->json->{items} // [] });
}

sub _google_search_web_count {
	my ($bot, $query) = @_;
	croak 'Undefined search query' unless defined $query;
	die GOOGLE_API_KEY_MISSING unless defined $bot->google_api_key and defined $bot->google_cse_id;
	
	my $request = Mojo::URL->new(GOOGLE_API_ENDPOINT)->query(key => $bot->google_api_key,
		cx => $bot->google_cse_id, q => $query, safe => 'off', num => 1);
	return $bot->ua_request($request)->transform(done => sub { shift->json->{searchInformation}{totalResults} // 0 });
}

sub _google_search_image {
	my ($bot, $query, $gif) = @_;
	croak 'Undefined search query' unless defined $query;
	die GOOGLE_API_KEY_MISSING unless defined $bot->google_api_key and defined $bot->google_cse_id;
	
	my $request = Mojo::URL->new(GOOGLE_API_ENDPOINT)->query(key => $bot->google_api_key,
		cx => $bot->google_cse_id, q => $query, safe => 'high', searchType => 'image');
	$request->query({hq => 'animated', tbs => 'itp:animated', fileType => 'gif'}) if $gif;
	return $bot->ua_request($request)->transform(done => sub { shift->json->{items} // [] });
}

sub _google_complete {
	my ($bot, $query) = @_;
	croak 'Undefined search query' unless defined $query;
	
	my $request = Mojo::URL->new(GOOGLE_COMPLETE_ENDPOINT)->query(output => 'toolbar',
		client => 'chrome', hl => 'en', q => $query);
	return $bot->ua_request($request)->transform(done => sub { (shift->json // [])->[1] // [] });
}

sub _google_result_web {
	my ($m, $result) = @_;
	my $url = $result->{link} // '';
	my $title = $result->{title} // '';
	my $snippet = $result->{snippet} // '';
	$snippet =~ s/\s?\r?\n/ /g;
	$snippet = " - $snippet" if length $snippet;
	
	my $b_code = chr 2;
	my $response = "Google search result: $b_code$title$b_code - $url$snippet";
	$m->reply($response);
}

sub _google_result_image {
	my ($m, $result) = @_;
	my $url = $result->{link} // '';
	my $title = $result->{title} // '';
	my $context_url = $result->{image}{contextLink} // '';
	
	my $b_code = chr 2;
	my $response = "Image search result: $b_code$title$b_code - $url ($context_url)";
	$m->reply($response);
}

1;

=head1 NAME

Bot::Maverick::Plugin::Google - Google search plugin for Maverick

=head1 SYNOPSIS

 my $bot = Bot::Maverick->new(
   plugins => { Google => 1 },
 );
 
 # Standalone usage
 my $google = Bot::Maverick::Plugin::Google->new(api_key => $api_key, cse_id => $cse_id);
 my $results = $google->google_search_web($query)->get;

=head1 DESCRIPTION

Adds helper methods and commands for searching Google to a L<Bot::Maverick> IRC
bot.

This plugin requires a Google API key and Custom Search Engine ID, as
configuration options C<google_api_key> and C<google_cse_id> in the C<apis>
section. See L<https://developers.google.com/custom-search/json-api/v1/overview>
for information on obtaining an API key and setting up a Custom Search Engine.
Currently, you can set up a Custom Search Engine for searching the entire web
instead of a specific site by changing the settings of the Custom Search Engine
after creation.

=head1 ATTRIBUTES

=head2 api_key

API key for Google API, defaults to value of configuration option
C<google_api_key> in section C<apis>.

=head2 cse_id

Google Custom Search Engine ID, defaults to value of configuration option
C<google_cse_id> in section C<apis>.

=head1 METHODS

=head2 google_search_web

 my $results = $bot->google_search_web($query)->get;
 my $future = $bot->google_search_web($query)->on_done(sub {
   my $results = shift;
 })->on_fail(sub { $m->reply("Google search error: $_[0]") });

Search Google web search. Returns a L<Future::Mojo> containing the results (if
any) in an arrayref.

=head2 google_search_web_count

 my $count = $bot->google_search_web_count($query)->get;
 my $future = $bot->google_search_web($query)->on_done(sub {
   my $count = shift;
 })->on_fail(sub { $m->reply("Google search error: $_[0]") });

Search Google web search. Returns a L<Future::Mojo> containing the approximate
number of results.

=head2 google_search_image

 my $results = $bot->google_search_image($query)->get;
 my $future = $bot->google_search_image($query)->on_done(sub {
   my $results = shift;
 })->on_fail(sub { $m->reply("Google search error: $_[0]") });

Search Google image search. Returns a L<Future::Mojo> containing the results
(if any) in an arrayref.

=head2 google_complete

 my $suggestions = $bot->google_complete($query)->get;
 my $future = $bot->google_complete($query)->on_done(sub {
   my $suggestions = shift;
 })->on_fail(sub { $m->reply("Google search error: $_[0]") });

Returns a L<Future::Mojo> containing Google autocomplete suggestions in an
arrayref.

=head1 COMMANDS

=head2 google

 !google why is the interview rated r
 !google how do you authorize a computer for itunes
 !google what are the seven deadly sins

Search Google web search and display the first result, if any. Additional
results can be retrieved using the C<more> command.

=head2 image

 !image angelina jolie
 !image wat

Search Google image search and display the first result, if any. Additional
results can be retrieved using the C<more> command.

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
