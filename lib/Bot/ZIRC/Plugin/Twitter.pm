package Bot::ZIRC::Plugin::Twitter;

use Date::Parse;
use Mojo::URL;
use Mojo::UserAgent;
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
	die ua_error($tx->error) if $tx->error;
	return $tx->res->json->{access_token};
}

sub register {
	my ($self, $bot) = @_;
	$self->api_key($bot->config->get('apis','twitter_api_key'))
		unless defined $self->api_key;
	$self->api_secret($bot->config->get('apis','twitter_api_secret'))
		unless defined $self->api_secret;
	die TWITTER_API_KEY_MISSING unless defined $self->api_key and defined $self->api_secret;
		
	$bot->add_command(
		name => 'twitter',
		help_text => 'Search tweets on Twitter',
		usage_text => '(<query>|#<tweet id>|@<twitter user>)',
		tokenize => 0,
		on_run => sub {
			my ($network, $sender, $channel, $query) = @_;
			return 'usage' unless length $query;
			
			my $token = $self->_access_token;
			
			# Tweet ID
			if ($query =~ /^#(\d+)$/) {
				my $id = $1;
				my $url = Mojo::URL->new(TWITTER_API_ENDPOINT)
					->path('statuses/show.json')->query(id => $id);
				$network->ua->get($url, { Authorization => "Bearer $token" }, sub {
					my ($ua, $tx) = @_;
					return $network->reply($sender, $channel, ua_error($tx->error)) if $tx->error;
					my $tweet = $tx->res->json;
					return display_tweet($network, $sender, $channel, $tweet);
				});
			}
			
			# User timeline
			elsif ($query =~ /^\@(\S+)$/) {
				my $user = $1;
				my $url = Mojo::URL->new(TWITTER_API_ENDPOINT)
					->path('users/show.json')->query(screen_name => $user, include_entities => 'false');
				$network->ua->get($url, { Authorization => "Bearer $token" }, sub {
					my ($ua, $tx) = @_;
					return $network->reply($sender, $channel, ua_error($tx->error)) if $tx->error;
					my $user = $tx->res->json;
					my $tweet = delete $user->{status};
					$tweet->{user} = $user;
					return display_tweet($network, $sender, $channel, $tweet);
				});
			}
			
			# Search
			else {
				my $url = Mojo::URL->new(TWITTER_API_ENDPOINT)
					->path('search/tweets.json')->query(q => $query, count => 15, include_entities => 'false');
				$network->ua->get($url, { Authorization => "Bearer $token" }, sub {
					my ($ua, $tx) = @_;
					return $network->reply($sender, $channel, ua_error($tx->error)) if $tx->error;
					my $tweets = $tx->res->json->{statuses};
					return $network->reply($sender, $channel, "No results for Twitter search")
						unless $tweets and @$tweets;
					
					my $first_tweet = shift @$tweets;
					my $channel_name = lc ($channel // $sender);
					$self->results_cache->{$network}{$channel_name} = $tweets;
					my $show_more = @$tweets;
					display_tweet($network, $sender, $channel, $first_tweet, $show_more);
				});
			}
		},
		on_more => sub {
			my ($network, $sender, $channel) = @_;
			my $channel_name = lc ($channel // $sender);
			my $tweets = $self->results_cache->{$network}{$channel_name};
			return $network->reply($sender, $channel, "No more results for Twitter search")
				unless $tweets and @$tweets;
			
			my $next_tweet = shift @$tweets;
			my $show_more = @$tweets;
			display_tweet($network, $sender, $channel, $next_tweet, $show_more);
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
		my $url = Mojo::URL->new(TWITTER_API_ENDPOINT)
			->path('statuses/show.json')->query(id => $tweet_id);
		$network->ua->get($url, { Authorization => "Bearer $token" }, sub {
			my ($ua, $tx) = @_;
			return $network->logger->error("Error retrieving Twitter tweet data: ".ua_error($tx->error))
				if $tx->error;
			my $tweet = $tx->res->json;
			return display_triggered($network, $sender, $channel, $tweet);
		});
	});
}

sub display_tweet {
	my ($network, $sender, $channel, $tweet, $show_more) = @_;
	
	my $username = $tweet->{user}{screen_name};
	my $id = $tweet->{id_str};
	my $url = Mojo::URL->new('https://twitter.com')->path("$username/status/$id");
	
	my $in_reply_to_id = $tweet->{in_reply_to_status_id_str};
	my $in_reply_to_user = $tweet->{in_reply_to_screen_name};
	
	my $b_code = chr 2;
	my $in_reply_to = defined $in_reply_to_id
		? " in reply to $b_code\@$in_reply_to_user$b_code tweet \#$in_reply_to_id" : '';
	
	my $content = parse_tweet_text($tweet->{text});
	my $created_at = str2time($tweet->{created_at}) // time;
	my $ago = ago(time - $created_at);
	
	my $name = $tweet->{user}{name};
	$name = defined $name ? "$name ($b_code\@$username$b_code)" : "$b_code\@$username$b_code";
	
	my $if_show_more = $show_more ? " [ $show_more more results, use 'more' command to display ]" : '';
	my $msg = "Tweeted by $name $ago$in_reply_to: $content ($url)$if_show_more";
	$network->reply($sender, $channel, $msg);
}

sub display_triggered {
	my ($network, $sender, $channel, $tweet) = @_;
	
	my $username = $tweet->{user}{screen_name};
	
	my $in_reply_to_id = $tweet->{in_reply_to_status_id_str};
	my $in_reply_to_user = $tweet->{in_reply_to_screen_name};
	
	my $b_code = chr 2;
	my $in_reply_to = defined $in_reply_to_id
		? " in reply to $b_code\@$in_reply_to_user$b_code tweet \#$in_reply_to_id" : '';
	
	my $content = parse_tweet_text($tweet->{text});
	my $created_at = str2time($tweet->{created_at}) // time;
	my $ago = ago(time - $created_at);
	
	my $name = $tweet->{user}{name};
	$name = defined $name ? "$name ($b_code\@$username$b_code)" : "$b_code\@$username$b_code";
	
	my $msg = "Tweet linked by $sender: Tweeted by $name $ago$in_reply_to: $content";
	$network->write(privmsg => $channel, ":$msg");
}

sub parse_tweet_text {
	my $text = shift;
	
	$text = html_unescape $text;
	$text =~ s/\n/ /g;
	
	my @urls = $text =~ m!(https?://t.co/\w+)!g;
	my $ua = Mojo::UserAgent->new;
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
