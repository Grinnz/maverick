package Bot::ZIRC::Plugin::Core;

use Bot::ZIRC::Access ':access';

use Moo;
extends 'Bot::ZIRC::Plugin';

has 'more_commands' => (
	is => 'ro',
	lazy => 1,
	default => sub { {} },
	init_arg => undef,
);

sub register {
	my ($self, $bot) = @_;
	
	$bot->add_command(
		name => 'help',
		help_text => 'This is the help command',
		usage_text => '[<command>]',
		on_run => sub {
			my ($network, $sender, $channel, $name) = @_;
			my ($help_text, $command);
			if (defined $name) {
				$command = $self->bot->get_command($name);
				if (defined $command) {
					$help_text = $command->help_text // 'No help text for command $name';
					$help_text .= '.' if $help_text =~ /\w\s*$/;
					$help_text .= ' Usage: $trigger$name';
					$help_text .= ' ' . $command->usage_text if defined $command->usage_text;
				} else {
					return $network->reply($sender, $channel, "No such command $name");
				}
			} else {
				$command = $self->bot->get_command('help');
				$help_text = 'Type $trigger$name <command> to get help with a specific command.';
			}
			$help_text = $command->parse_usage_text($network, $help_text);
			$network->reply($sender, $channel, $help_text);
		},
	);
	
	$bot->add_command(
		name => 'join',
		help_text => 'Join a channel',
		usage_text => '<channel> [<channel> ...]',
		required_access => ACCESS_BOT_ADMIN,
		on_run => sub {
			my ($network, $sender, $channel, @channels) = @_;
			return 'usage' unless @channels;
			$network->write(join => $_) for @channels;
		},
	);
	
	$bot->add_command(
		name => 'leave',
		help_text => 'Leave a channel',
		usage_text => '[<channel> ...] [<message>]',
		on_run => sub {
			my ($network, $sender, $channel, @channels) = @_;
			my $message = 'Leaving';
			$message = pop @channels if @channels and $channels[-1] !~ /^#/;
			return 'usage' unless $channel or @channels;
			if (@channels) {
				$sender->check_access(ACCESS_BOT_ADMIN, sub {
					my ($sender, $has_access) = @_;
					if ($has_access) {
						$sender->network->write(part => $_, ":$message") for @channels;
					} else {
						$sender->network->reply($sender, $channel,
							"You must be a bot administrator to run this command.");
					}
				});
			} else {
				$sender->check_access(ACCESS_CHANNEL_OP, $channel, sub {
					my ($sender, $has_access) = @_;
					if ($has_access) {
						$sender->network->write(part => $channel, ":$message");
					} else {
						$sender->network->reply($sender, $channel,
							"You must be a channel operator to run this command.");
					}
				});
			}
		},
	);
	
	$bot->add_hook_after_command(sub {
		my ($command, $network, $sender, $channel) = @_;
		return unless $command->has_on_more;
		my $channel_name = lc ($channel // $sender);
		$self->more_commands->{$network}{$channel_name} = lc $command->name;
	});
	
	$bot->add_command(
		name => 'more',
		help_text => 'Show more results',
		usage_text => '[<command>]',
		on_run => sub {
			my ($network, $sender, $channel, $command_name) = @_;
			my $channel_name = lc ($channel // $sender);
			$command_name //= $self->more_commands->{$network}{$channel_name};
			return $network->reply($sender, $channel, "No more to display") unless defined $command_name;
			my $command = $self->bot->get_command($command_name);
			return $network->reply($sender, $channel, "No more to display for $command_name")
				unless $command and $command->has_on_more;
			$self->more_commands->{$network}{$channel_name} = lc $command->name;
			$command->on_more->($network, $sender, $channel);
		},
	);
	
	$bot->add_command(
		name => 'nick',
		help_text => 'Change bot\'s nick',
		usage_text => '<nick>',
		on_run => sub {
			my ($network, $sender, $channel, $nick) = @_;
			return 'usage' unless defined $nick and length $nick;
			$network->config->set('irc', 'nick', $nick);
			$network->write(nick => $nick);
		},
		required_access => ACCESS_BOT_ADMIN,
	);
	
	$bot->add_command(
		name => 'quit',
		help_text => 'Quit IRC and shutdown',
		usage_text => '[<message>]',
		required_access => ACCESS_BOT_MASTER,
		on_run => sub {
			my ($network, $sender, $channel, @message) = @_;
			my $message = join ' ', @message;
			$message ||= 'Goodbye';
			$self->bot->stop($message);
		},
	);
	
	$bot->add_command(
		name => 'reload',
		help_text => 'Reload bot configuration',
		required_access => ACCESS_BOT_MASTER,
		on_run => sub {
			my ($network, $sender, $channel) = @_;
			$self->bot->reload;
			$network->reply($sender, $channel, "Reloaded configuration");
		},
	);
	
	$bot->add_command(
		name => 'say',
		help_text => 'Echo a message',
		usage_text => '<message>',
		required_access => ACCESS_CHANNEL_VOICE,
		strip_formatting => 0,
		tokenize => 0,
		on_run => sub {
			my ($network, $sender, $channel, $message) = @_;
			if ($message =~ s/^(#\w+)//) {
				my $in_channel = $1;
				return 'usage' unless length $message;
				$sender->check_access(ACCESS_BOT_ADMIN, sub {
					my ($sender, $has_access) = @_;
					if ($has_access) {
						$sender->network->write(privmsg => $in_channel, ":$message");
					} else {
						$sender->network->reply($sender, $channel,
							"You must be a bot administrator to run this command.");
					}
				});
			} else {
				return 'usage' unless length $message;
				$network->reply($sender, $channel, $message);
			}
		},
	);
	
	$bot->add_command(
		name => 'set',
		help_text => 'Get/set network or channel-specific bot configuration',
		usage_text => '[network|<channel>] <name> [<value>]',
		required_access => ACCESS_CHANNEL_OP,
		on_run => sub {
			my ($network, $sender, $channel, @args) = @_;
			my $scope = $channel;
			if (defined $args[0] and (lc $args[0] eq 'network' or $args[0] =~ /^#/)) {
				$scope = shift @args;
			}
			
			my ($name, $value) = @args;
			return 'usage' unless $name;
			my @required = lc $scope eq 'network' ? (ACCESS_BOT_ADMIN) : (ACCESS_CHANNEL_OP, $scope);
			$sender->check_access(@required, sub {
				my ($sender, $has_access) = @_;
				my $network = $sender->network;
				if ($has_access) {
					if (defined $value) {
						$network->config->set_channel($scope, $name, $value);
						$network->reply($sender, $channel, "Set $scope configuration option $name to $value");
					} else {
						my $value = $network->config->get_channel($scope, $name);
						my $set_str = defined $value ? "is set to $value" : "is not set";
						$network->reply($sender, $channel, "$scope configuration option $name $set_str");
					}
				} else {
					$network->reply($sender, $channel, "You must be an operator to run this command.");
				}
			});
		},
	);
}

1;

=head1 NAME

Bot::ZIRC::Plugin::Core - Core commands plugin for Bot::ZIRC

=head1 SYNOPSIS

 my $bot = Bot::ZIRC->new(
   plugins => { Core => 1 },
 );

=head1 DESCRIPTION

Adds commands for core functionality to a L<Bot::ZIRC> IRC bot. This plugin is
included by default unless disabled in the constructor.

=head1 COMMANDS

=head2 help

 !help set

Display the help and usage text for a command.

=head2 join

 !join #bots

Attempt to join a channel.

=head2 leave

 !leave
 !leave #bots

Leave a channel (default current channel).

=head2 more

 !more
 !more google

Display more results for a specified command (or the last command with C<more>
functionality).

=head2 nick

 !nick Somebot

Change the bot's configured nick for this network, and attempt to set the new
nick.

=head2 quit

 !quit Goodbye

Quit all networks with an optional quit message.

=head2 reload

 !reload

Reload configuration from files and reopen logs.

=head2 say

 !say To be, or not to be?

Echo a message. If the first argument is a channel name it will be said there.

=head2 set

 !set youtube_trigger 0
 !set network youtube_trigger 0
 !set #bots youtube_trigger 0

Set a network configuration option for either the whole network or a channel,
defaulting to the current channel.

=head1 BUGS

Report any issues on the public bugtracker.

=head1 AUTHOR

Dan Book, C<dbook@cpan.org>

=head1 COPYRIGHT AND LICENSE

Copyright 2015, Dan Book.

This library is free software; you may redistribute it and/or modify it under
the terms of the Artistic License version 2.0.

=head1 SEE ALSO

L<Bot::ZIRC>
