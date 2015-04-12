package Bot::ZIRC::Plugin::Wikipedia;

use Carp 'croak';
use Mojo::URL;

use Moo;
extends 'Bot::ZIRC::Plugin';

use constant WIKIPEDIA_API_ENDPOINT => 'http://en.wikipedia.org/w/api.php';

has '_results_cache' => (
	is => 'ro',
	lazy => 1,
	default => sub { {} },
	init_arg => undef,
);

sub register {
	my ($self, $bot) = @_;
	
	$bot->add_plugin_method($self, 'wikipedia_search');
	$bot->add_plugin_method($self, 'wikipedia_page');
	
	$bot->add_command(
		name => 'wikipedia',
		help_text => 'Search Wikipedia articles',
		usage_text => '<query>',
		tokenize => 0,
		on_run => sub {
			my ($network, $sender, $channel, $query) = @_;
			return 'usage' unless length $query;
			
			$self->wikipedia_search($query, sub {
				my ($err, $titles) = @_;
				return $network->reply($sender, $channel, $err) if $err;
				return $network->reply($sender, $channel, "No results for Wikipedia search") unless @$titles;
				
				my $first_title = shift @$titles;
				my $channel_name = lc ($channel // $sender);
				$self->_results_cache->{$network}{$channel_name} = $titles;
				my $show_more = @$titles;
				$self->_display_wiki_page($network, $sender, $channel, $first_title, $show_more);
			});
		},
		on_more => sub {
			my ($network, $sender, $channel) = @_;
			my $channel_name = lc ($channel // $sender);
			my $titles = $self->_results_cache->{$network}{$channel_name} // [];
			return $network->reply($sender, $channel, "No more results for Wikipedia search") unless @$titles;
			
			my $next_title = shift @$titles;
			my $show_more = @$titles;
			$self->_display_wiki_page($network, $sender, $channel, $next_title, $show_more);
		},
	);
}

sub wikipedia_search {
	my ($self, $query, $cb) = @_;
	croak 'Undefined search query' unless defined $query;
	
	my $url = Mojo::URL->new(WIKIPEDIA_API_ENDPOINT)
		->query(format => 'json', action => 'opensearch', search => $query);
	if ($cb) {
		$self->ua->get($url, sub {
			my ($ua, $tx) = @_;
			return $cb->($self->ua_error($tx->error)) if $tx->error;
			return $cb->(undef, $tx->res->json->[1]//[]);
		});
	} else {
		my $tx = $self->ua->get($url);
		return $self->ua_error($tx->error) if $tx->error;
		return (undef, $tx->res->json->[1]//[]);
	}
}

sub wikipedia_page {
	my ($self, $title, $cb) = @_;
	croak 'Undefined page title' unless defined $title;
	
	my $url = Mojo::URL->new(WIKIPEDIA_API_ENDPOINT)->query(format => 'json', action => 'query',
		redirects => 1, prop => 'extracts|info', explaintext => 1, exsectionformat => 'plain',
		exchars => 250, inprop => 'url', titles => $title);
	if ($cb) {
		$self->ua->get($url, sub {
			my ($ua, $tx) = @_;
			return $cb->($self->ua_error($tx->error)) if $tx->error;
			my $pages = $tx->res->json->{query}{pages} // {};
			my $key = (sort keys %$pages)[0] // '';
			return $cb->(undef, $pages->{$key});
		});
	} else {
		my $tx = $self->ua->get($url);
		return $self->ua_error($tx->error) if $tx->error;
		my $pages = $tx->res->json->{query}{pages} // {};
		my $key = (sort keys %$pages)[0] // '';
		return (undef, $pages->{$key});
	}
}

sub _display_wiki_page {
	my ($self, $network, $sender, $channel, $title, $show_more) = @_;
	
	my $if_show_more = $show_more ? " [ $show_more more results, use 'more' command to display ]" : '';
	$self->wikipedia_page($title, sub {
		my ($err, $page) = @_;
		return $network->reply($sender, $channel, $err) if $err;
		return $network->reply($sender, $channel, "Wikipedia page $title not found$if_show_more") unless defined $page;
		
		my $title = $page->{title} // '';
		my $url = $page->{fullurl} // '';
		my $extract = $page->{extract} // '';
		$extract =~ s/\n/ /g;
		
		my $b_code = chr 2;
		my $response = "Wikipedia search result: $b_code$title$b_code - $url - $extract$if_show_more";
		return $network->reply($sender, $channel, $response);
	});
}

1;

=head1 NAME

Bot::ZIRC::Plugin::Wikipedia - Wikipedia search plugin for Bot::ZIRC

=head1 SYNOPSIS

 my $bot = Bot::ZIRC->new(
   plugins => { Wikipedia => 1 },
 );
 
 # Standalone usage
 my $wiki = Bot::ZIRC::Plugin::Wikipedia->new;
 my ($err, $titles) = $wiki->wikipedia_search($query);
 foreach my $title (@$titles) {
   my ($err, $page) = $wiki->wikipedia_page($title);
 }

=head1 DESCRIPTION

Adds plugin methods and commands for searching Wikipedia to a L<Bot::ZIRC> IRC
bot.

=head1 METHODS

=head2 wikipedia_search

 my ($err, $titles) = $bot->wikipedia_search($query);
 $bot->wikipedia_search($query, sub {
   my ($err, $titles) = @_;
 });

Search Wikipedia pages. On error, the first return value contains the error
message. On success, the second return value contains the page titles (if any)
in an arrayref. Pass a callback to perform the query non-blocking.

=head2 wikipedia_page

 my ($err, $page) = $bot->wikipedia_page($title);
 $bot->wikipedia_page($title, sub {
   my ($err, $page) = @_;
 });

Retrieve a Wikipedia page by title. On error, the first return value contains
the error message. On success, the second return value contains the page data
if found. Pass a callback to perform the query non-blocking.

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

L<Bot::ZIRC>
