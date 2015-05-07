package Bot::ZIRC::Network;

use Carp;
use List::Util 'any';
use IRC::Utils 'parse_user';
use Mojo::IOLoop;
use Mojo::IRC;
use Mojo::Util 'dumper';
use Parse::IRC;
use Scalar::Util qw/blessed looks_like_number weaken/;
use Bot::ZIRC;
use Bot::ZIRC::Access qw/:access channel_access_level/;
use Bot::ZIRC::Channel;
use Bot::ZIRC::User;
use Bot::ZIRC::Message;

use Moo;
use namespace::clean;

use overload '""' => sub { shift->name };

our @CARP_NOT = qw(Bot::ZIRC Bot::ZIRC::Command Bot::ZIRC::User Bot::ZIRC::Channel Moo);

our $VERSION = '0.20';

has 'name' => (
	is => 'rwp',
	isa => sub { croak "Unspecified network name" unless defined $_[0] },
	required => 1,
);

has 'bot' => (
	is => 'ro',
	isa => sub { croak "Invalid bot" unless blessed $_[0] and $_[0]->isa('Bot::ZIRC') },
	lazy => 1,
	default => sub { Bot::ZIRC->new },
	weak_ref => 1,
	handles => [qw/bot_version config_dir is_stopping storage ua/],
);

has 'init_config' => (
	is => 'ro',
	isa => sub { croak "Invalid configuration hash $_[0]"
		unless defined $_[0] and ref $_[0] eq 'HASH' },
	lazy => 1,
	default => sub { {} },
	init_arg => 'config',
);

has 'config_file' => (
	is => 'ro',
	lazy => 1,
	default => sub { lc($_[0]->bot->name) . '-' . lc($_[0]->name) . '.conf' },
);

has 'config' => (
	is => 'lazy',
	init_arg => undef,
);

sub _build_config {
	my $self = shift;
	my $config = Bot::ZIRC::Config->new(
		dir => $self->config_dir,
		file => $self->config_file,
		defaults_config => $self->bot->config,
	);
	$config->apply($self->init_config) if %{$self->init_config};
	return $config;
}

has 'logger' => (
	is => 'lazy',
	init_arg => undef,
	clearer => 1,
);

sub _build_logger {
	my $self = shift;
	my $path = $self->config->get('logfile') || undef;
	my $logger = Mojo::Log->new(path => $path);
	$logger->level('info') unless $self->config->get('debug');
	return $logger;
}

has 'channels' => (
	is => 'ro',
	lazy => 1,
	default => sub { {} },
	init_arg => undef,
);

sub channel {
	my $self = shift;
	my $name = shift // croak "No channel name provided";
	return $name if blessed $name and $name->isa('Bot::ZIRC::Channel');
	return $self->channels->{lc $name} //= Bot::ZIRC::Channel->new(name => $name, network => $self);
}

has 'users' => (
	is => 'ro',
	lazy => 1,
	default => sub { {} },
	init_arg => undef,
);

sub user {
	my $self = shift;
	my $nick = shift // croak "No user nick provided";
	return $nick if blessed $nick and $nick->isa('Bot::ZIRC::User');
	return $self->users->{lc $nick} //= Bot::ZIRC::User->new(nick => $nick, network => $self);
}

sub rename_user {
	my ($self, $from, $to) = @_;
	my $user = delete $self->users->{lc $from} // return $self->user($to);
	$user->nick($to);
	$self->users->{lc $to} = $user;
}

has 'irc' => (
	is => 'lazy',
	init_arg => undef,
	handles => [qw/nick server write/],
);

sub _build_irc {
	my $self = shift;
	my $irc = Mojo::IRC->new($self->_connect_options);
	$irc->parser(Parse::IRC->new(ctcp => 1, public => 1));
	return $irc;
}

sub _connect_options {
	my $self = shift;
	my ($server, $port, $server_pass, $ssl, $nick, $realname) = 
		@{$self->config->hash->{irc}}{qw/server port server_pass ssl nick realname/};
	croak "IRC server for network $self is not configured\n"
		unless defined $server and length $server;
	$server .= ":$port" if defined $port and length $port;
	$nick = $self->bot->name unless defined $nick and length $nick;
	croak "Invalid bot nick $nick" unless IRC::Utils::is_valid_nick_name $nick;
	$realname = sprintf 'Bot::ZIRC %s by %s', $self->bot_version, 'Grinnz'
		unless defined $realname and length $realname;
	my %options = (
		server => $server,
		nick => $nick,
		user => $nick,
		name => $realname,
	);
	$options{tls} = {} if $ssl;
	$options{pass} = $server_pass if defined $server_pass and length $server_pass;
	return %options;
}

has 'check_recurring_timer' => (
	is => 'rw',
	lazy => 1,
	predicate => 1,
	clearer => 1,
);

with 'Bot::ZIRC::EventEmitter';

sub BUILD {
	my $self = shift;
	
	$self->bot->on(start => sub { $self->start });
	$self->bot->on(stop => sub { $self->stop($_[1]) });
	$self->bot->on(reload => sub { $self->reload });
}

sub start {
	my $self = shift;
	my $irc = $self->irc;
	
	$self->register_event_handlers;
	$irc->register_default_event_handlers;
	
	weaken $self;
	$irc->on(close => sub { $self->on_disconnect });
	$irc->on(error => sub { $self->logger->error($_[1]); $self->disconnect; });
	
	my $server = $self->server;
	$self->logger->debug("Connecting to $server");
	$self->connect;
	return $self;
}

sub stop {
	my ($self, $message) = @_;
	my $server = $self->server;
	$self->logger->debug("Disconnecting from $server");
	$self->disconnect($message);
	return $self;
}

sub reload {
	my $self = shift;
	$self->logger->debug("Reloading network $self");
	$self->config->reload;
	$self->clear_logger;
	return $self;
}

my @irc_events = qw/irc_invite irc_join irc_kick irc_mode irc_nick
	irc_notice irc_part irc_privmsg irc_public irc_quit irc_rpl_welcome
	irc_rpl_motdstart irc_rpl_endofmotd err_nomotd irc_rpl_notopic
	irc_rpl_topic irc_rpl_topicwhotime irc_rpl_namreply irc_rpl_whoreply
	irc_rpl_endofwho irc_rpl_whoisuser irc_rpl_whoischannels irc_rpl_away
	irc_rpl_whoisoperator irc_rpl_whoisaccount irc_rpl_whoisidle irc_335
	irc_rpl_endofwhois/;

sub register_event_handlers {
	my $self = shift;
	$self->register_event_handler($_) for @irc_events;
}

sub register_event_handler {
	my ($self, $event) = @_;
	my $handler = $self->can($event) // die "No handler found for IRC event $event\n";
	weaken $self;
	$self->irc->on($event => sub { shift; $self->$handler(@_) });
}

# IRC methods

sub connect {
	my $self = shift;
	my $server = $self->server;
	$self->logger->debug("Connected to $server");
	weaken $self;
	$self->irc->connect(sub { shift; $self->on_connect(@_) });
}

sub on_connect {
	my ($self, $err) = @_;
	if ($err) {
		$self->logger->error($err);
		return if $self->is_stopping or !$self->config->get('irc','reconnect');
		my $delay = $self->config->get('irc','reconnect_delay');
		$delay = 10 unless defined $delay and looks_like_number $delay;
		Mojo::IOLoop->timer($delay => sub { $self->reconnect });
	} else {
		$self->identify;
		$self->check_recurring;
	}
}

sub on_welcome {
	my $self = shift;
	$self->set_bot_mode;
	$self->autojoin;
	$self->write(whois => $self->nick);
}

sub disconnect {
	my $self = shift;
	my $cb = ref $_[-1] eq 'CODE' ? pop : undef;
	my $message = shift;
	if (defined $message) {
		$self->write(quit => ":$message", sub { shift->disconnect($cb) });
	} else {
		$self->irc->disconnect($cb);
	}
}

sub on_disconnect {
	my $self = shift;
	my $server = $self->server;
	$self->logger->debug("Disconnected from $server");
	Mojo::IOLoop->remove($self->check_recurring_timer) if $self->has_check_recurring_timer;
	$self->clear_check_recurring_timer;
	$self->reconnect if !$self->is_stopping and $self->config->get('irc','reconnect');
}

sub reconnect {
	my $self = shift;
	my $server = $self->server;
	$self->logger->debug("Reconnecting to $server");
	$self->connect;
}

sub identify {
	my $self = shift;
	my $nick = $self->config->get('irc','nick') // $self->bot->name;
	my $pass = $self->config->get('irc','password');
	if (defined $pass and length $pass) {
		$self->do_identify($nick, $pass);
	}
}

sub do_identify {
	my ($self, $nick, $pass) = @_;
	$self->logger->debug("Identifying with NickServ as $nick");
	$self->write("NICKSERV identify $nick $pass");
}

sub check_recurring {
	my $self = shift;
	Mojo::IOLoop->remove($self->check_recurring_timer) if $self->has_check_recurring_timer;
	weaken $self;
	my $timer_id = Mojo::IOLoop->recurring(60 => sub { $self->check_nick; $self->check_channels });
	$self->check_recurring_timer($timer_id);
}

sub check_nick {
	my $self = shift;
	my $desired = $self->config->get('irc','nick') // $self->bot->name;
	my $current = $self->nick;
	unless (lc $desired eq lc substr $current, 0, length $desired) {
		$self->write(nick => $desired);
		$current = $desired;
	}
	$self->after_whois($current, sub {
		my ($self, $user) = @_;
		$self->identify unless $user->is_registered;
	});
}

sub check_channels {
	my $self = shift;
	my @autojoin = split /[\s,]+/, $self->config->get('channels','autojoin') // '';
	my $current = $self->user($self->nick)->channels;
	my @to_join = grep { !exists $current->{lc $_} } @autojoin;
	$self->join_channels(@to_join);
}

sub set_bot_mode {
	my $self = shift;
	$self->write(mode => $self->nick => '+B');
}

sub autojoin {
	my $self = shift;
	my @channels = split /[\s,]+/, $self->config->get('channels','autojoin') // '';
	$self->join_channels(@channels);
}

sub join_channels {
	my ($self, @channels) = @_;
	return unless @channels;
	my $channels_str = join ', ', @channels;
	$self->logger->debug("Joining channels: $channels_str");
	while (my @chunk = splice @channels, 0, 10) {
		$self->write(join => join(',', @chunk));
	}
}

# Command parsing

sub check_privmsg {
	my ($self, $message) = @_;
	my $sender = $message->sender;
	my $channel = $message->channel;
	
	if (defined $message->parse_command) {
		return unless my $command = $message->command;
		
		my $args_str = $message->args;
		$self->logger->debug("<$sender> [command] $command $args_str");
			
		$sender->check_access($command->required_access, $channel, sub {
			my ($sender, $has_access) = @_;
			if ($has_access) {
				$sender->logger->debug("$sender has access to run command $command");
				$command->run($message);
			} else {
				$sender->logger->debug("$sender does not have access to run command $command");
				my $channel_str = defined $channel ? " in $channel" : '';
				$message->reply_private("You do not have access to run $command$channel_str");
			}
		});
	} else {
		$self->bot->emit_hook(privmsg => $message);
	}
}

# Queue future events

sub after_who {
	my ($self, $nick, $cb) = @_;
	$self->once('who_'.lc($nick) => $cb);
	$self->write(who => $nick);
	return $self;
}

sub run_after_who {
	my ($self, $nick) = @_;
	my $user = $self->user($nick);
	$self->emit_hook('who_'.lc($nick) => $user);
	return $self;
}

sub after_whois {
	my ($self, $nick, $cb) = @_;
	$self->once('whois_'.lc($nick) => $cb);
	$self->write(whois => $nick);
	return $self;
}

sub run_after_whois {
	my ($self, $nick) = @_;
	my $user = $self->user($nick);
	$self->emit_hook('whois_'.lc($nick) => $user);
	return $self;
}

# IRC event callbacks

sub irc_invite {
	my ($self, $message) = @_;
	my ($to, $channel) = @{$message->{params}};
	my $from = parse_user($message->{prefix});
	$self->logger->debug("User $from has invited $to to $channel");
}

sub irc_join {
	my ($self, $message) = @_;
	my ($channel) = @{$message->{params}};
	my $from = parse_user($message->{prefix});
	$self->logger->debug("User $from joined $channel");
	$self->channel($channel)->add_user($from);
	$self->user($from)->add_channel($channel);
	if (lc $from eq lc $self->nick) {
		#$self->write('who', '+c', $channel);
	} else {
		$self->write(whois => $from);
	}
}

sub irc_kick {
	my ($self, $message) = @_;
	my ($channel, $to) = @{$message->{params}};
	my $from = parse_user($message->{prefix});
	$self->logger->debug("User $from has kicked $to from $channel");
	$self->channel($channel)->remove_user($to);
	$self->user($to)->remove_channel($channel);
	if (lc $to eq lc $self->nick and any { lc $_ eq lc $channel }
			split /[\s,]+/, $self->config->get('channels','autojoin')) {
		$self->write(join => $channel);
	}
}

sub irc_mode {
	my ($self, $message) = @_;
	my ($to, $mode, @params) = @{$message->{params}};
	my $from = parse_user($message->{prefix});
	my $params_str = join ' ', @params;
	if ($to =~ /^#/) {
		my $channel = $to;
		$self->logger->debug("User $from changed mode of $channel to $mode $params_str");
		if (@params and $mode =~ /[qaohvbe]/) {
			if ($mode =~ /[qaohv]/) {
				my $bot_nick = $self->nick;
				$self->write('who', '+cn', $channel, $_)
					for grep { lc $_ ne lc $bot_nick } @params;
			}
		}
	} else {
		my $user = $to;
		$self->logger->debug("User $from changed mode of $user to $mode $params_str");
	}
}

sub irc_nick {
	my ($self, $message) = @_;
	my ($to) = @{$message->{params}};
	my $from = parse_user($message->{prefix});
	$self->logger->debug("User $from changed nick to $to");
	$_->rename_user($from => $to) foreach values %{$self->channels};
	$self->rename_user($from => $to);
	$self->nick($to) if lc $self->nick eq lc $from;
}

sub irc_notice {
	my ($self, $message) = @_;
	my ($to, $text) = @{$message->{params}};
	my $from = parse_user($message->{prefix}) // '';
	$self->logger->info("[notice $to] <$from> $text") if $self->config->get('echo');
	my $sender = $self->user($from);
	my $channel = $to =~ /^#/ ? $self->channel($to) : undef;
	my $m = Bot::ZIRC::Message->new(network => $self, sender => $sender, channel => $channel, text => $text);
	$self->bot->emit_hook(notice => $m);
}

sub irc_part {
	my ($self, $message) = @_;
	my ($channel) = @{$message->{params}};
	my $from = parse_user($message->{prefix});
	$self->logger->debug("User $from parted $channel");
	if (lc $from eq lc $self->nick) {
	}
	$self->channel($channel)->remove_user($from);
	$self->user($from)->remove_channel($channel);
}

sub irc_privmsg {
	my ($self, $message) = @_;
	my ($to, $msg) = @{$message->{params}};
	my $from = parse_user($message->{prefix});
	$self->logger->info("[private] <$from> $msg") if $self->config->get('echo');
	my $user = $self->user($from);
	my $obj = Bot::ZIRC::Message->new(network => $self, sender => $user, text => $msg);
	$self->check_privmsg($obj) unless $user->is_bot and $self->config->get('users','ignore_bots');
}

sub irc_public {
	my ($self, $message) = @_;
	my ($channel, $msg) = @{$message->{params}};
	my $from = parse_user($message->{prefix});
	$self->logger->info("[$channel] <$from> $msg") if $self->config->get('echo');
	my $user = $self->user($from);
	$channel = $self->channel($channel);
	my $obj = Bot::ZIRC::Message->new(network => $self, sender => $user, channel => $channel, text => $msg);
	$self->check_privmsg($obj) unless $user->is_bot and $self->config->get('users','ignore_bots');
}

sub irc_quit {
	my ($self, $message) = @_;
	my $from = parse_user($message->{prefix});
	$self->logger->debug("User $from has quit");
	$_->remove_user($from) foreach values %{$self->channels};
	$self->user($from)->clear_channels;
}

sub irc_rpl_welcome {
	my ($self, $message) = @_;
	$self->irc->irc_rpl_welcome($message);
	$self->on_welcome;
}

sub irc_rpl_motdstart { # RPL_MOTDSTART
	my ($self, $message) = @_;
}

sub irc_rpl_endofmotd { # RPL_ENDOFMOTD
	my ($self, $message) = @_;
}

sub err_nomotd { # ERR_NOMOTD
	my ($self, $message) = @_;
}

sub irc_rpl_notopic { # RPL_NOTOPIC
	my ($self, $message) = @_;
	my ($channel) = @{$message->{params}};
	$self->logger->debug("No topic set for $channel");
	$self->channel($channel)->topic(undef);
}

sub irc_rpl_topic { # RPL_TOPIC
	my ($self, $message) = @_;
	my ($to, $channel, $topic) = @{$message->{params}};
	$self->logger->debug("Topic for $channel: $topic");
	$self->channel($channel)->topic($topic);
}

sub irc_rpl_topicwhotime { # RPL_TOPICWHOTIME
	my ($self, $message) = @_;
	my ($to, $channel, $who, $time) = @{$message->{params}};
	my $time_str = localtime($time);
	$self->logger->debug("Topic for $channel was changed at $time_str by $who");
	$self->channel($channel)->topic_info([$time, $who]);
}

sub irc_rpl_namreply { # RPL_NAMREPLY
	my ($self, $message) = @_;
	my ($to, $sym, $channel, $nicks) = @{$message->{params}};
	$self->logger->debug("Received names for $channel: $nicks");
	my @nicks = split /\s+/, $nicks;
	foreach my $nick (@nicks) {
		my $access = ACCESS_NONE;
		if ($nick =~ s/^([-~&@%+])//) {
			$access = channel_access_level($1);
		}
		my $user = $self->user($nick);
		$user->add_channel($channel);
		$user->channel_access($channel => $access);
		$self->channel($channel)->add_user($nick);
	}
	$self->write(whois => join ',', @nicks) if @nicks;
}

sub irc_rpl_whoreply { # RPL_WHOREPLY
	my ($self, $message) = @_;
	my ($to, $channel, $username, $host, $server, $nick, $state, $realname) = @{$message->{params}};
	$realname =~ s/^\d+\s+//;
	
	my ($away, $reg, $bot, $ircop, $access);
	if ($state =~ /([HG])(r?)(B?)(\*?)([-~&@%+]?)/) {
		$away = ($1 eq 'G') ? 1 : 0;
		$reg = $2 ? 1 : 0;
		$bot = $3 ? 1 : 0;
		$ircop = $4 ? 1 : 0;
		$access = $5 ? channel_access_level($5) : ACCESS_NONE;
	}
	
	$self->logger->debug("Received who reply for $nick in $channel");
	my $user = $self->user($nick);
	$user->host($host);
	$user->username($username);
	$user->realname($realname);
	$user->is_away($away);
	$user->is_registered($reg);
	$user->is_bot($bot);
	$user->is_ircop($ircop);
	$user->channel_access($channel => $access);
	
	$self->run_after_who($nick);
}

sub irc_rpl_endofwho { # RPL_ENDOFWHO
	my ($self, $message) = @_;
}

sub irc_rpl_whoisuser { # RPL_WHOISUSER
	my ($self, $message) = @_;
	my ($to, $nick, $username, $host, $star, $realname) = @{$message->{params}};
	$self->logger->debug("Received user info for $nick!$username\@$host: $realname");
	my $user = $self->user($nick);
	$user->host($host);
	$user->username($username);
	$user->realname($realname);
	$user->clear_is_registered;
	$user->clear_identity;
	$user->clear_is_away;
	$user->clear_away_message;
	$user->clear_is_ircop;
	$user->clear_ircop_message;
	$user->clear_is_bot;
	$user->clear_idle_time;
	$user->clear_signon_time;
	$user->clear_channels;
}

sub irc_rpl_whoischannels { # RPL_WHOISCHANNELS
	my ($self, $message) = @_;
	my ($to, $nick, $channels) = @{$message->{params}};
	$self->logger->debug("Received channels for $nick: $channels");
	my $user = $self->user($nick);
	foreach my $channel (split /\s+/, $channels) {
		my $access = ACCESS_NONE;
		if ($channel =~ s/^([-~&@%+])//) {
			$access = channel_access_level($1);
		}
		$user->add_channel($channel);
		$user->channel_access($channel => $access);
		$self->channel($channel)->add_user($nick);
	}
}

sub irc_rpl_away { # RPL_AWAY
	my ($self, $message) = @_;
	my $msg = pop @{$message->{params}};
	my ($to, $nick) = @{$message->{params}};
	$self->logger->debug("Received away message for $nick: $msg");
	my $user = $self->user($nick);
	$user->is_away(1);
	$user->away_message($msg);
}

sub irc_rpl_whoisoperator { # RPL_WHOISOPERATOR
	my ($self, $message) = @_;
	my ($to, $nick, $msg) = @{$message->{params}};
	$self->logger->debug("Received IRC Operator privileges for $nick: $msg");
	my $user = $self->user($nick);
	$user->is_ircop(1);
	$user->ircop_message($msg);
}

sub irc_rpl_whoisaccount { # RPL_WHOISACCOUNT
	my ($self, $message) = @_;
	my ($to, $nick, $identity) = @{$message->{params}};
	$self->logger->debug("Received identity for $nick: $identity");
	$self->user($nick)->identity($identity);
}

sub irc_335 { # whois bot string
	my ($self, $message) = @_;
	my ($to, $nick) = @{$message->{params}};
	$self->logger->debug("Received bot status for $nick");
	my $user = $self->user($nick);
	$user->is_bot(1);
}

sub irc_rpl_whoisidle { # RPL_WHOISIDLE
	my ($self, $message) = @_;
	my ($to, $nick, $seconds, $signon) = @{$message->{params}};
	$self->logger->debug("Received idle status for $nick: $seconds, $signon");
	my $user = $self->user($nick);
	$user->idle_time($seconds);
	$user->signon_time($signon);
}

sub irc_rpl_endofwhois { # RPL_ENDOFWHOIS
	my ($self, $message) = @_;
	my ($to, $nicks) = @{$message->{params}};
	$self->logger->debug("End of whois reply for $nicks");
	my @nicks = split ',', $nicks;
	foreach my $nick (@nicks) {
		my $user = $self->user($nick);
		$user->identity(undef) unless $user->is_registered;
		$self->run_after_whois($nick);
	}
}

1;

=head1 NAME

Bot::ZIRC::Network - IRC network class for Bot::ZIRC

=head1 SYNOPSIS

  my $network = Bot::ZIRC::Network->new(name => 'SomeNetwork', bot => $bot,
    config => { irc => { server => 'irc.somenetwork.org', port => 6667 } });

=head1 DESCRIPTION

Represents an IRC network for a L<Bot::ZIRC> IRC bot. When constructed,
the network object registers hooks for the L<Bot::ZIRC> C<start>, C<stop>, and
C<reload> hooks, to call its own methods of the same name.

=head1 ATTRIBUTES

=head2 name

Identifying name for network, required and must be unique among the networks
added to a L<Bot::ZIRC> object. Used for the default L</"config_file"> name.

=head2 bot

Weakened reference to main L<Bot::ZIRC> object.

=head2 config_file

Configuration filename for network, defaults to lowercased L<Bot::ZIRC/"name">
appended with C<-> and lowercased network L</"name">, then appended with
C<.conf>.

=head2 config

L<Bot::ZIRC::Config> configuration object for network.

=head2 logger

Logging object, defaults to L<Mojo::Log> object logging to configuration option
C<logfile> or STDERR.

=head2 users

Hash reference of L<Bot::ZIRC::User> objects representing known network users.

=head2 channels

Hash reference of L<Bot::ZIRC::Channel> objects representing known network
channels.

=head2 irc

L<Mojo::IRC> object used to connect to IRC network. Handles methods C<nick>,
C<server>, and C<write>.

=head1 METHODS

=head2 start

Connects to IRC network and sets up event subscriptions to L</"irc"> object.

=head2 stop

Disconnects from IRC network.

=head2 reload

Reloads L</"config"> and reopens L</"logger">.

=head2 after_who

Sends a C<WHO> query and runs the callback when a response is received.

=head2 after_whois

Sends a C<WHOIS> query and runs the callback when a response is received.

=head1 BUGS

Report any issues on the public bugtracker.

=head1 AUTHOR

Dan Book, C<dbook@cpan.org>

=head1 COPYRIGHT AND LICENSE

Copyright 2015, Dan Book.

This library is free software; you may redistribute it and/or modify it under
the terms of the Artistic License version 2.0.

=head1 SEE ALSO

L<Bot::ZIRC>, L<Bot::ZIRC::User>, L<Bot::ZIRC::Channel>, L<Bot::ZIRC::Config>
