package Bot::Maverick::Plugin::Wikipedia;

use Carp 'croak';
use Mojo::URL;

use Moo;
with 'Bot::Maverick::Plugin';

our $VERSION = '0.20';

use constant WIKIPEDIA_API_ENDPOINT => 'https://en.wikipedia.org/w/api.php';

has '_results_cache' => (
	is => 'ro',
	lazy => 1,
	default => sub { {} },
	init_arg => undef,
);

sub register {
	my ($self, $bot) = @_;
	
	$bot->add_helper(_wikipedia_results_cache => sub { $self->_results_cache });
	$bot->add_helper(wikipedia_search => \&_wikipedia_search);
	$bot->add_helper(wikipedia_page => \&_wikipedia_page);
	
	$bot->add_command(
		name => 'wikipedia',
		help_text => 'Search Wikipedia articles',
		usage_text => '<query>',
		on_run => sub {
			my $m = shift;
			my $query = $m->args;
			return 'usage' unless length $query;
			
			return $m->bot->wikipedia_search($query)->then(sub {
				my $titles = shift;
				unless (@$titles) {
					$m->reply("No results for Wikipedia search");
					return $m->bot->new_future->done(undef);
				}
				
				my $first_title = shift @$titles;
				my $channel_name = lc ($m->channel // $m->sender);
				$m->bot->_wikipedia_results_cache->{$m->network}{$channel_name} = $titles;
				$m->show_more(scalar @$titles);
				
				return $m->bot->wikipedia_page($first_title);
			})->on_done(sub {
				my $page = shift;
				_display_wiki_page($m, $page);
			})->on_fail(sub { $m->reply("Wikipedia search error: $_[0]") });
		},
		on_more => sub {
			my $m = shift;
			my $channel_name = lc ($m->channel // $m->sender);
			my $titles = $m->bot->_wikipedia_results_cache->{$m->network}{$channel_name} // [];
			return $m->reply("No more results for Wikipedia search") unless @$titles;
			
			my $next_title = shift @$titles;
			$m->show_more(scalar @$titles);
			
			return $m->bot->wikipedia_page($next_title)->on_done(sub {
				my $page = shift;
				_display_wiki_page($m, $page);
			})->on_fail(sub { $m->reply("Wikipedia search error: $_[0]") });
		},
	);
}

sub _wikipedia_search {
	my ($bot, $query) = @_;
	croak 'Undefined search query' unless defined $query;
	
	my $url = Mojo::URL->new(WIKIPEDIA_API_ENDPOINT)
		->query(format => 'json', action => 'opensearch', search => $query);
	return $bot->ua_request($url)->transform(done => sub { (shift->json // [])->[1] // [] });
}

sub _wikipedia_page {
	my ($bot, $title) = @_;
	croak 'Undefined page title' unless defined $title;
	
	my $url = Mojo::URL->new(WIKIPEDIA_API_ENDPOINT)->query(format => 'json', action => 'query',
		redirects => 1, prop => 'extracts|info', explaintext => 1, exsectionformat => 'plain',
		exchars => 250, inprop => 'url', titles => $title);
	return $bot->ua_request($url)->transform(done => sub { _find_page_result(shift->json->{query}{pages}) });
}

sub _find_page_result {
	my $pages = shift // return undef;
	my $key = (sort keys %$pages)[0] // return undef;
	return $pages->{$key};
}

sub _display_wiki_page {
	my ($m, $page) = @_;
	return() unless defined $page;
	
	my $title = $page->{title} // '';
	my $url = $page->{fullurl} // '';
	my $extract = $page->{extract} // '';
	$extract =~ s/\n/ /g;
	
	my $b_code = chr 2;
	my $response = "Wikipedia search result: $b_code$title$b_code - $url - $extract";
	$m->reply($response);
}

1;

=head1 NAME

Bot::Maverick::Plugin::Wikipedia - Wikipedia search plugin for Maverick

=head1 SYNOPSIS

 my $bot = Bot::Maverick->new(
   plugins => { Wikipedia => 1 },
 );
 
 # Standalone usage
 my $wiki = Bot::Maverick::Plugin::Wikipedia->new;
 my $titles = $wiki->wikipedia_search($query);
 foreach my $title (@$titles) {
   my $page = $wiki->wikipedia_page($title);
 }

=head1 DESCRIPTION

Adds helper methods and commands for searching Wikipedia to a L<Bot::Maverick>
IRC bot.

=head1 METHODS

=head2 wikipedia_search

 my $titles = $bot->wikipedia_search($query);
 $bot->wikipedia_search($query, sub {
   my $titles = shift;
 })->catch(sub { $m->reply("Wikipedia search error: $_[1]") });

Search Wikipedia page titles. Returns matching page titles (if any) in an
arrayref, or throws an exception on error. Pass a callback to perform the query
non-blocking.

=head2 wikipedia_page

 my $page = $bot->wikipedia_page($title);
 $bot->wikipedia_page($title, sub {
   my $page = shift;
 })->catch(sub { $m->reply("Error retrieving page from Wikipedia: $_[1]") });

Retrieve a Wikipedia page by title. Returns the page data as a hashref, or
undef if it is not found. Throws an exception on error. Pass a calback to
perform the query non-blocking.

=head1 COMMANDS

=head2 wikipedia

 !wikipedia boat
 !wikipedia NRA
 !wikipedia Charlie Sheen

Search Wikipedia and display info from the first relevant page, if any.
Additional pages can be retrieved using the C<more> command.

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
