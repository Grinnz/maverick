package Bot::ZIRC::Message;

use Bot::ZIRC::Channel;
use Bot::ZIRC::Command;
use Bot::ZIRC::Network;
use Bot::ZIRC::User;
use Carp 'croak';
use Scalar::Util 'blessed';

use Moo;
use namespace::clean;

use constant IRC_MAX_MESSAGE_LENGTH => 510;

has 'network' => (
	is => 'ro',
	isa => sub { croak "Invalid network object $_[0]"
		unless blessed $_[0] and $_[0]->isa('Bot::ZIRC::Network') },
	lazy => 1,
	default => sub { Bot::ZIRC::Network->new(name => 'dummy') },
	handles => [qw/bot config logger nick write/],
);

has 'sender' => (
	is => 'ro',
	isa => sub { croak "Invalid sender $_[0]"
		unless blessed $_[0] and $_[0]->isa('Bot::ZIRC::User') },
	lazy => 1,
	default => sub { Bot::ZIRC::User->new(nick => 'dummy') },
	handles => [qw/check_access/],
);

has 'channel' => (
	is => 'ro',
	isa => sub { return unless defined $_[0]; croak "Invalid channel $_[0]"
		unless blessed $_[0] and $_[0]->isa('Bot::ZIRC::Channel') },
);

has 'text' => (
	is => 'ro',
	lazy => 1,
	default => '',
);

has 'command' => (
	is => 'rwp',
	isa => sub { croak "Invalid command $_[0]"
		unless blessed $_[0] and $_[0]->isa('Bot::ZIRC::Command') },
);

has 'args' => (
	is => 'rwp',
);

sub args_list {
	my $self = shift;
	return split ' ', ($self->args // '');
}

sub parse_command {
	my $self = shift;
	my $trigger = $self->config->get('commands','trigger') // '';
	my $by_nick = $self->config->get('commands','by_nick');
	my $bare = $self->config->get('commands','bare');
	my $bot_nick = $self->nick;
	
	my ($cmd_name, $args_str);
	$trigger = quotemeta $trigger;
	if (length $trigger and $self->text =~ /^[$trigger](\w+)\s*(.*?)$/i) {
		($cmd_name, $args_str) = ($1, $2);
	} elsif ($by_nick and $self->text =~ /^\Q$bot_nick\E[:,]?\s+(\w+)\s*(.*?)$/i) {
		($cmd_name, $args_str) = ($1, $2);
	} elsif (($bare or !defined $self->channel) and $self->text =~ /^(\w+)\s*(.*?)$/) {
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
			$self->reply("Command $cmd_name is ambiguous. Did you mean: $suggestions");
			return '';
		}
		$command = $self->bot->get_command($cmds->[0]);
	}
	
	return undef unless defined $command;
	
	unless ($command->is_enabled) {
		$self->reply_private("Command $command is currently disabled.");
		return '';
	}
	
	$args_str = IRC::Utils::strip_formatting($args_str) if $command->strip_formatting;
	$args_str =~ s/^\s+//;
	$args_str =~ s/\s+$//;
	
	$self->_set_command($command);
	$self->_set_args($args_str);
	
	return 1;
}

sub reply {
	my $self = shift;
	$self->_reply($self->sender, $self->channel, @_);
}

sub reply_private {
	my $self = shift;
	$self->_reply($self->sender, undef, @_);
}

sub reply_bare {
	my $self = shift;
	$self->_reply(undef, $self->channel, @_);
}

sub _reply {
	my $cb = ref $_[-1] eq 'CODE' ? pop : undef;
	my ($self, $sender, $channel, $message) = @_;
	
	if (defined $channel) {
		$message = "$sender: $message" if defined $sender;
		my @reply = $self->_limit_reply(privmsg => $channel, $message);
		push @reply, $cb if $cb;
		$self->network->write(@reply);
	} elsif (defined $sender) {
		my @writes;
		foreach my $reply ($self->_split_reply(privmsg => $sender, $message)) {
			push @writes, sub { $self->network->write(@$reply, shift->begin) };
		}
		push @writes, $cb if $cb;
		Mojo::IOLoop->delay(@writes);
	} else {
		croak "No sender or channel specified for reply";
	}
	
	if ($self->config->get('echo')) {
		my $nick = $self->nick;
		my $target = $channel // $sender;
		$self->logger->info("[to $target] <$nick> $message");
	}
	
	return $self;
}

sub _limit_reply {
	my ($self, @args) = @_;
	my $msg = pop @args;
	my $allowed_len = $self->_allowed_message_length(@args);
	$msg = substr($msg, 0, ($allowed_len-3)).'...' if length $msg > $allowed_len;
	return (@args, ":$msg");
}

sub _split_reply {
	my ($self, @args) = @_;
	my $msg = pop @args;
	my $allowed_len = $self->_allowed_message_length(@args);
	my @returns;
	while (my $chunk = substr $msg, 0, $allowed_len, '') {
		push @returns, [@args, ":$chunk"];
	}
	return @returns;
}

sub _allowed_message_length {
	my ($self, @args) = @_;
	my $hostmask = $self->network->user($self->nick)->hostmask // '';
	my $prefix_len = length ":$hostmask " . join(' ', @args, ':');
	return IRC_MAX_MESSAGE_LENGTH - $prefix_len;
}

1;
