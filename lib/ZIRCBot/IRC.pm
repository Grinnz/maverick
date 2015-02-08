package ZIRCBot::IRC;

use Mojo::IRC;
use Mojo::Util 'dumper';
use Parse::IRC;
use Scalar::Util 'weaken';

use Moo::Role;
use warnings NONFATAL => 'all';

my @irc_events = qw/irc_333 irc_335 irc_422 irc_rpl_motdstart irc_rpl_endofmotd
	irc_rpl_notopic irc_rpl_topic irc_rpl_whoreply irc_rpl_endofwho
	irc_rpl_whoisuser irc_rpl_whoischannels irc_rpl_away irc_rpl_whoisoperator
	irc_rpl_whoisaccount irc_rpl_whoisidle irc_rpl_endofwhois
	irc_notice irc_public irc_privmsg irc_whois irc_invite irc_kick irc_join
	irc_part irc_nick irc_mode/;
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

# IRC event callbacks

sub irc_rpl_motdstart { # RPL_MOTDSTART
	my ($self, $irc, $message) = @_;
}

sub irc_rpl_endofmotd { # RPL_ENDOFMOTD
	my ($self, $irc, $message) = @_;
}

sub irc_422 { # ERR_NOMOTD
	my ($self, $irc, $message) = @_;
}

sub irc_rpl_notopic { # RPL_NOTOPIC
	my ($self, $irc, $message) = @_;
}

sub irc_rpl_topic { # RPL_TOPIC
	my ($self, $irc, $message) = @_;
}

sub irc_333 { # topic info
	my ($self, $irc, $message) = @_;
}

sub irc_rpl_whoreply { # RPL_WHOREPLY
	my ($self, $irc, $message) = @_;
}

sub irc_rpl_endofwho { # RPL_ENDOFWHO
	my ($self, $irc, $message) = @_;
}

sub irc_rpl_whoisuser { # RPL_WHOISUSER
	my ($self, $irc, $message) = @_;
}

sub irc_rpl_whoischannels { # RPL_WHOISCHANNELS
	my ($self, $irc, $message) = @_;
}

sub irc_rpl_away { # RPL_AWAY
	my ($self, $irc, $message) = @_;
}

sub irc_rpl_whoisoperator { # RPL_WHOISOPERATOR
	my ($self, $irc, $message) = @_;
}

sub irc_rpl_whoisaccount { # RPL_WHOISACCOUNT
	my ($self, $irc, $message) = @_;
}

sub irc_335 { # whois bot string
	my ($self, $irc, $message) = @_;
}

sub irc_rpl_whoisidle { # RPL_WHOISIDLE
	my ($self, $irc, $message) = @_;
}

sub irc_rpl_endofwhois { # RPL_ENDOFWHOIS
	my ($self, $irc, $message) = @_;
}

sub irc_notice {
	my ($self, $irc, $message) = @_;
}

sub irc_public {
	my ($self, $irc, $message) = @_;
	my ($channel, $msg) = @{$message->{params}};
	my $from = parse_from_nick($message->{prefix});
	$self->logger->info("[$channel] <$from> $msg") if $self->config->{main}{echo};
}

sub irc_privmsg {
	my ($self, $irc, $message) = @_;
	my ($to, $msg) = @{$message->{params}};
	my $from = parse_from_nick($message->{prefix});
	$self->logger->info("[privmsg] <$from> $msg") if $self->config->{main}{echo};
}

sub irc_whois {
	my ($self, $irc, $message) = @_;
}

sub irc_invite {
	my ($self, $irc, $message) = @_;
}

sub irc_kick {
	my ($self, $irc, $message) = @_;
}

sub irc_join {
	my ($self, $irc, $message) = @_;
}

sub irc_part {
	my ($self, $irc, $message) = @_;
}

sub irc_quit {
	my ($self, $irc, $message) = @_;
}

sub irc_nick {
	my ($self, $irc, $message) = @_;
}

sub irc_mode {
	my ($self, $irc, $message) = @_;
}

# Helper functions

sub parse_from_nick {
	my $prefix = shift // return undef;
	$prefix =~ /^([^!]+)/ and return $1;
	return undef;
}

1;
