package Bot::Maverick::Message;

use Bot::Maverick::Channel;
use Bot::Maverick::Command;
use Bot::Maverick::Network;
use Bot::Maverick::User;
use Carp 'croak';
use Scalar::Util 'blessed';

use Moo;
use namespace::clean;

use constant IRC_MAX_MESSAGE_LENGTH => 510;

our $VERSION = '0.50';

has 'network' => (
	is => 'ro',
	isa => sub { croak "Invalid network object $_[0]"
		unless blessed $_[0] and $_[0]->isa('Bot::Maverick::Network') },
	lazy => 1,
	default => sub { Bot::Maverick::Network->new(name => 'dummy') },
	handles => [qw/bot config logger nick write/],
);

has 'sender' => (
	is => 'ro',
	isa => sub { croak "Invalid sender $_[0]"
		unless blessed $_[0] and $_[0]->isa('Bot::Maverick::User') },
	lazy => 1,
	default => sub { Bot::Maverick::User->new(nick => 'dummy') },
	handles => [qw/check_access/],
);

has 'channel' => (
	is => 'ro',
	isa => sub { return unless defined $_[0]; croak "Invalid channel $_[0]"
		unless blessed $_[0] and $_[0]->isa('Bot::Maverick::Channel') },
);

has 'text' => (
	is => 'ro',
	lazy => 1,
	default => '',
);

has 'command' => (
	is => 'rwp',
	isa => sub { croak "Invalid command $_[0]"
		unless blessed $_[0] and $_[0]->isa('Bot::Maverick::Command') },
);

has 'args' => (
	is => 'rwp',
);

sub args_list {
	my $self = shift;
	return split ' ', ($self->args // '');
}

has 'show_more' => (
	is => 'rw',
	isa => sub { croak "Invalid show-more count"
		if defined $_[0] and $_[0] !~ m/^\d+\z/ },
);

has 'private_reply_max' => (
	is => 'rw',
	isa => sub { croak "Invalid private reply max"
		unless defined $_[0] and $_[0] =~ m/^\d+\z/ },
	lazy => 1,
	default => 5,
);

sub parse_command {
	my $self = shift;
	my $trigger = $self->config->param('commands','trigger') // '';
	my $by_nick = $self->config->param('commands','by_nick');
	my $bare = $self->config->param('commands','bare');
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
	if (!defined $command and $self->config->param('commands','prefixes')) {
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
	my ($self, $message, $sender, $channel) = @_;
	$sender //= $self->sender;
	$channel //= $self->channel;
	$self->_reply($sender, $channel, $message);
}

sub reply_private {
	my ($self, $message, $sender) = @_;
	$sender //= $self->sender;
	$self->_reply($sender, undef, $message);
}

sub reply_bare {
	my ($self, $message, $channel) = @_;
	$channel //= $self->channel // $self->sender;
	$self->_reply(undef, $channel, $message);
}

sub _reply {
	my ($self, $sender, $channel, $message) = @_;
	chomp $message;
	
	my $show_more = $self->show_more // 0;
	my $more_str = $show_more > 0 ? " [ $show_more more results ]" : '';
	if (defined $channel) {
		$message = "$sender: $message" if defined $sender;
		my $reply = $self->_limit_reply(privmsg => $channel, $more_str, $message);
		$self->network->write(privmsg => $channel, ":$reply$more_str");
	} elsif (defined $sender) {
		my @writes;
		$message .= $more_str;
		my $future = $self->bot->new_future->done;
		foreach my $reply ($self->_split_reply(privmsg => $sender, $message)) {
			$future = $future->then_with_f(sub {
				my $f = shift->new;
				$self->network->write(privmsg => $sender, ":$reply", sub { $f->done });
				return $f;
			});
		}
		$self->bot->adopt_future($future);
	} else {
		croak "No sender or channel specified for reply";
	}
	
	if ($self->config->param('main', 'echo')) {
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
	return $msg;
}

sub _split_reply {
	my ($self, @args) = @_;
	my $msg = pop @args;
	my $allowed_len = $self->_allowed_message_length(@args);
	my @returns;
	while (my $chunk = substr $msg, 0, $allowed_len, '') {
		push @returns, $chunk;
	}
	my $max = $self->private_reply_max;
	splice @returns, $max if @returns > $max;
	return @returns;
}

sub _allowed_message_length {
	my ($self, @args) = @_;
	my $hostmask = $self->network->user($self->nick)->hostmask // '';
	my $prefix_len = length ":$hostmask " . join(' ', @args, ':');
	return IRC_MAX_MESSAGE_LENGTH - $prefix_len;
}

1;

=head1 NAME

Bot::Maverick::Message - IRC message class for Maverick

=head1 SYNOPSIS

  my $m = Bot::Maverick::Message->new(network => $network, sender => $sender,
    channel => $channel, text => $text);
  if (defined $m->parse_command) {
    my ($command, $args) = ($m->command, $m->args);
    $m->reply("Got command: $command $args");
  }

=head1 DESCRIPTION

Represents an IRC message received by a L<Bot::Maverick> IRC bot, and contains
methods for parsing commands and sending replies.

=head1 ATTRIBUTES

=head2 network

L<Bot::Maverick::Network> object from which the message was received.

=head2 sender

L<Bot::Maverick::Sender> object representing the IRC user that sent the
message.

=head2 channel

L<Bot::Maverick::Channel> object representing the IRC channel in which the
message was sent, or C<undef> for private messages.

=head2 text

Unparsed message text.

=head2 command

L<Bot::Maverick::Command> object representing the command to be run, after being
parsed by L</"parse_command">.

=head2 args

Command arguments as a string, after being parsed by L</"parse_command">.

=head2 show_more

Count of additional results that can be retrieved by the C<more> command, to be
displayed in the reply.

=head2 private_reply_max

Maximum number of replies that will be sent for a private L</"reply">.

=head1 METHODS

=head2 args_list

Command arguments as a list, split on whitespace.

=head2 parse_command

Attempt to parse the message text for a command, returns C<undef> if no command
was found. Otherwise, the return value is true if a valid command was found, or
false if the command was ambiguous or disabled, in which case a reply will also
be generated to the sender.

=head2 reply

Reply to the message sender over the appropriate network. If the message was
sent in a channel, reply in the same channel addressing the sender. If the
message was sent privately, reply privately. Channel messages will be truncated
if exceeding the maximum message length; private messages will be split into
multiple messages up to L</"private_reply_max">.

=head2 reply_private

Reply to the message sender over the appropriate network as in L</"reply">, but
always privately.

=head2 reply_bare

Reply to the message sender over the appropriate network as in L</"reply">, but
without addressing the sender if replying in a channel.

=head1 BUGS

Report any issues on the public bugtracker.

=head1 AUTHOR

Dan Book, C<dbook@cpan.org>

=head1 COPYRIGHT AND LICENSE

Copyright 2015, Dan Book.

This library is free software; you may redistribute it and/or modify it under
the terms of the Artistic License version 2.0.

=head1 SEE ALSO

L<Bot::Maverick>, L<Bot::Maverick::Network>, L<Bot::Maverick::Sender>,
L<Bot::Maverick::Channel>, L<Bot::Maverick::Command>
