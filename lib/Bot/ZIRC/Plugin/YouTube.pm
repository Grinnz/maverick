package Bot::ZIRC::Plugin::YouTube;

use Carp 'croak';
use Mojo::URL;
use Time::Duration 'ago';

use Moo;
extends 'Bot::ZIRC::Plugin';

use constant YOUTUBE_API_ENDPOINT => 'https://www.googleapis.com/youtube/v3/';
use constant YOUTUBE_VIDEO_URL => 'https://www.youtube.com/watch';
use constant YOUTUBE_API_KEY_MISSING => 
	"YouTube plugin requires configuration option 'google_api_key' in section 'apis'\n" .
	"See https://developers.google.com/youtube/registering_an_application " .
	"for more information on obtaining a Google API key.\n";

has 'api_key' => (
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
	die YOUTUBE_API_KEY_MISSING unless defined $self->api_key;
	
	$bot->add_plugin_method($self, 'youtube_search');
	
	$bot->add_command(
		name => 'youtube',
		help_text => 'Search YouTube videos',
		usage_text => '<search query>',
		on_run => sub {
			my $m = shift;
			my $query = $m->args;
			return 'usage' unless length $query;
			
			$self->youtube_search($query, sub {
				my ($err, $results) = @_;
				return $m->reply($err) if $err;
				return $m->reply("No results for YouTube search") unless @$results;
				
				my $first_result = shift @$results;
				my $channel_name = lc ($m->channel // $m->sender);
				$self->_results_cache->{$m->network}{$channel_name} = $results;
				my $show_more = @$results;
				$self->_display_result($m, $first_result, $show_more);
			});
		},
		on_more => sub {
			my $m = shift;
			my $channel_name = lc ($m->channel // $m->sender);
			my $results = $self->_results_cache->{$m->network}{$channel_name} // [];
			return $m->reply("No more results for YouTube search") unless @$results;
			
			my $next_result = shift @$results;
			my $show_more = @$results;
			$self->_display_result($m, $next_result, $show_more);
		},
	);
	
	$bot->config->set_channel_default('youtube_trigger', 1);
	
	$bot->on(privmsg => sub {
		my ($bot, $m) = @_;
		my $message = $m->text;
		return unless defined $m->channel;
		return unless $m->config->get_channel($m->channel, 'youtube_trigger');
		
		return unless $message =~ m!\b(\S+youtube.com/watch\S+)!;
		my $captured = Mojo::URL->new($1);
		my $video_id = $captured->query->param('v') // return;
		
		$m->logger->debug("Captured YouTube URL $captured with video ID $video_id");
		$self->youtube_video($video_id, sub {
			my ($err, $result) = @_;
			return $m->logger->error("Error retrieving YouTube video data: $err") if $err;
			return unless defined $result;
			$self->_display_triggered($m, $result);
		});
	});
}

sub youtube_search {
	my ($self, $query, $cb) = @_;
	croak 'Undefined search query' unless defined $query;
	die YOUTUBE_API_KEY_MISSING unless defined $self->api_key;
	
	my $request = Mojo::URL->new(YOUTUBE_API_ENDPOINT)->path('search')
		->query(key => $self->api_key, part => 'snippet', q => $query,
			safeSearch => 'strict', type => 'video');
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

sub youtube_video {
	my ($self, $id, $cb) = @_;
	croak 'Undefined video ID' unless defined $id;
	die YOUTUBE_API_KEY_MISSING unless defined $self->api_key;
	
	my $request = Mojo::URL->new(YOUTUBE_API_ENDPOINT)->path('videos')
		->query(key => $self->api_key, part => 'snippet', id => $id);
	if ($cb) {
		$self->ua->get($request, sub {
			my ($ua, $tx) = @_;
			return $cb->($self->ua_error($tx->error)) if $tx->error;
			my $results = $tx->res->json->{items} // [];
			return $cb->(undef, $results->[0]);
		});
	} else {
		my $tx = $self->ua->get($request);
		return $self->ua_error($tx->error) if $tx->error;
		my $results = $tx->res->json->{items} // [];
		return (undef, $results->[0]);
	}
}

sub _display_result {
	my ($self, $m, $result, $show_more) = @_;
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
	$m->reply($response);
}

sub _display_triggered {
	my ($self, $m, $result) = @_;
	my $video_id = $result->{id} // '';
	my $title = $result->{snippet}{title} // '';
	
	my $ytchannel = $result->{snippet}{channelTitle} // '';
	
	my $description = $result->{snippet}{description} // '';
	$description = substr($description, 0, 200) . '...' if length $description > 200;
	$description = " - $description" if length $description;
	
	my $b_code = chr 2;
	my $sender = $m->sender;
	my $response = "YouTube video linked by $sender: $b_code$title$b_code - " .
		"published by $b_code$ytchannel$b_code$description";
	$m->reply_bare($response);
}

1;

=head1 NAME

Bot::ZIRC::Plugin::YouTube - YouTube search plugin for Bot::ZIRC

=head1 SYNOPSIS

 my $bot = Bot::ZIRC->new(
   plugins => { YouTube => 1 },
 );
 
 # Standalone usage
 my $youtube = Bot::ZIRC::Plugin::YouTube->new(api_key => $api_key);
 my ($err, $results) = $youtube->youtube_search($query);

=head1 DESCRIPTION

Adds plugin methods and commands for searching YouTube to a L<Bot::ZIRC> IRC
bot. Also adds a hook to display information about YouTube videos linked in a
channel.

This plugin requires a Google API key as configuration option C<google_api_key>
in the C<apis> section. See
L<https://developers.google.com/youtube/registering_an_application> for
information on obtaining an API key.

=head1 ATTRIBUTES

=head2 api_key

API key for Google API, defaults to value of configuration option
C<google_api_key> in section C<apis>.

=head1 METHODS

=head2 youtube_search

 my ($err, $results) = $bot->youtube_search($query);
 $bot->youtube_search($query, sub {
   my ($err, $results) = @_;
 });

Search YouTube videos. On error, the first return value contains the error
message. On success, the second return value contains the results (if any) in
an arrayref. Pass a callback to perform the query non-blocking.

=head1 CONFIGURATION

=head2 youtube_trigger

 !set #bots youtube_trigger 0

Enable or disable automatic response of video information triggered by YouTube
links. Defaults on 1 (on).

=head1 COMMANDS

=head2 youtube

 !youtube cats knocking stuff over
 !youtube disrespect your surroundings
 !youtube the numa numa guy

Search YouTube videos and display the first result, if any. Additional results
can be retrieved using the C<more> command.

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
