package Bot::Maverick::Plugin::LastFM;

use Carp 'croak';
use Mojo::IOLoop;
use Mojo::URL;
use Time::Duration 'ago';

use Moo;
extends 'Bot::Maverick::Plugin';

our $VERSION = '0.20';

use constant LASTFM_API_ENDPOINT => 'http://ws.audioscrobbler.com/2.0/';
use constant LASTFM_API_KEY_MISSING =>
	"Last.fm plugin requires configuration option 'lastfm_api_key' in section 'apis'\n" .
	"See http://www.last.fm/api/authentication for more information on obtaining a Last.fm API key.\n";

has 'api_key' => (
	is => 'rw',
);

sub register {
	my ($self, $bot) = @_;
	$self->api_key($bot->config->param('apis','lastfm_api_key')) unless defined $self->api_key;
	die LASTFM_API_KEY_MISSING unless defined $self->api_key;
	
	$bot->add_helper(_lastfm => sub { $self });
	$bot->add_helper(lastfm_api_key => sub { shift->_lastfm->api_key });
	$bot->add_helper(lastfm_last_track => \&_lastfm_last_track);
	
	$bot->add_command(
		name => 'np',
		help_text => 'Show now playing information, or set Last.fm username',
		usage_text => '[<Last.fm username>|set <Last.fm username>]',
		on_run => sub {
			my $m = shift;
			my @args = $m->args_list;
			my $sender = $m->sender->identity // $m->sender->nick;
			
			if (@args and lc $args[0] eq 'set') {
				my $username = $args[1];
				return 'usage' unless defined $username and length $username;
				$m->bot->storage->data->{lastfm}{usernames}{lc $sender} = $username;
				return $m->reply("Set Last.fm username of $sender to $username");
			}
			
			my $username = shift @args;
			unless (defined $username) {
				$username = $m->bot->storage->data->{lastfm}{usernames}{lc $sender} // $m->sender->nick;
			}
			
			$m->logger->debug("Retrieving Last.fm recent tracks for $username");
			$m->bot->lastfm_last_track($username, sub {
				my $track = shift;
				return $m->reply("No recent tracks found for $username")
					unless defined $track;
				_lastfm_result($m, $track, $username);
			})->catch(sub { $m->reply("Error retrieving recent tracks for $username: $_[1]") });
		},
	);
}

sub _lastfm_last_track {
	my ($bot, $username, $cb) = @_;
	croak 'Undefined Last.fm username' unless defined $username;
	die LASTFM_API_KEY_MISSING unless defined $bot->lastfm_api_key;
	
	my $request = Mojo::URL->new(LASTFM_API_ENDPOINT)->query(method => 'user.getrecenttracks',
		user => $username, api_key => $bot->lastfm_api_key, format => 'json', limit => 1);
	unless ($cb) {
		my $tx = $bot->ua->get($request);
		die $bot->ua_error($tx->error) if $tx->error;
		return _lastfm_recenttrack($tx->res->json);
	}
	return Mojo::IOLoop->delay(sub {
		$bot->ua->get($request, shift->begin);
	}, sub {
		my ($delay, $tx) = @_;
		die $bot->ua_error($tx->error) if $tx->error;
		$cb->(_lastfm_recenttrack($tx->res->json));
	});
}

sub _lastfm_recenttrack {
	my $response = shift;
	die "Last.fm error: $response->{message}\n" if $response->{error};
	return ref $response->{recenttracks}{track} eq 'ARRAY'
		? $response->{recenttracks}{track}[0] : $response->{recenttracks}{track};
}

sub _lastfm_result {
	my ($m, $track, $username) = @_;
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
	
	$m->reply($response);
}

1;

=head1 NAME

Bot::Maverick::Plugin::LastFM - Last.FM plugin for Maverick

=head1 SYNOPSIS

 my $bot = Bot::Maverick->new(
   plugins => { LastFM => 1 },
 );
 
 # Standalone usage
 my $lastfm = Bot::Maverick::Plugin::LastFM->new(api_key => $api_key);
 my $track = $lastfm->lastfm_last_track($username);

=head1 DESCRIPTION

Adds helper method and command for retrieving Last.FM last-track-played
information to a L<Bot::Maverick> IRC bot.

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

 my $track = $bot->lastfm_last_track($username);
 $bot->lastfm_last_track($username, sub {
   my $track = shift;
 })->catch(sub { $m->reply("Error retrieving recent tracks for $username: $_[1]") });

Retrieve last-played track information from Last.FM for a username. Returns the
track information as a hashref, or undef if no recent tracks are found. Throws
an exception on error. Pass a callback to perform the query non-blocking.

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

L<Bot::Maverick>
