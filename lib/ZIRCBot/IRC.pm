package ZIRCBot::IRC;

use Mojo::IRC;
use Parse::IRC;
use Scalar::Util 'weaken';

use Moo::Role;
use warnings NONFATAL => 'all';

my @irc_events = qw/irc_375 irc_372 irc_376 irc_422 irc_331 irc_332 irc_333 irc_352 irc_315
	irc_311 irc_319 irc_301 irc_313 irc_330 irc_335 irc_317 irc_318
	irc_notice irc_public irc_privmsg irc_whois
	irc_invite irc_kick irc_join irc_part irc_nick irc_mode/;
sub get_irc_events { @irc_events }

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
	$realname = sprintf 'ZIRCBot %s by %s', $self->bot_version, 'Grinnz' unless length $realname;
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

before 'start' => sub {
	my $self = shift;
	my $irc = $self->irc;
	
	$irc->register_default_event_handlers;
	weaken $self;
	foreach my $event ($self->get_irc_events) {
		my $handler = $self->can($event) // die "No handler found for IRC event $event\n";
		$irc->on($event => sub { $self->$handler(@_) });
	}
	$irc->on(close => sub { $self->irc_disconnected($irc) });
	
	my $server = $irc->server;
	$self->logger->debug("Connecting to $server");
	$irc->connect(sub { $self->irc_connected(@_) });
};

after 'stop' => sub {
	my $self = shift;
	my $irc = $self->irc;
	
	$self->logger->debug("Disconnecting from server");
	$irc->disconnect;
};

sub irc_connected {
	my ($self, $irc, $err) = @_;
	if ($err) {
		$self->logger->error($err);
	} else {
		$self->irc_identify($irc);
		$self->irc_autojoin($irc);
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
	my @channels = $self->config->{channels}{autojoin};
	return unless @channels;
	@channels = map { split /[\s,]+/ } @channels;
	my $channels_str = join ', ', @channels;
	$self->logger->debug("Joining channels: $channels_str");
	$irc->write(join => $_) for @channels;
}

sub irc_disconnected {
	my $self = shift;
	my $irc = $self->irc;
	$self->logger->debug("Disconnected from server");
	if (!$self->is_stopping and ($self->config->{irc}{reconnect}//1)) {
		my $server = $irc->server;
		$self->logger->debug("Reconnecting to $server");
		weaken $self;
		$irc->connect(sub { $self->irc_connected(@_) });
	}
}

sub irc_375 { # RPL_MOTDSTART
}

sub irc_372 { # RPL_MOTD
} # prevent MOTD from showing up in the debug output

sub irc_376 { # RPL_ENDOFMOTD
}

sub irc_422 { # ERR_NOMOTD
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

sub irc_privmsg {
}

sub irc_whois {
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
