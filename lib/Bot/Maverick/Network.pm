package Bot::Maverick::Network;

use Carp;
use List::Util 'any';
use IRC::Utils 'parse_user';
use Mojo::IRC;
use Mojo::Util 'dumper';
use Parse::IRC;
use Scalar::Util qw/blessed looks_like_number weaken/;
use Bot::Maverick;
use Bot::Maverick::Access qw/:access channel_access_level/;
use Bot::Maverick::Channel;
use Bot::Maverick::User;
use Bot::Maverick::Message;

use Moo;
use namespace::clean;

use overload 'cmp' => sub { $_[2] ? lc $_[1] cmp lc $_[0] : lc $_[0] cmp lc $_[1] },
	'""' => sub { shift->name }, bool => sub {1}, fallback => 1;

with 'Role::EventEmitter';

our @CARP_NOT = qw(Bot::Maverick Bot::Maverick::Command Bot::Maverick::User Bot::Maverick::Channel Moo);

our $VERSION = '0.50';

has 'name' => (
	is => 'rwp',
	isa => sub { croak "Unspecified network name" unless defined $_[0] },
	required => 1,
);

has 'bot' => (
	is => 'ro',
	isa => sub { croak "Invalid bot" unless blessed $_[0] and $_[0]->isa('Bot::Maverick') },
	lazy => 1,
	default => sub { Bot::Maverick->new },
	weak_ref => 1,
	handles => [qw/bot_version config_dir is_stopping storage ua loop/],
);

has '_init_config' => (
	is => 'ro',
	isa => sub { croak "Invalid configuration hash $_[0]"
		unless defined $_[0] and ref $_[0] eq 'HASH' },
	predicate => 1,
	clearer => 1,
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
	my $config = Bot::Maverick::Config->new(
		dir => $self->config_dir,
		file => $self->config_file,
		defaults => $self->bot->config,
	);
	if ($self->_has_init_config) {
		$config->apply($self->_init_config);
		$self->_clear_init_config;
	}
	return $config;
}

has 'logger' => (
	is => 'lazy',
	init_arg => undef,
	clearer => 1,
);

sub _build_logger {
	my $self = shift;
	my $path = $self->config->param('main', 'logfile') || undef;
	my $logger = Mojo::Log->new(path => $path);
	$logger->level('info') unless $self->config->param('main', 'debug');
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
	return $name if blessed $name and $name->isa('Bot::Maverick::Channel');
	return $self->channels->{lc $name} //= Bot::Maverick::Channel->new(name => $name, network => $self);
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
	return $nick if blessed $nick and $nick->isa('Bot::Maverick::User');
	return $self->users->{lc $nick} //= Bot::Maverick::User->new(nick => $nick, network => $self);
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
	my ($server, $port, $server_pass, $ssl, $insecure, $nick, $realname) = 
		@{$self->config->to_hash->{irc}//{}}{qw/server port server_pass ssl insecure nick realname/};
	croak "IRC server for network $self is not configured\n"
		unless defined $server and length $server;
	$server .= ":$port" if defined $port and length $port;
	$nick = $self->bot->name unless defined $nick and length $nick;
	croak "Invalid bot nick $nick" unless IRC::Utils::is_valid_nick_name $nick;
	$realname = sprintf 'Bot::Maverick %s by %s', $self->bot_version, 'Grinnz'
		unless defined $realname and length $realname;
	my %options = (
		server => $server,
		nick => $nick,
		user => $nick,
		name => $realname,
	);
	$options{tls} = {insecure => $insecure} if $ssl;
	$options{pass} = $server_pass if defined $server_pass and length $server_pass;
	return %options;
}

has '_recurring_check_timer' => (
	is => 'rw',
	lazy => 1,
	predicate => 1,
	clearer => 1,
);

sub BUILD {
	my $self = shift;
	
	$self->bot->on(start => sub { $self->start });
	$self->bot->on(stop => sub { $self->stop($_[1]) });
	$self->bot->on(reload => sub { $self->reload });
	
	$self->on(connect => sub {
		my $self = shift;
		$self->_identify;
		$self->_start_recurring_check;
	});
	$self->on(welcome => sub {
		my $self = shift;
		$self->set_bot_mode;
		$self->join_channels($self->autojoin_channels);
		$self->write(whois => $self->nick);
	});
	$self->on(disconnect => sub {
		my $self = shift;
		my $server = $self->server;
		$self->logger->debug("Disconnected from $server");
		$self->_stop_recurring_check;
		$self->connect if !$self->is_stopping and $self->config->param('irc','reconnect');
	});
}

sub start {
	my $self = shift;
	my $irc = $self->irc;
	
	$self->register_event_handlers;
	$irc->register_default_event_handlers;
	
	weaken $self;
	$irc->on(close => sub { $self->emit('disconnect') });
	$irc->on(error => sub { $self->logger->error($_[1]); $self->irc->disconnect; });
	
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
	irc_rpl_endofwhois err_nosuchnick err_yourebannedcreep/;

sub register_event_handlers {
	my $self = shift;
	$self->register_event_handler($_) for @irc_events;
	return $self;
}

sub register_event_handler {
	my ($self, $event) = @_;
	my $handler = $self->can("_$event") // die "No handler found for IRC event $event\n";
	weaken $self;
	$self->irc->on($event => sub { shift; $self->$handler(@_) });
	return $self;
}

# IRC methods

sub connect {
	my $self = shift;
	my $server = $self->server;
	$self->logger->debug("Connecting to $server");
	weaken $self;
	$self->irc->connect(sub {
		my ($irc, $err) = @_;
		if ($err) {
			$self->logger->error($err);
			return if $self->is_stopping or !$self->config->param('irc','reconnect');
			my $delay = $self->config->param('irc','reconnect_delay');
			$delay = 10 unless defined $delay and looks_like_number $delay;
			$self->loop->timer($delay => sub { $self->connect });
		} else {
			$self->emit('connect');
		}
	});
	return $self;
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
	return $self;
}

sub _identify {
	my $self = shift;
	my $nick = $self->config->param('irc','nick') // $self->bot->name;
	my $pass = $self->config->param('irc','password');
	if (defined $pass and length $pass) {
		$self->identify($nick, $pass);
	}
	return $self;
}

sub identify {
	my ($self, $nick, $pass) = @_;
	$self->logger->debug("Identifying with NickServ as $nick");
	$self->write("NICKSERV identify $nick $pass");
	return $self;
}

sub set_bot_mode {
	my $self = shift;
	$self->write(mode => $self->nick => '+B');
	return $self;
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

# Recurring checks

sub _start_recurring_check {
	my $self = shift;
	$self->loop->remove($self->_recurring_check_timer) if $self->_has_recurring_check_timer;
	weaken $self;
	my $timer_id = $self->loop->recurring(60 => sub { $self->check_nick; $self->check_channels });
	$self->_recurring_check_timer($timer_id);
	return $self;
}

sub _stop_recurring_check {
	my $self = shift;
	$self->loop->remove($self->_recurring_check_timer) if $self->_has_recurring_check_timer;
	$self->_clear_recurring_check_timer;
	return $self;
}

sub check_nick {
	my $self = shift;
	my $desired = $self->config->param('irc','nick') // $self->bot->name;
	my $current = $self->nick;
	unless (lc $desired eq lc substr $current, 0, length $desired) {
		$self->write(nick => $desired);
		$current = $desired;
	}
	$self->after_whois($current, sub {
		my ($self, $user) = @_;
		$self->_identify unless $user->is_registered;
	});
	return $self;
}

sub check_channels {
	my $self = shift;
	my $current = $self->user($self->nick)->channels;
	my @to_join = grep { !exists $current->{lc $_} } $self->autojoin_channels;
	$self->join_channels(@to_join);
	return $self;
}

# Config parsing

sub autojoin_channels {
	my $self = shift;
	return @{$self->config->multi_param('channels','autojoin')};
}

sub master_user {
	my $self = shift;
	return $self->config->param('users','master') // '';
}

sub admin_users {
	my $self = shift;
	return @{$self->config->multi_param('users','admin')};
}

sub voice_users {
	my $self = shift;
	return @{$self->config->multi_param('users','voice')};
}

sub ignore_users {
	my $self = shift;
	return @{$self->config->multi_param('users','ignore')};
}

# Queue future events

sub after_who {
	my ($self, $nick, $cb) = @_;
	$self->once('who_'.lc($nick) => $cb);
	$self->write(who => $nick);
	return $self;
}

sub after_whois {
	my ($self, $nick, $cb) = @_;
	$self->once('whois_'.lc($nick) => $cb);
	$self->write(whois => $nick);
	return $self;
}

# IRC event callbacks

sub _irc_invite {
	my ($self, $message) = @_;
	my ($to, $channel) = @{$message->{params}};
	my $from = parse_user($message->{prefix});
	$self->logger->debug("User $from has invited $to to $channel");
}

sub _irc_join {
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

sub _irc_kick {
	my ($self, $message) = @_;
	my ($channel, $to) = @{$message->{params}};
	my $from = parse_user($message->{prefix});
	$self->logger->debug("User $from has kicked $to from $channel");
	$self->channel($channel)->remove_user($to);
	$self->user($to)->remove_channel($channel);
	if (lc $to eq lc $self->nick
		and any { lc $_ eq lc $channel } $self->autojoin_channels) {
		$self->write(join => $channel);
	}
}

sub _irc_mode {
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

sub _irc_nick {
	my ($self, $message) = @_;
	my ($to) = @{$message->{params}};
	my $from = parse_user($message->{prefix});
	$self->logger->debug("User $from changed nick to $to");
	$_->rename_user($from => $to) foreach values %{$self->channels};
	$self->rename_user($from => $to);
	$self->nick($to) if lc $self->nick eq lc $from;
}

sub _irc_notice {
	my ($self, $message) = @_;
	my ($to, $text) = @{$message->{params}};
	my $from = parse_user($message->{prefix}) // '';
	$self->logger->info("[$self] [notice $to] <$from> $text") if $self->config->param('main', 'echo');
	my $sender = $self->user($from);
	my $channel = $to =~ /^#/ ? $self->channel($to) : undef;
	my $m = Bot::Maverick::Message->new(network => $self, sender => $sender, channel => $channel, text => $text);
	$self->bot->emit(notice => $m);
}

sub _irc_part {
	my ($self, $message) = @_;
	my ($channel) = @{$message->{params}};
	my $from = parse_user($message->{prefix});
	$self->logger->debug("User $from parted $channel");
	if (lc $from eq lc $self->nick) {
	}
	$self->channel($channel)->remove_user($from);
	$self->user($from)->remove_channel($channel);
}

sub _irc_privmsg {
	my ($self, $message) = @_;
	my ($to, $msg) = @{$message->{params}};
	my $from = parse_user($message->{prefix});
	$self->logger->info("[$self] [private] <$from> $msg") if $self->config->param('main', 'echo');
	my $user = $self->user($from);
	my $m = Bot::Maverick::Message->new(network => $self, sender => $user, text => $msg);
	$self->_check_privmsg($m);
}

sub _irc_public {
	my ($self, $message) = @_;
	my ($channel, $msg) = @{$message->{params}};
	my $from = parse_user($message->{prefix});
	$self->logger->info("[$self] [$channel] <$from> $msg") if $self->config->param('main', 'echo');
	my $user = $self->user($from);
	$channel = $self->channel($channel);
	my $m = Bot::Maverick::Message->new(network => $self, sender => $user, channel => $channel, text => $msg);
	$self->_check_privmsg($m);
}

sub _check_privmsg {
	my ($self, $message) = @_;
	my $sender = $message->sender;
	my $channel = $message->channel;
	
	return if $sender->is_bot and $self->config->param('users','ignore_bots');
	return if any { lc $_ eq lc $sender } $self->ignore_users;
	
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
		foreach my $handler (@{$self->bot->handlers}) {
			return if $self->bot->$handler($message);
		}
		$self->bot->emit(privmsg => $message);
	}
}

sub _irc_quit {
	my ($self, $message) = @_;
	my $from = parse_user($message->{prefix});
	$self->logger->debug("User $from has quit");
	$_->remove_user($from) foreach values %{$self->channels};
	$self->user($from)->clear_channels;
}

sub _irc_rpl_welcome {
	my ($self, $message) = @_;
	$self->irc->irc_rpl_welcome($message);
	$self->emit('welcome');
}

sub _irc_rpl_motdstart { # RPL_MOTDSTART
	my ($self, $message) = @_;
}

sub _irc_rpl_endofmotd { # RPL_ENDOFMOTD
	my ($self, $message) = @_;
}

sub _err_nomotd { # ERR_NOMOTD
	my ($self, $message) = @_;
}

sub _irc_rpl_notopic { # RPL_NOTOPIC
	my ($self, $message) = @_;
	my ($channel) = @{$message->{params}};
	$self->logger->debug("No topic set for $channel");
	$self->channel($channel)->topic(undef);
}

sub _irc_rpl_topic { # RPL_TOPIC
	my ($self, $message) = @_;
	my ($to, $channel, $topic) = @{$message->{params}};
	$self->logger->debug("Topic for $channel: $topic");
	$self->channel($channel)->topic($topic);
}

sub _irc_rpl_topicwhotime { # RPL_TOPICWHOTIME
	my ($self, $message) = @_;
	my ($to, $channel, $who, $time) = @{$message->{params}};
	my $time_str = localtime($time);
	$self->logger->debug("Topic for $channel was changed at $time_str by $who");
	$self->channel($channel)->topic_info([$time, $who]);
}

sub _irc_rpl_namreply { # RPL_NAMREPLY
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

sub _irc_rpl_whoreply { # RPL_WHOREPLY
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
	$user->is_bot(1) if $bot;
	$user->is_ircop($ircop);
	$user->channel_access($channel => $access);
}

sub _irc_rpl_endofwho { # RPL_ENDOFWHO
	my ($self, $message) = @_;
	my ($to, $nick) = @{$message->{params}};
	my $user = $self->user($nick);
	$user->is_bot(0) unless $user->is_bot;
	$self->emit('who_'.lc($nick) => $user);
}

sub _irc_rpl_whoisuser { # RPL_WHOISUSER
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

sub _irc_rpl_whoischannels { # RPL_WHOISCHANNELS
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

sub _irc_rpl_away { # RPL_AWAY
	my ($self, $message) = @_;
	my $msg = pop @{$message->{params}};
	my ($to, $nick) = @{$message->{params}};
	$self->logger->debug("Received away message for $nick: $msg");
	my $user = $self->user($nick);
	$user->is_away(1);
	$user->away_message($msg);
}

sub _irc_rpl_whoisoperator { # RPL_WHOISOPERATOR
	my ($self, $message) = @_;
	my ($to, $nick, $msg) = @{$message->{params}};
	$self->logger->debug("Received IRC Operator privileges for $nick: $msg");
	my $user = $self->user($nick);
	$user->is_ircop(1);
	$user->ircop_message($msg);
}

sub _irc_rpl_whoisaccount { # RPL_WHOISACCOUNT
	my ($self, $message) = @_;
	my ($to, $nick, $identity) = @{$message->{params}};
	$self->logger->debug("Received identity for $nick: $identity");
	$self->user($nick)->identity($identity);
}

sub _irc_335 { # whois bot string
	my ($self, $message) = @_;
	my ($to, $nick) = @{$message->{params}};
	$self->logger->debug("Received bot status for $nick");
	my $user = $self->user($nick);
	$user->is_bot(1);
}

sub _irc_rpl_whoisidle { # RPL_WHOISIDLE
	my ($self, $message) = @_;
	my ($to, $nick, $seconds, $signon) = @{$message->{params}};
	$self->logger->debug("Received idle status for $nick: $seconds, $signon");
	my $user = $self->user($nick);
	$user->idle_time($seconds);
	$user->signon_time($signon);
}

sub _irc_rpl_endofwhois { # RPL_ENDOFWHOIS
	my ($self, $message) = @_;
	my ($to, $nicks) = @{$message->{params}};
	$self->logger->debug("End of whois reply for $nicks");
	my @nicks = split ',', $nicks;
	foreach my $nick (@nicks) {
		my $user = $self->user($nick);
		$user->identity(undef) unless $user->is_registered;
		$user->is_bot(0) unless $user->is_bot;
		$self->emit('whois_'.lc($nick) => $user);
	}
}

sub _err_nosuchnick { # ERR_NOSUCHNICK
	my ($self, $message) = @_;
	my ($to, $nick) = @{$message->{params}};
	$self->logger->debug("No such nick: $nick");
	$self->unsubscribe('whois_'.lc($nick));
}

sub _err_yourebannedcreep { # ERR_YOUREBANNEDCREEP
	my ($self, $message) = @_;
	my ($to, $reason) = @{$message->{params}};
	$self->logger->error("You are banned from this server: $reason");
}

1;

=head1 NAME

Bot::Maverick::Network - IRC network class for Maverick

=head1 SYNOPSIS

  my $network = Bot::Maverick::Network->new(name => 'SomeNetwork', bot => $bot,
    config => { irc => { server => 'irc.somenetwork.org', port => 6667 } });

=head1 DESCRIPTION

Represents an IRC network for a L<Bot::Maverick> IRC bot. When constructed,
the network object registers hooks for the L<Bot::Maverick> C<start>, C<stop>,
and C<reload> hooks, to call its own methods of the same name.

=head1 ATTRIBUTES

=head2 name

Identifying name for network, required and must be unique among the networks
added to a L<Bot::Maverick> object. Used for the default L</"config_file">
name.

=head2 bot

Weakened reference to main L<Bot::Maverick> object.

=head2 config_file

Configuration filename for network, defaults to lowercased
L<Bot::Maverick/"name"> appended with C<-> and lowercased network L</"name">,
then appended with C<.conf>.

=head2 config

L<Bot::Maverick::Config> configuration object for network.

=head2 logger

Logging object, defaults to L<Mojo::Log> object logging to configuration option
C<logfile> or STDERR.

=head2 users

Hash reference of L<Bot::Maverick::User> objects representing known network
users.

=head2 channels

Hash reference of L<Bot::Maverick::Channel> objects representing known network
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

L<Bot::Maverick>, L<Bot::Maverick::User>, L<Bot::Maverick::Channel>, L<Bot::Maverick::Config>
