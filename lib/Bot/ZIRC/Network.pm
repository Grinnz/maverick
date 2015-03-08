package Bot::ZIRC::Network;

use Carp;
use List::Util 'any';
use IRC::Utils 'parse_user';
use Mojo::IOLoop;
use Mojo::IRC;
use Mojo::Util 'dumper';
use Parse::IRC;
use Scalar::Util qw/blessed looks_like_number weaken/;
use Bot::ZIRC::Access qw/:access channel_access_level/;
use Bot::ZIRC::Channel;
use Bot::ZIRC::User;

use Moo 2;
use namespace::clean;

use overload '""' => sub { shift->name };

use constant IRC_MAX_MESSAGE_LENGTH => 510;

our @CARP_NOT = qw(Bot::ZIRC Bot::ZIRC::Command Bot::ZIRC::User Bot::ZIRC::Channel Moo);

my @irc_events = qw/irc_default irc_invite irc_join irc_kick irc_mode irc_nick
	irc_notice irc_part irc_privmsg irc_public irc_quit irc_rpl_welcome
	irc_rpl_motdstart irc_rpl_endofmotd err_nomotd irc_rpl_notopic
	irc_rpl_topic irc_rpl_topicwhotime irc_rpl_namreply irc_rpl_whoreply
	irc_rpl_endofwho irc_rpl_whoisuser irc_rpl_whoischannels irc_rpl_away
	irc_rpl_whoisoperator irc_rpl_whoisaccount irc_rpl_whoisidle irc_335
	irc_rpl_endofwhois/;
sub get_irc_events { @irc_events }

has 'name' => (
	is => 'rwp',
	isa => sub { croak "Unspecified network name" unless defined $_[0] },
	required => 1,
);

has 'bot' => (
	is => 'rwp',
	required => 1,
	isa => sub { croak "Invalid bot" unless blessed $_[0] and $_[0]->isa('Bot::ZIRC') },
	weak_ref => 1,
	handles => [qw/bot_version config_dir get_hooks is_stopping/],
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
	default => sub { my $name = shift->name; return "zirc-$name.conf" },
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
	$config->apply($self->init_config)->store if %{$self->init_config};
	return $config;
}

has 'futures' => (
	is => 'ro',
	lazy => 1,
	default => sub { {} },
	init_arg => undef,
);

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
	die "IRC server for network $self is not configured\n"
		unless defined $server and length $server;
	$server .= ":$port" if defined $port and length $port;
	$nick //= 'ZIRCBot',
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

sub start {
	my $self = shift;
	my $irc = $self->irc;
	
	$irc->register_default_event_handlers;
	weaken $self;
	foreach my $event ($self->get_irc_events) {
		my $handler = $self->can($event) // die "No handler found for IRC event $event\n";
		$irc->on($event => sub { shift; $self->$handler(@_) });
	}
	$irc->on(close => sub { $self->on_disconnect });
	$irc->on(error => sub { $self->logger->error($_[1]); $self->disconnect; });
	
	my $server = $self->server;
	$self->logger->debug("Connecting to $server");
	$self->connect;
	return $self;
}

sub stop {
	my $self = shift;
	my $server = $self->server;
	$self->logger->debug("Disconnecting from $server");
	$self->disconnect(@_);
	return $self;
}

sub reload {
	my $self = shift;
	$self->clear_logger;
	$self->logger->debug("Reloading network $self");
	$self->config->reload;
	return $self;
}

# IRC methods

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
		$self->autojoin;
		$self->check_recurring;
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

sub connect {
	my $self = shift;
	my $server = $self->server;
	$self->logger->debug("Connected to $server");
	weaken $self;
	$self->irc->connect(sub { shift; $self->on_connect(@_) });
}

sub disconnect {
	my $self = shift;
	my $cb = ref $_[-1] eq 'CODE' ? pop : undef;
	my $message = shift;
	if (defined $message) {
		$self->write(quit => $message, sub { shift->disconnect($cb) });
	} else {
		$self->irc->disconnect($cb);
	}
}

sub reconnect {
	my $self = shift;
	my $server = $self->server;
	$self->logger->debug("Reconnecting to $server");
	$self->connect;
}

sub identify {
	my $self = shift;
	my $nick = $self->config->get('irc','nick');
	my $pass = $self->config->get('irc','password');
	if (defined $nick and length $nick and defined $pass and length $pass) {
		$self->do_identify($nick, $pass);
	}
}

sub do_identify {
	my ($self, $nick, $pass) = @_;
	$self->logger->debug("Identifying with NickServ as $nick");
	$self->write(quote => "NICKSERV identify $nick $pass");
}

sub autojoin {
	my $self = shift;
	my @channels = split /[\s,]+/, $self->config->get('channels','autojoin') // '';
	return unless @channels;
	my $channels_str = join ', ', @channels;
	$self->logger->debug("Joining channels: $channels_str");
	while (my @chunk = splice @channels, 0, 10) {
		$self->write(join => join(',', @chunk));
	}
}

sub check_recurring {
	my $self = shift;
	Mojo::IOLoop->remove($self->check_recurring_timer) if $self->has_check_recurring_timer;
	weaken $self;
	my $timer_id = Mojo::IOLoop->recurring(60 => sub { $self->check_nick });
	$self->check_recurring_timer($timer_id);
}

sub check_nick {
	my $self = shift;
	my $desired = $self->config->get('irc','nick');
	unless (lc $desired eq lc substr $self->nick, 0, length $desired) {
		$self->write(nick => $desired);
		$self->write(whois => $desired);
	} else {
		$self->write(whois => $self->nick);
	}
}

sub reply {
	my ($self, $sender, $channel, $message, $cb) = @_;
	if (defined $channel) {
		my @reply = $self->limit_reply(privmsg => $channel, "$sender: $message");
		push @reply, $cb if $cb;
		$self->write(@reply);
	} else {
		my @writes;
		foreach my $reply ($self->split_reply(privmsg => $sender, $message)) {
			push @writes, sub { $self->write(@$reply, shift->begin) };
		}
		push @writes, $cb if $cb;
		Mojo::IOLoop->delay(@writes);
	}
	return $self;
}

sub limit_reply {
	my ($self, @args) = @_;
	my $msg = pop @args;
	my $hostmask = $self->user($self->nick)->hostmask;
	my $prefix_len = length ":$hostmask " . join(' ', @args, ':');
	my $allowed_len = IRC_MAX_MESSAGE_LENGTH - $prefix_len;
	$msg = substr($msg, 0, ($allowed_len-3)).'...' if length $msg > $allowed_len;
	return (@args, $msg);
}

sub split_reply {
	my ($self, @args) = @_;
	my $msg = pop @args;
	my $hostmask = $self->user($self->nick)->hostmask;
	my $prefix_len = length ":$hostmask " . join(' ', @args, ':');
	my $allowed_len = IRC_MAX_MESSAGE_LENGTH - $prefix_len;
	my @returns;
	while (my $chunk = substr $msg, 0, $allowed_len, '') {
		push @returns, [@args, $chunk];
	}
	return @returns;
}

# Command parsing

sub check_privmsg {
	my ($self, $sender, $channel, $message) = @_;
	$sender = $self->user($sender);
	my ($command, @args) = $self->parse_command($sender, $channel, $message);
	
	if (defined $command) {
		my $args_str = join ' ', @args;
		$self->logger->debug("<$sender> [command] $command $args_str");
			
		$sender->check_access($command->required_access, $channel, sub {
			my ($sender, $has_access) = @_;
			if ($has_access) {
				$sender->logger->debug("$sender has access to run command $command");
				$command->run($sender->network, $sender, $channel, @args);
			} else {
				$sender->logger->debug("$sender does not have access to run command $command");
				my $channel_str = defined $channel ? " in $channel" : '';
				$sender->network->reply($sender, undef, "You do not have access to run $command$channel_str");
			}
		});
	} else {
		my $hooks = $self->get_hooks('privmsg');
		foreach my $hook (@$hooks) {
			local $@;
			eval { $self->$hook($sender, $channel, $message) };
			$self->logger->error("Error in privmsg hook: $@") if $@;
		}
	}
}

sub parse_command {
	my ($self, $sender, $channel, $message) = @_;
	my $trigger = $self->config->get('commands','trigger');
	my $by_nick = $self->config->get('commands','by_nick');
	my $bot_nick = $self->nick;
	
	my ($cmd_name, $args_str);
	if ($trigger and $message =~ /^\Q$trigger\E(\w+)\s*(.*?)$/i) {
		($cmd_name, $args_str) = ($1, $2);
	} elsif ($by_nick and $message =~ /^\Q$bot_nick\E[:,]?\s+(\w+)\s*(.*?)$/i) {
		($cmd_name, $args_str) = ($1, $2);
	} elsif (!defined $channel and $message =~ /^(\w+)\s*(.*?)$/) {
		($cmd_name, $args_str) = ($1, $2);
	} else {
		return undef;
	}
	
	my $command = $self->bot->get_command($cmd_name);
	if (!defined $command and $self->config->get('commands','prefixes')) {
		my $cmds = $self->bot->get_commands_by_prefix($cmd_name);
		return undef unless $cmds and @$cmds;
		if (@$cmds > 1) {
			my $suggestions = join ', ', sort @$cmds;
			$self->reply($sender, $channel,
				"Command $cmd_name is ambiguous. Did you mean: $suggestions");
			return undef;
		}
		$command = $self->bot->get_command($cmds->[0]);
	}
	
	return undef unless defined $command;
	
	unless ($command->is_enabled) {
		$self->reply($sender, undef, "Command $command is currently disabled.");
		return undef;
	}
	
	$args_str = IRC::Utils::strip_formatting($args_str) if $command->strip_formatting;
	$args_str =~ s/^\s+//;
	$args_str =~ s/\s+$//;
	my @args = $command->tokenize ? (split /\s+/, $args_str) : $args_str;
	
	return ($command, @args);
}

# Queue future events

sub after_who {
	my ($self, $nick, $cb) = @_;
	$self->queue_event_future(who => lc $nick, $cb);
	$self->write(who => $nick);
	return $self;
}

sub run_after_who {
	my ($self, $nick) = @_;
	my $user = $self->user($nick);
	my $futures = $self->get_event_futures(who => lc $nick);
	$self->$_($user) for @$futures;
	return $self;
}

sub after_whois {
	my ($self, $nick, $cb) = @_;
	$self->queue_event_future(whois => lc $nick, $cb);
	$self->write(whois => $nick);
	return $self;
}

sub run_after_whois {
	my ($self, $nick) = @_;
	my $user = $self->user($nick);
	my $futures = $self->get_event_futures(whois => lc $nick);
	$self->$_($user) for @$futures;
	return $self;
}

sub queue_event_future {
	my $self = shift;
	my $future = pop;
	croak "Invalid coderef $future" unless defined $future and ref $future eq 'CODE';
	my ($event, $key) = @_;
	croak 'No event given' unless defined $event;
	my $futures = $self->futures->{$event} //= {};
	my $future_list = defined $key
		? ($futures->{by_key}{$key} //= [])
		: ($futures->{list} //= []);
	push @$future_list, ref $future eq 'ARRAY' ? @$future : $future;
	return $self;
}

sub get_event_futures {
	my ($self, $event, $key) = @_;
	croak 'No event given' unless defined $event;
	return undef unless exists $self->futures->{$event};
	my $futures = $self->futures->{$event};
	my $future_list = defined $key
		? delete $futures->{by_key}{$key}
		: delete $futures->{list};
	delete $self->futures->{$event} unless exists $futures->{list}
		or keys %{$futures->{by_key}};
	return $future_list // [];
}

# IRC event callbacks

sub irc_default {
	my ($self, $message) = @_;
	my $command = $message->{command} // '';
	my $params_str = join ', ', map { "'$_'" } @{$message->{params}};
	my $from = parse_user($message->{prefix});
	$self->logger->debug("[$command] <$from> [ $params_str ]");
}

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
		$self->write('who', '+c', $channel);
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
			split /[\s,]+/, $self->config->{channels}{autojoin}) {
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
	$self->user($from)->nick($to);
}

sub irc_notice {
	my ($self, $message) = @_;
	my ($to, $msg) = @{$message->{params}};
	my $from = parse_user($message->{prefix});
	$self->logger->info("[notice $to] <$from> $msg") if $self->config->get('echo');
	my $hooks = $self->get_hooks('notice');
	if (@$hooks) {
		my $sender = $self->user($from);
		my $channel = lc $to eq lc $self->nick ? undef : $to;
		foreach my $hook (@$hooks) {
			local $@;
			eval { $self->$hook($sender, $channel, $msg) };
			$self->logger->error("Error in notice hook: $@") if $@;
		}
	}
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
	$self->check_privmsg($from, undef, $msg);
}

sub irc_public {
	my ($self, $message) = @_;
	my ($channel, $msg) = @{$message->{params}};
	my $from = parse_user($message->{prefix});
	$self->logger->info("[$channel] <$from> $msg") if $self->config->get('echo');
	$self->check_privmsg($from, $channel, $msg);
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
	my ($to) = @{$message->{params}};
	$self->logger->debug("Set nick to $to");
	$self->nick($to);
	$self->write(whois => $to);
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
	foreach my $nick (split /\s+/, $nicks) {
		my $access = ACCESS_NONE;
		if ($nick =~ s/^([-~&@%+])//) {
			$access = channel_access_level($1);
		}
		my $user = $self->user($nick);
		$user->add_channel($channel);
		$user->channel_access($channel => $access);
		$self->channel($channel)->add_user($nick);
	}
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
	$self->identify if lc $nick eq lc $self->nick and !$reg;
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
	my ($to, $nick) = @{$message->{params}};
	$self->logger->debug("End of whois reply for $nick");
	my $user = $self->user($nick);
	$user->identity(undef) unless $user->is_registered;
	
	$self->run_after_whois($nick);
	$self->identify if lc $nick eq lc $self->nick and !$user->is_registered;
}

1;
