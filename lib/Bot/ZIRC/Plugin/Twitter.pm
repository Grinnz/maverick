package Bot::ZIRC::Plugin::Twitter;

use Carp 'croak';
use Date::Parse;
use Mojo::URL;
use Mojo::Util qw/b64_encode html_unescape url_escape/;
use Time::Duration 'ago';

use Moo;
extends 'Bot::ZIRC::Plugin';

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
	lazy => 1,
	builder => 1,
	init_arg => undef,
);

has 'results_cache' => (
	is => 'ro',
	lazy => 1,
	default => sub { {} },
	init_arg => undef,
);

sub _build__access_token {
	my $self = shift;
	die TWITTER_API_KEY_MISSING unless defined $self->api_key and defined $self->api_secret;
	
	my $bearer_token = b64_encode(url_escape($self->api_key) . ':' . url_escape($self->api_secret), '');
	my $url = Mojo::URL->new(TWITTER_OAUTH_ENDPOINT);
	my $headers = { Authorization => "Basic $bearer_token",
		'Content-Type' => 'application/x-www-form-urlencoded;charset=UTF-8' };
	my $tx = $self->ua->post($url, $headers,
		form => { grant_type => 'client_credentials' });
	die $self->ua_error($tx->error) if $tx->error;
	return $tx->res->json->{access_token};
}

sub register {
	my ($self, $bot) = @_;
	$self->api_key($bot->config->get('apis','twitter_api_key'))
		unless defined $self->api_key;
	$self->api_secret($bot->config->get('apis','twitter_api_secret'))
		unless defined $self->api_secret;
	die TWITTER_API_KEY_MISSING unless defined $self->api_key and defined $self->api_secret;
	
	$bot->add_plugin_method($self, 'twitter_search');
	$bot->add_plugin_method($self, 'twitter_tweet_by_id');
	$bot->add_plugin_method($self, 'twitter_tweet_by_user');
		
	$bot->add_command(
		name => 'twitter',
		help_text => 'Search tweets on Twitter',
		usage_text => '(<query>|#<tweet id>|@<twitter user>)',
		tokenize => 0,
		on_run => sub {
			my ($network, $sender, $channel, $query) = @_;
			return 'usage' unless length $query;
			
			# Tweet ID
			if ($query =~ /^#(\d+)$/) {
				my $id = $1;
				$self->twitter_tweet_by_id($id, sub {
					my ($err, $tweet) = @_;
					return $network->reply($sender, $channel, $err) if $err;
					return $self->_display_tweet($network, $sender, $channel, $tweet);
				});
			}
			
			# User timeline
			elsif ($query =~ /^\@(\S+)$/) {
				my $user = $1;
				$self->twitter_tweet_by_user($user, sub {
					my ($err, $tweet) = @_;
					return $network->reply($sender, $channel, $err) if $err;
					return $self->_display_tweet($network, $sender, $channel, $tweet);
				});
			}
			
			# Search
			else {
				$self->twitter_search($query, sub {
					my ($err, $tweets) = @_;
					return $network->reply($sender, $channel, "No results for Twitter search") unless @$tweets;
					my $first_tweet = shift @$tweets;
					my $channel_name = lc ($channel // $sender);
					$self->results_cache->{$network}{$channel_name} = $tweets;
					my $show_more = @$tweets;
					$self->_display_tweet($network, $sender, $channel, $first_tweet, $show_more);
				});
			}
		},
		on_more => sub {
			my ($network, $sender, $channel) = @_;
			my $channel_name = lc ($channel // $sender);
			my $tweets = $self->results_cache->{$network}{$channel_name} // [];
			return $network->reply($sender, $channel, "No more results for Twitter search") unless @$tweets;
			my $next_tweet = shift @$tweets;
			my $show_more = @$tweets;
			$self->_display_tweet($network, $sender, $channel, $next_tweet, $show_more);
		},
	);
	
	$bot->config->set_channel_default('twitter_trigger', 1);
	
	$bot->add_hook_privmsg(sub {
		my ($network, $sender, $channel, $message) = @_;
		return unless defined $channel;
		return unless $network->config->get_channel($channel, 'twitter_trigger');
		return unless $message =~ m!\b(\S+twitter.com/(statuses|[^/]+?/status)\S+)!;
		my $token = $self->_access_token;
		
		my $captured = Mojo::URL->new($1);
		my $parts = $captured->path->parts;
		my $tweet_id = $parts->[0] eq 'statuses' ? $parts->[1] : $parts->[2];
		
		$network->logger->debug("Captured Twitter URL $captured with tweet ID $tweet_id");
		$self->twitter_tweet_by_id($tweet_id, sub {
			my ($err, $tweet) = @_;
			return $network->logger->error("Error retrieving Twitter tweet data: $err") if $err;
			return $self->_display_triggered($network, $sender, $channel, $tweet);
		});
	});
}

sub twitter_tweet_by_id {
	my ($self, $id, $cb) = @_;
	croak 'Undefined tweet ID' unless defined $id;
	
	my $url = Mojo::URL->new(TWITTER_API_ENDPOINT)->path('statuses/show.json')->query(id => $id);
	my $token = $self->_access_token;
	my %headers = (Authorization => "Bearer $token");
	if ($cb) {
		$self->ua->get($url, \%headers, sub {
			my ($ua, $tx) = @_;
			return $cb->($self->ua_error($tx->error)) if $tx->error;
			return $cb->(undef, $tx->res->json);
		});
	} else {
		my $tx = $self->ua->get($url, \%headers);
		return $self->ua_error($tx->error) if $tx->error;
		return (undef, $tx->res->json);
	}
}

sub twitter_tweet_by_user {
	my ($self, $user, $cb) = @_;
	croak 'Undefined twitter user' unless defined $user;
	
	my $url = Mojo::URL->new(TWITTER_API_ENDPOINT)->path('users/show.json')
		->query(screen_name => $user, include_entities => 'false');
	my $token = $self->_access_token;
	my %headers = (Authorization => "Bearer $token");
	if ($cb) {
		$self->ua->get($url, \%headers, sub {
			my ($ua, $tx) = @_;
			return $cb->($self->ua_error($tx->error)) if $tx->error;
			my $user = $tx->res->json;
			my $tweet = delete $user->{status};
			$tweet->{user} = $user;
			return $cb->(undef, $tweet);
		});
	} else {
		my $tx = $self->ua->get($url, \%headers);
		return $self->ua->error($tx->error) if $tx->error;
		my $user = $tx->res->json;
		my $tweet = delete $user->{status};
		$tweet->{user} = $user;
		return (undef, $tweet);
	}
}

sub twitter_search {
	my ($self, $query, $cb) = @_;
	croak 'Undefined twitter query' unless defined $query;
	
	my $url = Mojo::URL->new(TWITTER_API_ENDPOINT)->path('search/tweets.json')
		->query(q => $query, count => 15, include_entities => 'false');
	my $token = $self->_access_token;
	my %headers = (Authorization => "Bearer $token");
	if ($cb) {
		$self->ua->get($url, \%headers, sub {
			my ($ua, $tx) = @_;
			return $cb->($self->ua_error($tx->error)) if $tx->error;
			return $cb->(undef, $tx->res->json->{statuses}//[]);
		});
	} else {
		my $tx = $self->ua->get($url, \%headers);
		return $self->ua_error($tx->error) if $tx->error;
		return (undef, $tx->res->json->{statuses}//[]);
	}
}

sub _display_tweet {
	my ($self, $network, $sender, $channel, $tweet, $show_more) = @_;
	
	my $username = $tweet->{user}{screen_name};
	my $id = $tweet->{id_str};
	my $url = Mojo::URL->new('https://twitter.com')->path("$username/status/$id");
	
	my $in_reply_to_id = $tweet->{in_reply_to_status_id_str};
	my $in_reply_to_user = $tweet->{in_reply_to_screen_name};
	
	my $b_code = chr 2;
	my $in_reply_to = defined $in_reply_to_id
		? " in reply to $b_code\@$in_reply_to_user$b_code tweet \#$in_reply_to_id" : '';
	
	my $content = $self->_parse_tweet_text($tweet->{text});
	my $created_at = str2time($tweet->{created_at}) // time;
	my $ago = ago(time - $created_at);
	
	my $name = $tweet->{user}{name};
	$name = defined $name ? "$name ($b_code\@$username$b_code)" : "$b_code\@$username$b_code";
	
	my $if_show_more = $show_more ? " [ $show_more more results, use 'more' command to display ]" : '';
	my $msg = "Tweeted by $name $ago$in_reply_to: $content ($url)$if_show_more";
	$network->reply($sender, $channel, $msg);
}

sub _display_triggered {
	my ($self, $network, $sender, $channel, $tweet) = @_;
	
	my $username = $tweet->{user}{screen_name};
	
	my $in_reply_to_id = $tweet->{in_reply_to_status_id_str};
	my $in_reply_to_user = $tweet->{in_reply_to_screen_name};
	
	my $b_code = chr 2;
	my $in_reply_to = defined $in_reply_to_id
		? " in reply to $b_code\@$in_reply_to_user$b_code tweet \#$in_reply_to_id" : '';
	
	my $content = $self->_parse_tweet_text($tweet->{text});
	my $created_at = str2time($tweet->{created_at}) // time;
	my $ago = ago(time - $created_at);
	
	my $name = $tweet->{user}{name};
	$name = defined $name ? "$name ($b_code\@$username$b_code)" : "$b_code\@$username$b_code";
	
	my $msg = "Tweet linked by $sender: Tweeted by $name $ago$in_reply_to: $content";
	$network->write(privmsg => $channel, ":$msg");
}

sub _parse_tweet_text {
	my ($self, $text) = @_;
	
	$text = html_unescape $text;
	$text =~ s/\n/ /g;
	
	my @urls = $text =~ m!(https?://t.co/\w+)!g;
	foreach my $url (@urls) {
		my $tx = $self->ua->head($url);
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

Bot::ZIRC::Plugin::Twitter - Twitter plugin for Bot::ZIRC

=head1 SYNOPSIS

 my $bot = Bot::ZIRC->new(
   plugins => { Twitter => 1 },
 );
 
 # Standalone usage
 my $twitter = Bot::ZIRC::Plugin::Twitter->new(api_key => $api_key, api_secret => $api_secret);
 my ($err, $tweets) = $twitter->twitter_search($query);

=head1 DESCRIPTION

Adds plugin methods and commands for interacting with Twitter to a L<Bot::ZIRC>
IRC bot. Also adds a hook to display information about tweets linked in a
channel.

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

 my ($err, $tweets) = $bot->twitter_search($query);
 $bot->twitter_search($query, sub {
   my ($err, $tweets) = @_;
 });

Search tweets on Twitter. On error, the first return value contains the error
message. On success, the second return value contains the results (if any) in
an arrayref. Pass a callback to perform the query non-blocking.

=head2 twitter_tweet_by_id

 my ($err, $tweet) = $bot->twitter_tweet_by_id($id);
 $bot->twitter_tweet_by_id($id, sub {
   my ($err, $tweet) = @_;
 });

Retrieve a tweet by Tweet ID. On error, the first return value contains the
error message. On success, the second return value contains the tweet data.
Pass a callback to perform the query non-blocking.

=head2 twitter_tweet_by_user

 my ($err, $tweet) = $bot->twitter_tweet_by_user($user);
 $bot->twitter_tweet_by_user($user, sub {
   my ($err, $tweet) = @_;
 });

Retrieve the latest tweet in a user's timeline. On error, the first return
value contains the error message. On success, the second return value contains
the tweet data. Pass a callback to perform the query non-blocking.

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

L<Bot::ZIRC>
