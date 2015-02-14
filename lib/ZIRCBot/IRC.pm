package ZIRCBot::IRC;

use Carp;
use Future;
use List::Util 'any';
use IRC::Utils 'parse_user';
use Mojo::IRC;
use Mojo::Util 'dumper';
use Parse::IRC;
use Scalar::Util qw(looks_like_number weaken);
use ZIRCBot::Access;
use ZIRCBot::Channel;
use ZIRCBot::User;

use Moo::Role;
use warnings NONFATAL => 'all';

use constant IRC_MAX_MESSAGE_LENGTH => 510;

my @irc_events = qw/irc_default irc_invite irc_join irc_kick irc_mode irc_nick
	irc_notice irc_part irc_privmsg irc_public irc_quit irc_rpl_welcome
	irc_rpl_motdstart irc_rpl_endofmotd err_nomotd irc_rpl_notopic
	irc_rpl_topic irc_rpl_topicwhotime irc_rpl_namreply irc_rpl_whoreply
	irc_rpl_endofwho irc_rpl_whoisuser irc_rpl_whoischannels irc_rpl_away
	irc_rpl_whoisoperator irc_rpl_whoisaccount irc_rpl_whoisidle irc_335
	irc_rpl_endofwhois/;
sub get_irc_events { @irc_events }

has 'channels' => (
	is => 'ro',
	lazy => 1,
	default => sub { {} },
	init_arg => undef,
);

sub channel {
	my $self = shift;
	my $name = shift // croak "No channel name provided";
	return $self->channels->{lc $name} //= ZIRCBot::Channel->new(name => $name);
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
	return $self->users->{lc $nick} //= ZIRCBot::User->new(nick => $nick);
}

has 'irc' => (
	is => 'lazy',
	init_arg => undef,
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
		@{$self->config->{irc}}{qw/server port server_pass ssl nick realname/};
	die "IRC server is not configured\n" unless defined $server and length $server;
	$server .= ":$port" if defined $port and length $port;
	$nick //= 'ZIRCBot',
	$realname = sprintf 'ZIRCBot %s by %s', $self->bot_version, 'Grinnz'
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

before 'start' => sub {
	my $self = shift;
	my $irc = $self->irc;
	
	$irc->register_default_event_handlers;
	weaken $self;
	foreach my $event ($self->get_irc_events) {
		my $handler = $self->can($event) // die "No handler found for IRC event $event\n";
		$irc->on($event => sub { $self->$handler(@_) });
	}
	$irc->on(close => sub { $self->irc_disconnected($_[0]) });
	$irc->on(error => sub { $self->logger->error($_[1]); $_[0]->disconnect; });
	
	my $server = $irc->server;
	$self->logger->debug("Connecting to $server");
	$irc->connect(sub { $self->irc_connected(@_) });
};

before 'stop' => sub {
	my $self = shift;
	my $irc = $self->irc;
	
	$self->logger->debug("Disconnecting from server");
	$irc->disconnect(sub {});
};

# IRC methods

sub irc_connected {
	my ($self, $irc, $err) = @_;
	if ($err) {
		$self->logger->error($err);
		my $delay = $self->config->{irc}{reconnect_delay};
		$delay = 10 unless defined $delay and looks_like_number $delay;
		Mojo::IOLoop->timer($delay => sub { $self->irc_reconnect($irc) });
	} else {
		$self->irc_identify($irc);
		$self->irc_autojoin($irc);
		$self->irc_check_recurring($irc);
	}
}

sub irc_disconnected {
	my ($self, $irc) = @_;
	$self->logger->debug("Disconnected from server");
	Mojo::IOLoop->remove($self->check_recurring_timer) if $self->has_check_recurring_timer;
	$self->clear_check_recurring_timer;
	$self->irc_reconnect($irc);
}

sub irc_reconnect {
	my ($self, $irc) = @_;
	if (!$self->is_stopping and ($self->config->{irc}{reconnect}//1)) {
		my $server = $irc->server;
		$self->logger->debug("Reconnecting to $server");
		weaken $self;
		$irc->connect(sub { $self->irc_connected(@_) });
	}
}

sub irc_identify {
	my ($self, $irc) = @_;
	my $nick = $self->config->{irc}{nick};
	my $pass = $self->config->{irc}{password};
	if (defined $nick and length $nick and defined $pass and length $pass) {
		$self->("Identifying with NickServ as $nick");
		$irc->write(quote => "NICKSERV identify $nick $pass");
	}
}

sub irc_autojoin {
	my ($self, $irc) = @_;
	my @channels = split /[\s,]+/, $self->config->{channels}{autojoin};
	return unless @channels;
	my $channels_str = join ', ', @channels;
	$self->logger->debug("Joining channels: $channels_str");
	while (my @chunk = splice @channels, 0, 10) {
		$irc->write(join => join(',', @chunk));
	}
}

sub irc_check_recurring {
	my ($self, $irc) = @_;
	Mojo::IOLoop->remove($self->check_recurring_timer) if $self->has_check_recurring_timer;
	weaken $self;
	my $timer_id = Mojo::IOLoop->recurring(60 => sub { $self->irc_check($irc) });
	$self->check_recurring_timer($timer_id);
}

sub irc_check {
	my ($self, $irc) = @_;
	my $desired = $self->config->{irc}{nick};
	unless (lc $desired eq lc substr $irc->nick, 0, length $desired) {
		$irc->write(nick => $desired);
		$irc->write(whois => $desired);
	} else {
		$irc->write(whois => $irc->nick);
	}
}

sub irc_limit_msg {
	my ($self, @args) = @_;
	my $msg = pop @args;
	my $hostmask = $self->user($self->irc->nick)->hostmask;
	my $prefix_len = length ":$hostmask " . join(' ', @args, ':');
	my $allowed_len = IRC_MAX_MESSAGE_LENGTH - $prefix_len;
	$msg = substr($msg, 0, ($allowed_len-3)).'...' if length $msg > $allowed_len;
	return (@args, $msg);
}

sub irc_split_msg {
	my ($self, @args) = @_;
	my $msg = pop @args;
	my $hostmask = $self->user($self->irc->nick)->hostmask;
	my $prefix_len = length ":$hostmask " . join(' ', @args, ':');
	my $allowed_len = IRC_MAX_MESSAGE_LENGTH - $prefix_len;
	my @returns;
	while (my $chunk = substr $msg, 0, $allowed_len, '') {
		push @returns, [@args, $chunk];
	}
	return \@returns;
}

sub irc_check_command {
	my ($self, $irc, $sender, $channel, $message) = @_;
	my ($command, @args) = $self->parse_command($irc, $sender, $channel, $message);
	return unless defined $command;
	
	my $check = $self->check_command_access($irc, $sender, $channel, $command);
	unless (defined $check) {
		$self->logger->debug("Don't know identity of $sender; rechecking after whois");
		$self->queue_event_future(Future->new->on_done(sub {
			my ($self, $irc, $user) = @_;
			my $check = $self->check_command_access($irc, $sender, $channel, $command);
			my $cmd_name = $command->name;
			if ($check) {
				$self->logger->debug("$sender has access to run command $cmd_name");
				$self->irc_run_command($irc, $sender, $channel, $command, @args);
			} else {
				$self->logger->debug("$sender does not have access to run command $cmd_name");
				my $channel_str = defined $channel ? " in $channel" : '';
				$irc->write(privmsg => $sender, "You do not have access to run $cmd_name$channel_str");
			}
		}), 'whois', $sender);
		$irc->write(whois => $sender);
		return;
	}
	my $cmd_name = $command->name;
	if ($check) {
		$self->logger->debug("$sender has access to run command $cmd_name");
		$self->irc_run_command($irc, $sender, $channel, $command, @args);
	} else {
		$self->logger->debug("$sender does not have access to run command $cmd_name");
		my $channel_str = defined $channel ? " in $channel" : '';
		$irc->write(privmsg => $sender, "You do not have access to run $cmd_name$channel_str");
	}
}

sub irc_run_command {
	my ($self, $irc, $sender, $channel, $command, @args) = @_;
	local $@;
	eval { $command->on_run->($self, $irc, $sender, $channel, @args); 1 };
	if ($@) {
		my $err = $@;
		chomp $err;
		my $cmd_name = $command->name;
		warn "Error running command $cmd_name: $err\n";
	}
}

# IRC event callbacks

sub irc_default {
	my ($self, $irc, $message) = @_;
	my $command = $message->{command} // '';
	my $params_str = join ', ', map { "'$_'" } @{$message->{params}};
	my $from = parse_user($message->{prefix});
	$self->logger->debug("[$command] <$from> [ $params_str ]");
}

sub irc_invite {
	my ($self, $irc, $message) = @_;
	my ($to, $channel) = @{$message->{params}};
	my $from = parse_user($message->{prefix});
	$self->logger->debug("User $from has invited $to to $channel");
}

sub irc_join {
	my ($self, $irc, $message) = @_;
	my ($channel) = @{$message->{params}};
	my $from = parse_user($message->{prefix});
	$self->logger->debug("User $from joined $channel");
	if ($from eq $irc->nick) {
		$self->channel($channel);
	}
	$self->channel($channel)->add_user($from);
	$self->user($from)->add_channel($channel);
	$irc->write(whois => $from) unless lc $from eq lc $irc->nick;
}

sub irc_kick {
	my ($self, $irc, $message) = @_;
	my ($channel, $to) = @{$message->{params}};
	my $from = parse_user($message->{prefix});
	$self->logger->debug("User $from has kicked $to from $channel");
	$self->channel($channel)->remove_user($to);
	$self->user($to)->remove_channel($channel);
	if (lc $to eq lc $irc->nick and any { lc $_ eq lc $channel }
			split /[\s,]+/, $self->config->{channels}{autojoin}) {
		$irc->write(join => $channel);
	}
}

sub irc_mode {
	my ($self, $irc, $message) = @_;
	my ($to, $mode, @params) = @{$message->{params}};
	my $from = parse_user($message->{prefix});
	my $params_str = join ' ', @params;
	if ($to =~ /^#/) {
		my $channel = $to;
		$self->logger->debug("User $from changed mode of $channel to $mode $params_str");
		if (@params and $mode =~ /[qaohvbe]/) {
			if ($mode =~ /[qaohv]/) {
				$irc->write('who', '+cn', $channel, $_)
					for grep { lc $_ ne lc $irc->nick } @params;
			}
		}
	} else {
		my $user = $to;
		$self->logger->debug("User $from changed mode of $user to $mode $params_str");
	}
}

sub irc_nick {
	my ($self, $irc, $message) = @_;
	my ($to) = @{$message->{params}};
	my $from = parse_user($message->{prefix});
	$self->logger->debug("User $from changed nick to $to");
	$_->rename_user($from => $to) foreach values %{$self->channels};
	$self->user($from)->nick($to);
}

sub irc_notice {
	my ($self, $irc, $message) = @_;
	my ($to, $msg) = @{$message->{params}};
	my $from = parse_user($message->{prefix});
	$self->logger->info("[notice $to] <$from> $msg") if $self->config->{main}{echo};
}

sub irc_part {
	my ($self, $irc, $message) = @_;
	my ($channel) = @{$message->{params}};
	my $from = parse_user($message->{prefix});
	$self->logger->debug("User $from parted $channel");
	if ($from eq $irc->nick) {
	}
	$self->channel($channel)->remove_user($from);
	$self->user($from)->remove_channel($channel);
}

sub irc_privmsg {
	my ($self, $irc, $message) = @_;
	my ($to, $msg) = @{$message->{params}};
	my $from = parse_user($message->{prefix});
	$self->logger->info("[private] <$from> $msg") if $self->config->{main}{echo};
	$self->irc_check_command($irc, $from, undef, $msg);
}

sub irc_public {
	my ($self, $irc, $message) = @_;
	my ($channel, $msg) = @{$message->{params}};
	my $from = parse_user($message->{prefix});
	$self->logger->info("[$channel] <$from> $msg") if $self->config->{main}{echo};
	$self->irc_check_command($irc, $from, $channel, $msg);
}

sub irc_quit {
	my ($self, $irc, $message) = @_;
	my $from = parse_user($message->{prefix});
	$self->logger->debug("User $from has quit");
	$_->remove_user($from) foreach values %{$self->channels};
	$self->user($from)->clear_channels;
}

sub irc_rpl_welcome {
	my ($self, $irc, $message) = @_;
	my ($to) = @{$message->{params}};
	$self->logger->debug("Set nick to $to");
	$irc->nick($to);
	$irc->write(whois => $irc->nick);
}

sub irc_rpl_motdstart { # RPL_MOTDSTART
	my ($self, $irc, $message) = @_;
}

sub irc_rpl_endofmotd { # RPL_ENDOFMOTD
	my ($self, $irc, $message) = @_;
}

sub err_nomotd { # ERR_NOMOTD
	my ($self, $irc, $message) = @_;
}

sub irc_rpl_notopic { # RPL_NOTOPIC
	my ($self, $irc, $message) = @_;
	my ($channel) = @{$message->{params}};
	$self->logger->debug("No topic set for $channel");
	$self->channel($channel)->topic(undef);
}

sub irc_rpl_topic { # RPL_TOPIC
	my ($self, $irc, $message) = @_;
	my ($to, $channel, $topic) = @{$message->{params}};
	$self->logger->debug("Topic for $channel: $topic");
	$self->channel($channel)->topic($topic);
}

sub irc_rpl_topicwhotime { # RPL_TOPICWHOTIME
	my ($self, $irc, $message) = @_;
	my ($to, $channel, $who, $time) = @{$message->{params}};
	my $time_str = localtime($time);
	$self->logger->debug("Topic for $channel was changed at $time_str by $who");
	$self->channel($channel)->topic_info([$time, $who]);
}

sub irc_rpl_namreply { # RPL_NAMREPLY
	my ($self, $irc, $message) = @_;
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
	my ($self, $irc, $message) = @_;
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
	
	my $futures = $self->get_event_futures('who', $nick);
	$_->done($self, $irc, $user) for @$futures;
	
	$self->irc_identify if lc $nick eq lc $irc->nick and !$reg;
}

sub irc_rpl_endofwho { # RPL_ENDOFWHO
	my ($self, $irc, $message) = @_;
}

sub irc_rpl_whoisuser { # RPL_WHOISUSER
	my ($self, $irc, $message) = @_;
	my ($to, $nick, $username, $host, $star, $realname) = @{$message->{params}};
	$self->logger->debug("Received user info for $nick!$username\@$host: $realname");
	my $user = $self->user($nick);
	$user->host($host);
	$user->username($username);
	$user->realname($realname);
	$user->clear_is_registered;
	$user->clear_identity;
	$user->clear_bot_access;
	$user->clear_is_away;
	$user->clear_away_message;
	$user->clear_is_ircop;
	$user->clear_ircop_message;
	$user->clear_is_bot;
	$user->clear_is_idle;
	$user->clear_idle_time;
	$user->clear_signon_time;
	$user->clear_channels;
}

sub irc_rpl_whoischannels { # RPL_WHOISCHANNELS
	my ($self, $irc, $message) = @_;
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
	my ($self, $irc, $message) = @_;
	my $msg = pop @{$message->{params}};
	my ($to, $nick) = @{$message->{params}};
	$self->logger->debug("Received away message for $nick: $msg");
	my $user = $self->user($nick);
	$user->is_away(1);
	$user->away_message($msg);
	
	my $futures = $self->get_event_futures('away', $nick);
	$_->done($self, $irc, $user) for @$futures;
}

sub irc_rpl_whoisoperator { # RPL_WHOISOPERATOR
	my ($self, $irc, $message) = @_;
	my ($to, $nick, $msg) = @{$message->{params}};
	$self->logger->debug("Received IRC Operator privileges for $nick: $msg");
	my $user = $self->user($nick);
	$user->is_ircop(1);
	$user->ircop_message($msg);
}

sub irc_rpl_whoisaccount { # RPL_WHOISACCOUNT
	my ($self, $irc, $message) = @_;
	my ($to, $nick, $identity) = @{$message->{params}};
	$self->logger->debug("Received identity for $nick: $identity");
	my $user = $self->user($nick);
	$user->is_registered(1);
	$user->identity($identity);
	$user->bot_access($self->user_access_level($identity));
}

sub irc_335 { # whois bot string
	my ($self, $irc, $message) = @_;
	my ($to, $nick) = @{$message->{params}};
	$self->logger->debug("Received bot status for $nick");
	my $user = $self->user($nick);
	$user->is_bot(1);
}

sub irc_rpl_whoisidle { # RPL_WHOISIDLE
	my ($self, $irc, $message) = @_;
	my ($to, $nick, $seconds, $signon) = @{$message->{params}};
	$self->logger->debug("Received idle status for $nick: $seconds, $signon");
	my $user = $self->user($nick);
	$user->is_idle(1);
	$user->idle_time($seconds);
	$user->signon_time($signon);
}

sub irc_rpl_endofwhois { # RPL_ENDOFWHOIS
	my ($self, $irc, $message) = @_;
	my ($to, $nick) = @{$message->{params}};
	$self->logger->debug("End of whois reply for $nick");
	
	my $user = $self->user($nick);
	my $futures = $self->get_event_futures('whois', $nick);
	$_->done($self, $irc, $user) for @$futures;
	
	$self->irc_identify if lc $nick eq lc $irc->nick and !$user->is_registered;
}

1;
