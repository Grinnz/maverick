package Bot::ZIRC::Plugin::LastFM;

use Carp 'croak';
use Mojo::URL;
use Time::Duration 'ago';

use Moo;
extends 'Bot::ZIRC::Plugin';

use constant LASTFM_API_ENDPOINT => 'http://ws.audioscrobbler.com/2.0/';
use constant LASTFM_API_KEY_MISSING =>
	"Last.fm plugin requires configuration option 'lastfm_api_key' in section 'apis'\n" .
	"See http://www.last.fm/api/authentication for more information on obtaining a Last.fm API key.\n";

has 'api_key' => (
	is => 'rw',
);

sub register {
	my ($self, $bot) = @_;
	$self->api_key($bot->config->get('apis','lastfm_api_key')) unless defined $self->api_key;
	die LASTFM_API_KEY_MISSING unless defined $self->api_key;
	
	$bot->add_plugin_method($self, 'lastfm_last_track');
	
	$bot->add_command(
		name => 'np',
		help_text => 'Show now playing information, or set Last.fm username',
		usage_text => '[<Last.fm username>|set <Last.fm username>]',
		on_run => sub {
			my ($network, $sender, $channel, @args) = @_;
			
			if (@args and lc $args[0] eq 'set') {
				my $username = $args[1];
				return 'usage' unless defined $username and length $username;
				$network->storage->data->{lastfm}{usernames}{lc $sender} = $username;
				return $network->reply($sender, $channel, "Set Last.fm username of $sender to $username");
			}
			
			my $username = shift @args;
			unless (defined $username) {
				$username = $network->storage->data->{lastfm}{usernames}{lc $sender} // $sender->nick;
			}
			
			$network->logger->debug("Retrieving Last.fm recent tracks for $username");
			$self->lastfm_last_track($username, sub {
				my ($err, $track) = @_;
				return $network->reply($sender, $channel, $err) if $err;
				return $network->reply($sender, $channel, "No recent tracks found for $username")
					unless defined $track;
				$self->_lastfm_result($network, $sender, $channel, $track, $username);
			});
		},
	);
}

sub lastfm_last_track {
	my ($self, $username, $cb) = @_;
	croak 'Undefined Last.fm username' unless defined $username;
	die LASTFM_API_KEY_MISSING unless defined $self->api_key;
	
	my $request = Mojo::URL->new(LASTFM_API_ENDPOINT)->query(method => 'user.getrecenttracks',
		user => $username, api_key => $self->api_key, format => 'json', limit => 1);
	if ($cb) {
		$self->ua->get($request, sub {
			my ($ua, $tx) = @_;
			return $cb->($self->ua_error($tx->error)) if $tx->error;
			my $res = $tx->res->json;
			return $cb->("Last.fm error: $res->{message}") if $res->{error};
			my $track = $res->{recenttracks}{track};
			$track = shift @$track if ref $track eq 'ARRAY';
			return $cb->(undef, $track);
		});
	} else {
		my $tx = $self->ua->get($request);
		return $self->ua_error($tx->error) if $tx->error;
		my $res = $tx->res->json;
		return "Last.fm error: $res->{message}" if $res->{error};
		my $track = $res->{recenttracks}{track};
		$track = shift @$track if ref $track eq 'ARRAY';
		return (undef, $track);
	}
}

sub _lastfm_result {
	my ($self, $network, $sender, $channel, $track, $username) = @_;
	my $track_name = $track->{name} // '';
	my $artist = $track->{artist}{'#text'};
	my $album = $track->{album}{'#text'};
	my $nowplaying = $track->{'@attr'}{nowplaying};
	my $played_at = $track->{date}{uts} // time;
	
	my $response = $track_name;
	$response = "$artist - $response" if defined $artist and length $artist;
	$response = "$response (from $album)" if defined $album and length $album;
	$response = $nowplaying ? "Now playing for $username: $response"
		: "Last track played for $username: $response ".ago(time-$played_at);
	
	$network->reply($sender, $channel, $response);
}

1;

=head1 NAME

Bot::ZIRC::Plugin::LastFM - Last.FM plugin for Bot::ZIRC

=head1 SYNOPSIS

 my $bot = Bot::ZIRC->new(
   plugins => { LastFM => 1 },
 );
 
 # Standalone usage
 my $lastfm = Bot::ZIRC::Plugin::LastFM->new(api_key => $api_key);
 my ($err, $track) = $lastfm->lastfm_last_track($username);

=head1 DESCRIPTION

Adds plugin method and command for retrieving Last.FM last-track-played
information to a L<Bot::ZIRC> IRC bot.

This plugin requires a Last.FM API key, as configuration option
C<lastfm_api_key> in section C<apis>. See
L<http://www.last.fm/api/authentication> for information on obtaining an API
key.

=head1 ATTRIBUTES

=head2 api_key

API key for Last.FM API, defaults to value of configuration option
C<lastfm_api_key> in section C<apis>.

=head1 METHODS

=head2 lastfm_last_track

 my ($err, $track) = $bot->lastfm_last_track($username);
 $bot->lastfm_last_track($username, sub {
   my ($err, $track) = @_;
 });

Retrieve last-played track information from Last.FM for a username. On error,
the first return value contains the error message. Otherwise, the second return
value contains the most recently played track, or undef if none was found. Pass
a callback to perform the query non-blocking.

=head1 COMMANDS

=head2 np

 !np
 !np CoolGuy
 !np set CoolGuy

Display last-played or currently playing track for user. Defaults to sender's
nick. Use the C<set> syntax to set a Last.FM account to be used as your
default.

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
