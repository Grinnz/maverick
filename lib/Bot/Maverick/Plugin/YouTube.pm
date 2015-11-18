package Bot::Maverick::Plugin::YouTube;

use Carp 'croak';
use Mojo::URL;
use Time::Duration 'ago';

use Moo;
with 'Bot::Maverick::Plugin';

our $VERSION = '0.20';

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
	$self->api_key($bot->config->param('apis','google_api_key')) unless defined $self->api_key;
	die YOUTUBE_API_KEY_MISSING unless defined $self->api_key;
	
	$bot->add_helper(youtube_api_key => sub { $self->api_key });
	$bot->add_helper(_youtube_results_cache => sub { $self->_results_cache });
	$bot->add_helper(youtube_search => \&_youtube_search);
	$bot->add_helper(youtube_video => \&_youtube_video);
	
	$bot->add_command(
		name => 'youtube',
		help_text => 'Search YouTube videos',
		usage_text => '<search query>',
		on_run => sub {
			my $m = shift;
			my $query = $m->args;
			return 'usage' unless length $query;
			
			return $m->bot->youtube_search($query)->on_done(sub {
				my $results = shift;
				return $m->reply("No results for YouTube search") unless @$results;
				
				my $first_result = shift @$results;
				my $channel_name = lc ($m->channel // $m->sender);
				$m->bot->_youtube_results_cache->{$m->network}{$channel_name} = $results;
				$m->show_more(scalar @$results);
				_display_result($m, $first_result);
			})->on_fail(sub { $m->reply("YouTube search error: $_[0]") });
		},
		on_more => sub {
			my $m = shift;
			my $channel_name = lc ($m->channel // $m->sender);
			my $results = $m->bot->_youtube_results_cache->{$m->network}{$channel_name} // [];
			return $m->reply("No more results for YouTube search") unless @$results;
			
			my $next_result = shift @$results;
			$m->show_more(scalar @$results);
			_display_result($m, $next_result);
		},
	);
	
	$bot->config->channel_default('youtube_trigger', 1);
	
	$bot->on(privmsg => sub {
		my ($bot, $m) = @_;
		my $message = $m->text;
		return unless defined $m->channel;
		return unless $m->config->channel_param($m->channel, 'youtube_trigger');
		
		return unless $message =~ m!\b((https?://)?(?:(?:www\.)?youtube\.com/watch\?[-a-z0-9_=&;:%]+|youtu\.be/[-a-z0-9_]+))!i;
		my $captured = Mojo::URL->new(length $2 ? $1 : "https://$1");
		my $video_id = $captured->query->param('v') // $captured->path->parts->[0] // return;
		
		$m->logger->debug("Captured YouTube URL $captured with video ID $video_id");
		my $future = $m->bot->youtube_video($video_id)->on_done(sub { _display_triggered($m, shift) })
			->on_fail(sub { $m->logger->error("Error retrieving YouTube video data: $_[0]") });
		$m->bot->adopt_future($future);
	});
}

sub _youtube_search {
	my ($bot, $query) = @_;
	croak 'Undefined search query' unless defined $query;
	die YOUTUBE_API_KEY_MISSING unless defined $bot->youtube_api_key;
	
	my $request = Mojo::URL->new(YOUTUBE_API_ENDPOINT)->path('search')
		->query(key => $bot->youtube_api_key, part => 'snippet', q => $query,
			safeSearch => 'strict', type => 'video');
	return $bot->ua_request($request)->transform(done => sub { shift->json->{items} // [] });
}

sub _youtube_video {
	my ($bot, $id) = @_;
	croak 'Undefined video ID' unless defined $id;
	die YOUTUBE_API_KEY_MISSING unless defined $bot->youtube_api_key;
	
	my $request = Mojo::URL->new(YOUTUBE_API_ENDPOINT)->path('videos')
		->query(key => $bot->youtube_api_key, part => 'snippet', id => $id);
	return $bot->ua_request($request)->transform(done => sub { (shift->json->{items} // [])->[0] });
}

sub _display_result {
	my ($m, $result) = @_;
	my $video_id = $result->{id}{videoId} // '';
	my $title = $result->{snippet}{title} // '';
	
	my $url = Mojo::URL->new(YOUTUBE_VIDEO_URL)->query(v => $video_id)->to_string;
	my $ytchannel = $result->{snippet}{channelTitle} // '';
	
	my $description = $result->{snippet}{description} // '';
	$description =~ s/\n/ /g;
	$description = " - $description" if length $description;
	
	my $b_code = chr 2;
	my $response = "YouTube search result: $b_code$title$b_code - " .
		"published by $b_code$ytchannel$b_code - $url$description";
	$m->reply($response);
}

sub _display_triggered {
	my ($m, $result) = @_;
	return undef unless defined $result;
	my $video_id = $result->{id} // '';
	my $title = $result->{snippet}{title} // '';
	
	my $ytchannel = $result->{snippet}{channelTitle} // '';
	
	my $description = $result->{snippet}{description} // '';
	$description =~ s/\n/ /g;
	$description = " - $description" if length $description;
	
	my $b_code = chr 2;
	my $sender = $m->sender;
	my $response = "YouTube video linked by $sender: $b_code$title$b_code - " .
		"published by $b_code$ytchannel$b_code$description";
	$m->reply_bare($response);
}

1;

=head1 NAME

Bot::Maverick::Plugin::YouTube - YouTube search plugin for Maverick

=head1 SYNOPSIS

 my $bot = Bot::Maverick->new(
   plugins => { YouTube => 1 },
 );
 
 # Standalone usage
 my $youtube = Bot::Maverick::Plugin::YouTube->new(api_key => $api_key);
 my $results = $youtube->youtube_search($query)->get;

=head1 DESCRIPTION

Adds helper methods and commands for searching YouTube to a L<Bot::Maverick> IRC
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

 my $results = $bot->youtube_search($query)->get;
 my $future = $bot->youtube_search($query)->on_done(sub {
   my $results = shift;
 })->on_fail(sub { $m->reply("YouTube search error: $_[0]") });

Search YouTube videos. Returns a L<Future::Mojo> with the results (if any) in
an arrayref.

=head2 youtube_video

 my $result = $bot->youtube_video($video_id)->get;
 my $future = $bot->youtube_video($video_id)->on_done(sub {
   my $result = shift;
 })->on_fail(sub { $m->reply("YouTube search error: $_[0]") });

Retrieve information for a YouTube video by its video ID. Returns a
L<Future::Mojo> with the result if found or undef otherwise.

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

L<Bot::Maverick>
