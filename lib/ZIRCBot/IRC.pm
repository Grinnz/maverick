package ZIRCBot::IRC;

use Moose::Role;
use POE;

my @irc_events = qw/irc_375 irc_372 irc_376 irc_422 irc_331 irc_332 irc_333 irc_352 irc_315
	irc_311 irc_319 irc_301 irc_313 irc_330 irc_335 irc_317 irc_318
	irc_notice irc_public irc_msg irc_whois irc_ping irc_disconnected
	irc_invite irc_kick irc_join irc_part irc_nick irc_mode/;
sub get_irc_events { @irc_events }

sub identify {
	my $self = shift;
	my $irc = $self->irc;
	my $nick = $self->config->{irc}{nick};
	my $pass = $self->config->{irc}{password};
	if (length $nick and length $pass) {
		$irc->yield(quote => "nickserv identify $nick $pass");
	}
}

sub irc_375 { # RPL_MOTDSTART
}

sub irc_372 { # RPL_MOTD
} # prevent MOTD from showing up in the debug output

sub irc_376 { # RPL_ENDOFMOTD
	my $self = $_[OBJECT];
	$self->identify;
}

sub irc_422 { # ERR_NOMOTD
	my $self = $_[OBJECT];
	$self->identify;
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

sub irc_disconnected {
	my $self = $_[OBJECT];
	$self->end_sessions;
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

no Moose::Role;

1;
