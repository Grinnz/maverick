package Bot::ZIRC::Plugin::Google;

use Carp 'croak';
use Lingua::EN::Number::Format::MixWithWords 'format_number_mix';
use List::UtilsBy 'max_by';
use Mojo::IOLoop;
use Mojo::URL;

use Moo;
extends 'Bot::ZIRC::Plugin';

use constant GOOGLE_API_ENDPOINT => 'https://www.googleapis.com/customsearch/v1';
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
	$self->api_key($bot->config->get('apis','google_api_key')) unless defined $self->api_key;
	$self->cse_id($bot->config->get('apis','google_cse_id')) unless defined $self->cse_id;
	die GOOGLE_API_KEY_MISSING unless defined $self->api_key and defined $self->cse_id;
	
	$bot->add_helper($self, 'google_search_web');
	$bot->add_helper($self, 'google_search_image');
	
	$bot->add_command(
		name => 'google',
		help_text => 'Search the web with Google',
		usage_text => '<query>',
		on_run => sub {
			my $m = shift;
			my $query = $m->args;
			return 'usage' unless length $query;
			
			$self->google_search_web($query, sub {
				my $results = shift;
				return $m->reply("No results for Google search") unless @$results;
				
				my $first_result = shift @$results;
				my $channel_name = lc ($m->channel // $m->sender);
				$self->_results_cache->{web}{$m->network}{$channel_name} = $results;
				$m->show_more(scalar @$results);
				$self->_google_result_web($m, $first_result);
			})->catch(sub { $m->reply("Google search error: $_[1]") });
		},
		on_more => sub {
			my $m = shift;
			my $channel_name = lc ($m->channel // $m->sender);
			my $results = $self->_results_cache->{web}{$m->network}{$channel_name} // [];
			return $m->reply("No more results for Google search") unless @$results;
			
			my $next_result = shift @$results;
			$m->show_more(scalar @$results);
			$self->_google_result_web($m, $next_result);
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
			
			$self->google_search_image($query, sub {
				my $results = shift;
				return $m->reply("No results for Google image search") unless @$results;
				
				my $first_result = shift @$results;
				my $channel_name = lc ($m->channel // $m->sender);
				$self->_results_cache->{image}{$m->network}{$channel_name} = $results;
				$m->show_more(scalar @$results);
				$self->_google_result_image($m, $first_result);
			})->catch(sub { $m->reply("Google search error: $_[1]") });
		},
		on_more => sub {
			my $m = shift;
			my $channel_name = lc ($m->channel // $m->sender);
			my $results = $self->_results_cache->{image}{$m->network}{$channel_name} // [];
			return $m->reply("No more results for Google image search") unless @$results;
			
			my $next_result = shift @$results;
			$m->show_more(scalar @$results);
			$self->_google_result_image($m, $next_result);
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
			Mojo::IOLoop->delay(sub {
				my $delay = shift;
				foreach my $challenger (@challengers) {
					$self->google_search_web_count($challenger, $delay->begin(0))
						->catch(sub { $m->reply("Google search error: $_[1]") });
				}
			}, sub {
				my $delay = shift;
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
			})->catch(sub { $m->reply("Internal error"); chomp (my $err = $_[1]); $m->logger->error($err) });
		},
	);
}

sub google_search_web {
	my ($self, $query, $cb) = @_;
	croak 'Undefined search query' unless defined $query;
	die GOOGLE_API_KEY_MISSING unless defined $self->api_key and defined $self->cse_id;
	
	my $request = Mojo::URL->new(GOOGLE_API_ENDPOINT)->query(key => $self->api_key,
		cx => $self->cse_id, q => $query, safe => 'high');
	unless ($cb) {
		my $tx = $self->ua->get($request);
		die $self->ua_error($tx->error) if $tx->error;
		return $tx->res->json->{items}//[];
	}
	return Mojo::IOLoop->delay(sub {
		$self->ua->get($request, shift->begin);
	}, sub {
		my ($delay, $tx) = @_;
		die $self->ua_error($tx->error) if $tx->error;
		$cb->($tx->res->json->{items}//[]);
	});
}

sub google_search_web_count {
	my ($self, $query, $cb) = @_;
	croak 'Undefined search query' unless defined $query;
	die GOOGLE_API_KEY_MISSING unless defined $self->api_key and defined $self->cse_id;
	
	my $request = Mojo::URL->new(GOOGLE_API_ENDPOINT)->query(key => $self->api_key,
		cx => $self->cse_id, q => $query, safe => 'off', num => 1);
	unless ($cb) {
		my $tx = $self->ua->get($request);
		die $self->ua_error($tx->error) if $tx->error;
		return $tx->res->json->{searchInformation}{totalResults}//0;
	}
	return Mojo::IOLoop->delay(sub {
		$self->ua->get($request, shift->begin);
	}, sub {
		my ($delay, $tx) = @_;
		die $self->ua_error($tx->error) if $tx->error;
		$cb->($tx->res->json->{searchInformation}{totalResults}//0);
	});
}

sub google_search_image {
	my ($self, $query, $cb) = @_;
	croak 'Undefined search query' unless defined $query;
	die GOOGLE_API_KEY_MISSING unless defined $self->api_key and defined $self->cse_id;
	
	my $request = Mojo::URL->new(GOOGLE_API_ENDPOINT)->query(key => $self->api_key,
		cx => $self->cse_id, q => $query, safe => 'high', searchType => 'image');
	unless ($cb) {
		my $tx = $self->ua->get($request);
		die $self->ua_error($tx->error) if $tx->error;
		return $tx->res->json->{items}//[];
	}
	return Mojo::IOLoop->delay(sub {
		$self->ua->get($request, shift->begin);
	}, sub {
		my ($delay, $tx) = @_;
		die $self->ua_error($tx->error) if $tx->error;
		$cb->($tx->res->json->{items}//[]);
	});
}

sub _google_result_web {
	my ($self, $m, $result) = @_;
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
	my ($self, $m, $result) = @_;
	my $url = $result->{link} // '';
	my $title = $result->{title} // '';
	my $context_url = $result->{image}{contextLink} // '';
	
	my $b_code = chr 2;
	my $response = "Image search result: $b_code$title$b_code - $url ($context_url)";
	$m->reply($response);
}

1;

=head1 NAME

Bot::ZIRC::Plugin::Google - Google search plugin for Bot::ZIRC

=head1 SYNOPSIS

 my $bot = Bot::ZIRC->new(
   plugins => { Google => 1 },
 );
 
 # Standalone usage
 my $google = Bot::ZIRC::Plugin::Google->new(api_key => $api_key, cse_id => $cse_id);
 my $results = $google->google_search_web($query);

=head1 DESCRIPTION

Adds helper methods and commands for searching Google to a L<Bot::ZIRC> IRC
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

 my $results = $bot->google_search_web($query);
 $bot->google_search_web($query, sub {
   my $results = shift;
 })->catch(sub { $m->reply("Google search error: $_[1]") });

Search Google web search. Returns the results (if any) in an arrayref, or
throws an exception on error. Pass a callback to perform the query
non-blocking.

=head2 google_search_image

 my $results = $bot->google_search_image($query);
 $bot->google_search_image($query, sub {
   my $results = shift;
 })->catch(sub { $m->reply("Google search error: $_[1]") });

Search Google image search. Returns the results (if any) in an arrayref, or
throws an exception on error. Pass a callback to perform the query
non-blocking.

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

L<Bot::ZIRC>
