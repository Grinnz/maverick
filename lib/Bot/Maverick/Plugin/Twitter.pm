package Bot::Maverick::Plugin::Twitter;

use Carp 'croak';
use Mojo::URL;
use Mojo::UserAgent;
use Mojo::Util 'html_unescape';
use Mojo::WebService::Twitter;
use Time::Duration 'ago';

use Moo;
with 'Bot::Maverick::Plugin';

our $VERSION = '0.20';

use constant TWITTER_API_KEY_MISSING => 
	"Twitter plugin requires configuration options 'twitter_api_key' and 'twitter_api_secret' in section 'apis'\n" .
	"Go to https://apps.twitter.com/ to obtain a Twitter API key and secret.\n";

has 'api_key' => (
	is => 'rw',
);

has 'api_secret' => (
	is => 'rw',
);

has 'twitter' => (
	is => 'lazy',
	init_arg => undef,
);

sub _build_twitter {
	my $self = shift;
	$self->_twitter_authorized(0);
	die TWITTER_API_KEY_MISSING unless defined (my $api_key = $self->api_key) and defined (my $api_secret = $self->api_secret);
	return Mojo::WebService::Twitter->new(ua => $self->bot->ua, api_key => $api_key, api_secret => $api_secret);
}

has '_twitter_authorized' => (
	is => 'rw',
	init_arg => undef,
);

has '_results_cache' => (
	is => 'ro',
	lazy => 1,
	default => sub { {} },
	init_arg => undef,
);

sub _authorize {
	my ($self) = @_;
	return $self->bot->new_future->done($self->twitter) if $self->_twitter_authorized;
	
	return $self->bot->callback_to_future(sub {
		$self->twitter->request_oauth2(shift);
	})->transform(done => sub {
		my $res = shift;
		$self->twitter->authentication(oauth2 => $res->{access_token});
		$self->_twitter_authorized(1);
		return $self->twitter;
	});
}

sub register {
	my ($self, $bot) = @_;
	$self->api_key($bot->config->param('apis','twitter_api_key'))
		unless defined $self->api_key;
	$self->api_secret($bot->config->param('apis','twitter_api_secret'))
		unless defined $self->api_secret;
	die TWITTER_API_KEY_MISSING unless defined $self->api_key and defined $self->api_secret;
	
	$bot->add_helper(twitter_api_key => sub { $self->api_key });
	$bot->add_helper(twitter_api_secret => sub { $self->api_secret });
	$bot->add_helper(twitter => sub { $self->twitter });
	$bot->add_helper(_twitter_authorize => sub { $self->_authorize });
	$bot->add_helper(_twitter_results_cache => sub { $self->_results_cache });
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
				return $m->bot->twitter_tweet_by_id($id)->on_done(sub {
					my $tweet = shift;
					return $m->reply("Tweet \#$id not found") unless defined $tweet;
					return _display_tweet($m, $tweet);
				})->on_fail(sub { $m->reply("Error retrieving tweet: $_[0]") });
			}
			
			# User timeline
			elsif ($query =~ /^\@(\S+)$/) {
				my $user = $1;
				return $m->bot->twitter_tweet_by_user($user)->on_done(sub {
					my $tweet = shift;
					return $m->reply("No tweets found for user \@$user") unless defined $tweet;
					return _display_tweet($m, $tweet);
				})->on_fail(sub { $m->reply("Error retrieving tweet: $_[0]") });
			}
			
			# Search
			else {
				return $m->bot->twitter_search($query)->on_done(sub {
					my $tweets = shift;
					return $m->reply("No results for Twitter search") unless @$tweets;
					my $first_tweet = shift @$tweets;
					my $channel_name = lc ($m->channel // $m->sender);
					$m->bot->_twitter_results_cache->{$m->network}{$channel_name} = $tweets;
					$m->show_more(scalar @$tweets);
					_display_tweet($m, $first_tweet);
				})->on_fail(sub { $m->reply("Twitter search error: $_[0]") });
			}
		},
		on_more => sub {
			my $m = shift;
			my $channel_name = lc ($m->channel // $m->sender);
			my $tweets = $m->bot->_twitter_results_cache->{$m->network}{$channel_name} // [];
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
		
		my $future = $m->bot->twitter_tweet_by_id($tweet_id)->on_done(sub { _display_triggered($m, shift) })
			->on_fail(sub { $m->logger->error("Error retrieving Twitter tweet data: $_[0]") });
		$m->bot->adopt_future($future);
	});
}

sub _twitter_tweet_by_id {
	my ($bot, $id) = @_;
	croak 'Undefined tweet ID' unless defined $id;
	
	return $bot->_twitter_authorize->then(sub {
		$bot->callback_to_future(sub { $bot->twitter->get_tweet($id, shift) });
	});
}

sub _twitter_tweet_by_user {
	my ($bot, $user) = @_;
	croak 'Undefined twitter user' unless defined $user;
	
	return $bot->_twitter_authorize->then(sub {
		$bot->callback_to_future(sub { $bot->twitter->get_user(screen_name => $user, shift) });
	})->transform(done => sub { shift->last_tweet });
}

sub _twitter_search {
	my ($bot, $query) = @_;
	croak 'Undefined twitter query' unless defined $query;
	
	return $bot->_twitter_authorize->then(sub {
		$bot->callback_to_future(sub { $bot->twitter->search_tweets($query, count => 15, include_entities => 'false', shift) });
	});
}

sub _display_tweet {
	my ($m, $tweet) = @_;
	
	my $username = $tweet->user->screen_name;
	my $id = $tweet->id;
	my $url = Mojo::URL->new('https://twitter.com')->path("$username/status/$id");
	
	my $in_reply_to_id = $tweet->in_reply_to_status_id;
	my $in_reply_to_user = $tweet->in_reply_to_screen_name;
	
	my $b_code = chr 2;
	my $in_reply_to = defined $in_reply_to_id
		? " in reply to $b_code\@$in_reply_to_user$b_code tweet \#$in_reply_to_id" : '';
	
	my $content = _parse_tweet_text($tweet->text);
	my $created_at = $tweet->created_at;
	my $ago = ago(defined $created_at ? time - $created_at->epoch : 0);
	
	my $name = $tweet->user->name;
	$name = defined $name ? "$name ($b_code\@$username$b_code)" : "$b_code\@$username$b_code";
	
	my $msg = "Tweeted by $name $ago$in_reply_to: $content ($url)";
	$m->reply($msg);
}

sub _display_triggered {
	my ($m, $tweet) = @_;
	return() unless defined $tweet;
	
	my $username = $tweet->user->screen_name;
	
	my $in_reply_to_id = $tweet->in_reply_to_status_id;
	my $in_reply_to_user = $tweet->in_reply_to_screen_name;
	
	my $b_code = chr 2;
	my $in_reply_to = defined $in_reply_to_id
		? " in reply to $b_code\@$in_reply_to_user$b_code tweet \#$in_reply_to_id" : '';
	
	my $content = _parse_tweet_text($tweet->text);
	my $created_at = $tweet->created_at;
	my $ago = ago(defined $created_at ? time - $created_at->epoch : 0);
	
	my $name = $tweet->user->name;
	$name = defined $name ? "$name ($b_code\@$username$b_code)" : "$b_code\@$username$b_code";
	
	my $sender = $m->sender;
	my $msg = "Tweet linked by $sender: Tweeted by $name $ago$in_reply_to: $content";
	$m->reply_bare($msg);
}

sub _parse_tweet_text {
	my ($text) = @_;
	
	$text = html_unescape $text;
	$text =~ s/\n/ /g;
	
	my @urls = $text =~ m!(https?://t.co/\w+)!g;
	my $ua = Mojo::UserAgent->new->max_redirects(0);
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
 my $tweets = $twitter->twitter_search($query)->get;
 my $tweet = $twitter->twitter_tweet_by_user($user)->get;
 my $tweet = $twitter->twitter_tweet_by_id($id)->get;

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

 my $tweets = $bot->twitter_search($query)->get;
 my $future = $bot->twitter_search($query)->on_done(sub {
   my $tweets = shift;
 })->on_fail(sub { $m->reply("Twitter search error: $_[0]") });

Search tweets on Twitter. Returns a L<Future::Mojo> with the results (if any)
in a L<Mojo::Collection> of L<Mojo::WebService::Twitter::Tweet> objects.

=head2 twitter_tweet_by_id

 my $tweet = $bot->twitter_tweet_by_id($id)->get;
 my $future = $bot->twitter_tweet_by_id($id)->on_done(sub {
   my $tweet = shift;
 })->on_fail(sub { $m->reply("Error retrieving tweet: $_[0]") });

Retrieve a tweet by Tweet ID. Returns a L<Future::Mojo> with a
L<Mojo::WebService::Twitter::Tweet> object.

=head2 twitter_tweet_by_user

 my $tweet = $bot->twitter_tweet_by_user($user)->get;
 my $future = $bot->twitter_tweet_by_user($user)->on_done(sub {
   my $tweet = shift;
 })->on_fail(sub { $m->reply("Error retrieving tweet: $_[0]") });

Retrieve the latest tweet in a user's timeline. Returns a L<Future::Mojo> with
a L<Mojo::WebService::Twitter::Tweet> object.

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

L<Bot::Maverick>, L<Mojo::WebService::Twitter>
