package ZIRCBot::IRC;

use POE qw/Component::IRC/;

use Moo::Role;
use warnings NONFATAL => 'all';

my @irc_events = qw/_default irc_375 irc_372 irc_376 irc_422 irc_331 irc_332 irc_333 irc_352 irc_315
	irc_311 irc_319 irc_301 irc_313 irc_330 irc_335 irc_317 irc_318
	irc_notice irc_public irc_msg irc_whois irc_ping irc_disconnected
	irc_invite irc_kick irc_join irc_part irc_nick irc_mode/;
sub get_irc_events { @irc_events }

sub _build_irc {
	my $self = shift;
	my $server = $self->config->{irc}{server};
	die "IRC server is not configured\n" unless length $server;
	my $irc = POE::Component::IRC->spawn($self->_connect_options) or die $!;
	return $irc;
}

sub _connect_options {
	my $self = shift;
	my ($server, $port, $server_pass, $ssl, $nick, $realname, $flood) = 
		@{$self->config->{irc}}{qw/server port server_pass ssl nick realname flood/};
	die "IRC server is not configured\n" unless length $server;
	$port //= 6667;
	$ssl //= 0;
	$nick //= 'ZIRCBot',
	$realname = sprintf 'ZIRCBot %s by %s', $self->bot_version, 'Grinnz' unless length $realname;
	$flood //= 0;
	my %options = (
		Server => $server,
		Port => $port,
		UseSSL => $ssl,
		Nick => $nick,
		Ircname => $realname,
		Username => $nick,
		Flood => $flood,
		Resolver => $self->resolver,
	);
	$options{Password} = $server_pass if length $server_pass;
	return %options;
}

after 'hook_start' => sub {
	my $self = shift;
	my $irc = $self->irc;
	
	$irc->yield(register => 'all');
	
	my $server = $irc->server;
	my $port = $irc->port;
	$self->print_debug("Connecting to $server/$port...");
	$irc->yield(connect => {});
};

sub hook_connected {
	my $self = shift;
	$self->identify;
	$self->autojoin;
}

sub identify {
	my $self = shift;
	my $irc = $self->irc;
	my $nick = $self->config->{irc}{nick};
	my $pass = $self->config->{irc}{password};
	if (length $nick and length $pass) {
		$self->print_debug("Identifying with NickServ as $nick...");
		$irc->yield(quote => "NICKSERV identify $nick $pass");
	}
}

sub autojoin {
	my $self = shift;
	my $irc = $self->irc;
	my @channels = $self->config->{channels}{autojoin};
	return unless @channels;
	my $channels_str = join ',', @channels;
	$self->print_debug("Joining channels: $channels_str");
	$irc->yield(join => $_) for @channels;
}

sub irc_disconnected {
	my $self = $_[OBJECT];
	my $irc = $self->irc;
	if (!$self->is_stopping and ($self->config->{irc}{reconnect}//1)) {
		$irc->yield(connect => {});
	} else {
		$irc->yield(shutdown => 'Bye');
	}
}

after 'hook_stop' => sub {
	my $self = shift;
	my $irc = $self->irc;
	$irc->yield(shutdown => 'Bye');
};

sub _default { # Print unknown events in debug mode
	my $self = $_[OBJECT];
	my ($event, $args) = @_[ARG0,ARG1];
	my @output = "$event:";
	foreach my $arg (@$args) {
		$arg //= 'NULL';
		if (ref $arg eq 'ARRAY') {
			@$arg = map { $_ // 'NULL' } @$arg;
			push @output, '[' . join(', ', @$arg) . ']';
		} else {
			push @output, $arg;
		}
	}
	$self->print_debug(join ' ', @output);
	return 0;
}

sub irc_375 { # RPL_MOTDSTART
}

sub irc_372 { # RPL_MOTD
} # prevent MOTD from showing up in the debug output

sub irc_376 { # RPL_ENDOFMOTD
	my $self = $_[OBJECT];
	$self->hook_connected;
}

sub irc_422 { # ERR_NOMOTD
	my $self = $_[OBJECT];
	$self->hook_connected;
}

sub irc_331 { # RPL_NOTOPIC
}

sub irc_332 { # RPL_TOPIC
}

sub irc_333 { # topic info
}

sub irc_352 { # RPL_WHOREPLY
}

sub irc_315 { # RPL_ENDOFWHO
}

sub irc_311 { # RPL_WHOISUSER
}

sub irc_319 { # RPL_WHOISCHANNELS
}

sub irc_301 { # RPL_AWAY
}

sub irc_313 { # RPL_WHOISOPERATOR
}

sub irc_330 { # RPL_WHOISACCOUNT
}

sub irc_335 { # whois bot string
}

sub irc_317 { # RPL_WHOISIDLE
}

sub irc_318 { # RPL_ENDOFWHOIS
}

sub irc_notice {
}

sub irc_public {
}

sub irc_msg {
}

sub irc_whois {
}

sub irc_ping {
}

sub irc_invite {
}

sub irc_kick {
}

sub irc_join {
}

sub irc_part {
}

sub irc_quit {
}

sub irc_nick {
}

sub irc_mode {
}

1;
