package Bot::Maverick::Plugin::Twitter;

use Carp 'croak';
use Date::Parse;
use Mojo::URL;
use Mojo::Util qw/b64_encode html_unescape url_escape/;
use Time::Duration 'ago';

use Moo;
extends 'Bot::Maverick::Plugin';

our $VERSION = '0.20';

use constant TWITTER_OAUTH_ENDPOINT => 'https://api.twitter.com/oauth2/token';
use constant TWITTER_API_ENDPOINT => 'https://api.twitter.com/1.1/';
use constant TWITTER_API_KEY_MISSING => 
	"Twitter plugin requires configuration options 'twitter_api_key' and 'twitter_api_secret' in section 'apis'\n" .
	"Go to https://apps.twitter.com/ to obtain a Twitter API key and secret.\n";

has 'api_key' => (
	is => 'rw',
);

has 'api_secret' => (
	is => 'rw',
);

has '_access_token' => (
	is => 'rw',
	predicate => 1,
	init_arg => undef,
);

has 'results_cache' => (
	is => 'ro',
	lazy => 1,
	default => sub { {} },
	init_arg => undef,
);

sub _build__access_token {
	my ($self, $cb) = @_;
	die TWITTER_API_KEY_MISSING unless defined $self->api_key and defined $self->api_secret;
	
	my $bearer_token = b64_encode(url_escape($self->api_key) . ':' . url_escape($self->api_secret), '');
	my $url = Mojo::URL->new(TWITTER_OAUTH_ENDPOINT);
	my $headers = { Authorization => "Basic $bearer_token",
		'Content-Type' => 'application/x-www-form-urlencoded;charset=UTF-8' };
	unless ($cb) {
		my $tx = $self->ua->post($url, $headers,
			form => { grant_type => 'client_credentials' });
		die $self->ua_error($tx->error) if $tx->error;
		$self->_access_token($tx->res->json->{access_token});
		return $self->_access_token;
	}
	return Mojo::IOLoop->delay(sub {
		$self->ua->post($url, $headers,
			form => { grant_type => 'client_credentials' }, shift->begin);
	}, sub {
		my ($delay, $tx) = @_;
		die $self->ua_error($tx->error) if $tx->error;
		$self->_access_token($tx->res->json->{access_token});
		$cb->($self->_access_token);
	});
}

sub _retrieve_access_token {
	my ($self, $cb) = @_;
	return $self->_has_access_token ? $self->_access_token : $self->_build__access_token unless $cb;
	return Mojo::IOLoop->delay(sub {
		my $delay = shift;
		return $cb->($self->_access_token) if $self->_has_access_token;
		$self->_build__access_token($cb)->catch(sub { $delay->remaining([])->emit(error => $_[1]) });
	});
}

sub register {
	my ($self, $bot) = @_;
	$self->api_key($bot->config->param('apis','twitter_api_key'))
		unless defined $self->api_key;
	$self->api_secret($bot->config->param('apis','twitter_api_secret'))
		unless defined $self->api_secret;
	die TWITTER_API_KEY_MISSING unless defined $self->api_key and defined $self->api_secret;
	
	$bot->add_helper(_twitter => sub { $self });
	$bot->add_helper(twitter_api_key => sub { shift->_twitter->api_key });
	$bot->add_helper(twitter_api_secret => sub { shift->_twitter->api_secret });
	$bot->add_helper(twitter_access_token => sub { shift->_twitter->_retrieve_access_token(@_) });
	$bot->add_helper(twitter_results_cache => sub { shift->_twitter->results_cache });
	$bot->add_helper(twitter_search => \&_twitter_search);
	$bot->add_helper(twitter_tweet_by_id => \&_twitter_tweet_by_id);
	$bot->add_helper(twitter_tweet_by_user => \&_twitter_tweet_by_user);
		
	$bot->add_command(
		name => 'twitter',
		help_text => 'Search tweets on Twitter',
		usage_text => '(<query>|#<tweet id>|@<twitter user>)',
		on_run => sub {
			my $m = shift;
			my $query = $m->args;
			return 'usage' unless length $query;
			
			# Tweet ID
			if ($query =~ /^#(\d+)$/) {
				my $id = $1;
				$m->bot->twitter_tweet_by_id($id, sub {
					my $tweet = shift;
					return $m->reply("Tweet \#$id not found") unless defined $tweet;
					return _display_tweet($m, $tweet);
				})->catch(sub { $m->reply("Error retrieving tweet: $_[1]") });
			}
			
			# User timeline
			elsif ($query =~ /^\@(\S+)$/) {
				my $user = $1;
				$m->bot->twitter_tweet_by_user($user, sub {
					my $tweet = shift;
					return $m->reply("No tweets found for user \@$user") unless defined $tweet;
					return _display_tweet($m, $tweet);
				})->catch(sub { $m->reply("Error retrieving tweet: $_[1]") });
			}
			
			# Search
			else {
				$m->bot->twitter_search($query, sub {
					my $tweets = shift;
					return $m->reply("No results for Twitter search") unless @$tweets;
					my $first_tweet = shift @$tweets;
					my $channel_name = lc ($m->channel // $m->sender);
					$m->bot->twitter_results_cache->{$m->network}{$channel_name} = $tweets;
					$m->show_more(scalar @$tweets);
					_display_tweet($m, $first_tweet);
				})->catch(sub { $m->reply("Twitter search error: $_[1]") });
			}
		},
		on_more => sub {
			my $m = shift;
			my $channel_name = lc ($m->channel // $m->sender);
			my $tweets = $m->bot->twitter_results_cache->{$m->network}{$channel_name} // [];
			return $m->reply("No more results for Twitter search") unless @$tweets;
			my $next_tweet = shift @$tweets;
			$m->show_more(scalar @$tweets);
			_display_tweet($m, $next_tweet);
		},
	);
	
	$bot->config->channel_default('twitter_trigger', 1);
	
	$bot->on(privmsg => sub {
		my ($bot, $m) = @_;
		my $message = $m->text;
		return unless defined $m->channel;
		return unless $m->config->channel_param($m->channel, 'twitter_trigger');
		return unless $message =~ m!\b(\S+twitter.com/(statuses|[^/]+?/status)\S+)!;
		my $captured = Mojo::URL->new($1);
		my $parts = $captured->path->parts;
		my $tweet_id = $parts->[0] eq 'statuses' ? $parts->[1] : $parts->[2];
		$m->logger->debug("Captured Twitter URL $captured with tweet ID $tweet_id");
		
		$m->bot->twitter_tweet_by_id($tweet_id, sub {
			my $tweet = shift;
			return _display_triggered($m, $tweet) if defined $tweet;
		})->catch(sub { $m->logger->error("Error retrieving Twitter tweet data: $_[1]") });
	});
}

sub _twitter_tweet_by_id {
	my ($bot, $id, $cb) = @_;
	croak 'Undefined tweet ID' unless defined $id;
	
	my $url = Mojo::URL->new(TWITTER_API_ENDPOINT)->path('statuses/show.json')->query(id => $id);
	unless ($cb) {
		my $token = $bot->twitter_access_token;
		my %headers = (Authorization => "Bearer $token");
		my $tx = $bot->ua->get($url, \%headers);
		die $bot->ua_error($tx->error) if $tx->error;
		return $tx->res->json;
	}
	return Mojo::IOLoop->delay(sub {
		my $delay = shift;
		$bot->twitter_access_token($delay->begin(0))
			->catch(sub { $delay->remaining([])->emit(error => $_[1]) });
	}, sub {
		my ($delay, $token) = @_;
		my %headers = (Authorization => "Bearer $token");
		$bot->ua->get($url, \%headers, $delay->begin);
	}, sub {
		my ($delay, $tx) = @_;
		die $bot->ua_error($tx->error) if $tx->error;
		$cb->($tx->res->json);
	});
}

sub _twitter_tweet_by_user {
	my ($bot, $user, $cb) = @_;
	croak 'Undefined twitter user' unless defined $user;
	
	my $url = Mojo::URL->new(TWITTER_API_ENDPOINT)->path('users/show.json')
		->query(screen_name => $user, include_entities => 'false');
	unless ($cb) {
		my $token = $bot->twitter_access_token;
		my %headers = (Authorization => "Bearer $token");
		my $tx = $bot->ua->get($url, \%headers);
		die $bot->ua_error($tx->error) if $tx->error;
		return _swap_user_tweet($tx->res->json);
	}
	return Mojo::IOLoop->delay(sub {
		my $delay = shift;
		$bot->twitter_access_token($delay->begin(0))
			->catch(sub { $delay->remaining([])->emit(error => $_[1]) });
	}, sub {
		my ($delay, $token) = @_;
		my %headers = (Authorization => "Bearer $token");
		$bot->ua->get($url, \%headers, $delay->begin);
	}, sub {
		my ($delay, $tx) = @_;
		die $bot->ua_error($tx->error) if $tx->error;
		$cb->(_swap_user_tweet($tx->res->json));
	});
}

sub _swap_user_tweet {
	my $user = shift // return undef;
	my $tweet = delete $user->{status};
	$tweet->{user} = $user;
	return $tweet;
}

sub _twitter_search {
	my ($bot, $query, $cb) = @_;
	croak 'Undefined twitter query' unless defined $query;
	
	my $url = Mojo::URL->new(TWITTER_API_ENDPOINT)->path('search/tweets.json')
		->query(q => $query, count => 15, include_entities => 'false');
	unless ($cb) {
		my $token = $bot->twitter_access_token;
		my %headers = (Authorization => "Bearer $token");
		my $tx = $bot->ua->get($url, \%headers);
		die $bot->ua_error($tx->error) if $tx->error;
		return $tx->res->json->{statuses}//[];
	}
	return Mojo::IOLoop->delay(sub {
		my $delay = shift;
		$bot->twitter_access_token($delay->begin(0))
			->catch(sub { $delay->remaining([])->emit(error => $_[1]) });
	}, sub {
		my ($delay, $token) = @_;
		my %headers = (Authorization => "Bearer $token");
		$bot->ua->get($url, \%headers, $delay->begin);
	}, sub {
		my ($delay, $tx) = @_;
		die $bot->ua_error($tx->error) if $tx->error;
		$cb->($tx->res->json->{statuses}//[]);
	});
}

sub _display_tweet {
	my ($m, $tweet) = @_;
	
	my $username = $tweet->{user}{screen_name};
	my $id = $tweet->{id_str};
	my $url = Mojo::URL->new('https://twitter.com')->path("$username/status/$id");
	
	my $in_reply_to_id = $tweet->{in_reply_to_status_id_str};
	my $in_reply_to_user = $tweet->{in_reply_to_screen_name};
	
	my $b_code = chr 2;
	my $in_reply_to = defined $in_reply_to_id
		? " in reply to $b_code\@$in_reply_to_user$b_code tweet \#$in_reply_to_id" : '';
	
	my $content = _parse_tweet_text($m->bot->ua, $tweet->{text});
	my $created_at = str2time($tweet->{created_at}) // time;
	my $ago = ago(time - $created_at);
	
	my $name = $tweet->{user}{name};
	$name = defined $name ? "$name ($b_code\@$username$b_code)" : "$b_code\@$username$b_code";
	
	my $msg = "Tweeted by $name $ago$in_reply_to: $content ($url)";
	$m->reply($msg);
}

sub _display_triggered {
	my ($m, $tweet) = @_;
	
	my $username = $tweet->{user}{screen_name};
	
	my $in_reply_to_id = $tweet->{in_reply_to_status_id_str};
	my $in_reply_to_user = $tweet->{in_reply_to_screen_name};
	
	my $b_code = chr 2;
	my $in_reply_to = defined $in_reply_to_id
		? " in reply to $b_code\@$in_reply_to_user$b_code tweet \#$in_reply_to_id" : '';
	
	my $content = _parse_tweet_text($m->bot->ua, $tweet->{text});
	my $created_at = str2time($tweet->{created_at}) // time;
	my $ago = ago(time - $created_at);
	
	my $name = $tweet->{user}{name};
	$name = defined $name ? "$name ($b_code\@$username$b_code)" : "$b_code\@$username$b_code";
	
	my $sender = $m->sender;
	my $msg = "Tweet linked by $sender: Tweeted by $name $ago$in_reply_to: $content";
	$m->reply_bare($msg);
}

sub _parse_tweet_text {
	my ($ua, $text) = @_;
	
	$text = html_unescape $text;
	$text =~ s/\n/ /g;
	
	my @urls = $text =~ m!(https?://t.co/\w+)!g;
	foreach my $url (@urls) {
		my $tx = $ua->head($url);
		if ($tx->success and $tx->res->is_status_class(300)) {
			my $redir = $tx->res->headers->location;
			if (defined $redir and $redir ne $url) {
				$text =~ s/\Q$url/$redir/g;
			}
		}
	}
	
	return $text;
}

1;

=head1 NAME

Bot::Maverick::Plugin::Twitter - Twitter plugin for Maverick

=head1 SYNOPSIS

 my $bot = Bot::Maverick->new(
   plugins => { Twitter => 1 },
 );
 
 # Standalone usage
 my $twitter = Bot::Maverick::Plugin::Twitter->new(api_key => $api_key, api_secret => $api_secret);
 my $tweets = $twitter->twitter_search($query);
 my $tweet = $twitter->twitter_tweet_by_user($user);
 my $tweet = $twitter->twitter_tweet_by_id($id);

=head1 DESCRIPTION

Adds helper methods and commands for interacting with Twitter to a
L<Bot::Maverick> IRC bot. Also adds a hook to display information about tweets
linked in a channel.

This plugin requires a Twitter API key and API secret, as configuration options
C<twitter_api_key> and C<twitter_api_secret> in the C<apis> section. Go to
L<https://apps.twitter.com/> to obtain an API key and secret.

=head1 ATTRIBUTES

=head2 api_key

API key for Twitter API, defaults to value of configuration option
C<twitter_api_key> in section C<apis>.

=head2 api_secret

API secret for Twitter API, defaults to value of configuration option
C<twitter_api_secret> in section C<apis>.

=head1 METHODS

=head2 twitter_search

 my $tweets = $bot->twitter_search($query);
 $bot->twitter_search($query, sub {
   my $tweets = shift;
 })->catch(sub { $m->reply("Twitter search error: $_[1]") });

Search tweets on Twitter. Returns the results (if any) in an arrayref, or
throws an exception on error. Pass a callback to perform the query
non-blocking.

=head2 twitter_tweet_by_id

 my $tweet = $bot->twitter_tweet_by_id($id);
 $bot->twitter_tweet_by_id($id, sub {
   my $tweet = shift;
 })->catch(sub { $m->reply("Error retrieving tweet: $_[1]") });

Retrieve a tweet by Tweet ID. Returns the tweet data as a hashref, or throws an
exception on error. Pass a callback to perform the query non-blocking.

=head2 twitter_tweet_by_user

 my $tweet = $bot->twitter_tweet_by_user($user);
 $bot->twitter_tweet_by_user($user, sub {
   my $tweet = shift;
 })->catch(sub { $m->reply("Error retrieving tweet: $_[1]") });

Retrieve the latest tweet in a user's timeline. Returns the tweet data as a
hashref, or throws an exception on error. Pass a callback to perform the query
non-blocking.

=head1 CONFIGURATION

=head2 twitter_trigger

 !set #bots twitter_trigger 0

Enable or disable automatic response with information about linked tweets.
Defaults to 1 (on).

=head1 COMMANDS

=head2 twitter

 !twitter defiantly
 !twitter #585919167833870336
 !twitter @dominos

Search twitter and display the first result if any; or, with # or @ characters,
retrieve a tweet by ID or user. Additional results for searches can be
retrieved using the C<more> command.

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
