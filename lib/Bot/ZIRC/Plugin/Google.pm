package Bot::ZIRC::Plugin::Google;

use Carp 'croak';
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
	
	$bot->add_plugin_method($self, 'google_search_web');
	$bot->add_plugin_method($self, 'google_search_image');
	
	$bot->add_command(
		name => 'google',
		help_text => 'Search the web with Google',
		usage_text => '<query>',
		tokenize => 0,
		on_run => sub {
			my ($network, $sender, $channel, $query) = @_;
			return 'usage' unless length $query;
			
			$self->google_search_web($query, sub {
				my ($err, $results) = @_;
				return $network->reply($sender, $channel, $err) if $err;
				return $network->reply($sender, $channel, "No results for Google search") unless @$results;
				
				my $first_result = shift @$results;
				my $channel_name = lc ($channel // $sender);
				$self->_results_cache->{web}{$network}{$channel_name} = $results;
				my $show_more = @$results;
				$self->_google_result_web($network, $sender, $channel, $first_result, $show_more);
			});
		},
		on_more => sub {
			my ($network, $sender, $channel) = @_;
			my $channel_name = lc ($channel // $sender);
			my $results = $self->_results_cache->{web}{$network}{$channel_name} // [];
			return $network->reply($sender, $channel, "No more results for Google search") unless @$results;
			
			my $next_result = shift @$results;
			my $show_more = @$results;
			$self->_google_result_web($network, $sender, $channel, $next_result, $show_more);
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
			
			$self->google_search_image($query, sub {
				my ($err, $results) = @_;
				return $network->reply($sender, $channel, $err) if $err;
				return $network->reply($sender, $channel, "No results for Google image search") unless @$results;
				
				my $first_result = shift @$results;
				my $channel_name = lc ($channel // $sender);
				$self->_results_cache->{image}{$network}{$channel_name} = $results;
				my $show_more = @$results;
				$self->_google_result_image($network, $sender, $channel, $first_result, $show_more);
			});
		},
		on_more => sub {
			my ($network, $sender, $channel) = @_;
			my $channel_name = lc ($channel // $sender);
			my $results = $self->_results_cache->{image}{$network}{$channel_name} // [];
			return $network->reply($sender, $channel, "No more results for Google image search") unless @$results;
			
			my $next_result = shift @$results;
			my $show_more = @$results;
			$self->_google_result_image($network, $sender, $channel, $next_result, $show_more);
		},
	);
}

sub google_search_web {
	my ($self, $query, $cb) = @_;
	croak 'Undefined search query' unless defined $query;
	die GOOGLE_API_KEY_MISSING unless defined $self->api_key and defined $self->cse_id;
	
	my $request = Mojo::URL->new(GOOGLE_API_ENDPOINT)->query(key => $self->api_key,
		cx => $self->cse_id, q => $query, safe => 'high');
	if ($cb) {
		$self->ua->get($request, sub {
			my ($ua, $tx) = @_;
			return $cb->($self->ua_error($tx->error)) if $tx->error;
			return $cb->(undef, $tx->res->json->{items}//[]);
		});
	} else {
		my $tx = $self->ua->get($request);
		return $self->ua_error($tx->error) if $tx->error;
		return (undef, $tx->res->json->{items}//[]);
	}
}

sub google_search_image {
	my ($self, $query, $cb) = @_;
	croak 'Undefined search query' unless defined $query;
	die GOOGLE_API_KEY_MISSING unless defined $self->api_key and defined $self->cse_id;
	
	my $request = Mojo::URL->new(GOOGLE_API_ENDPOINT)->query(key => $self->api_key,
		cx => $self->cse_id, q => $query, safe => 'high', searchType => 'image');
	if ($cb) {
		$self->ua->get($request, sub {
			my ($ua, $tx) = @_;
			return $cb->($self->ua_error($tx->error)) if $tx->error;
			return $cb->(undef, $tx->res->json->{items}//[]);
		});
	} else {
		my $tx = $self->ua->get($request);
		return $self->ua_error($tx->error) if $tx->error;
		return (undef, $tx->res->json->{items}//[]);
	}
}

sub _google_result_web {
	my ($self, $network, $sender, $channel, $result, $show_more) = @_;
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

sub _google_result_image {
	my ($self, $network, $sender, $channel, $result, $show_more) = @_;
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

=head1 NAME

Bot::ZIRC::Plugin::Google - Google search plugin for Bot::ZIRC

=head1 SYNOPSIS

 my $bot = Bot::ZIRC->new(
   plugins => { Google => 1 },
 );
 
 # Standalone usage
 my $google = Bot::ZIRC::Plugin::Google->new(api_key => $api_key, cse_id => $cse_id);
 my ($err, $results) = $google->google_search_web($query);

=head1 DESCRIPTION

Adds plugin methods and commands for searching Google to a L<Bot::ZIRC> IRC
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

 my ($err, $results) = $bot->google_search_web($query);
 $bot->google_search_web($query, sub {
   my ($err, $results) = @_;
 });

Search Google web search. On error, the first return value contains the error
message. On success, the second return value contains the results (if any) in
an arrayref. Pass a callback to perform the query non-blocking.

=head2 google_search_image

 my ($err, $results) = $bot->google_search_image($query);
 $bot->google_search_image($query, sub {
   my ($err, $results) = @_;
 });

Search Google image search. On error, the first return value contains the error
message. On success, the second return value contains the results (if any) in
an arrayref. Pass a callback to perform the query non-blocking.

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
