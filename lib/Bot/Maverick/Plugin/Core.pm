package Bot::Maverick::Plugin::Core;

use Bot::Maverick::Access ':access';

use Moo;
with 'Bot::Maverick::Plugin';

our $VERSION = '0.50';

has 'more_commands' => (
	is => 'ro',
	lazy => 1,
	default => sub { {} },
	init_arg => undef,
);

sub register {
	my ($self, $bot) = @_;
	
	$bot->add_helper(_core_more_commands => sub { $self->more_commands });
	
	$bot->add_command(
		name => 'help',
		help_text => 'This is the help command',
		usage_text => '[<command>]',
		on_run => sub {
			my $m = shift;
			my ($name) = $m->args_list;
			my ($help_text, $command);
			if (defined $name) {
				$command = $m->bot->get_command($name);
				if (defined $command) {
					$help_text = $command->help_text // 'No help text for command $name';
					$help_text .= '.' if $help_text =~ /\w\s*$/;
					$help_text .= ' Usage: $trigger$name';
					$help_text .= ' ' . $command->usage_text if defined $command->usage_text;
				} else {
					return $m->reply("No such command $name");
				}
			} else {
				$command = $m->command;
				$help_text = 'Type $trigger$name <command> to get help with a specific command.';
			}
			$help_text = $command->parse_usage_text($m->network, $help_text);
			$m->reply($help_text);
		},
	);
	
	$bot->add_command(
		name => 'join',
		help_text => 'Join a channel',
		usage_text => '<channel> [<channel> ...]',
		required_access => ACCESS_BOT_ADMIN,
		on_run => sub {
			my $m = shift;
			my @channels = $m->args_list;
			return 'usage' unless @channels;
			$m->write(join => $_) for @channels;
		},
	);
	
	$bot->add_command(
		name => 'leave',
		help_text => 'Leave a channel',
		usage_text => '[<channel> ...] [<message>]',
		on_run => sub {
			my $m = shift;
			my @channels = $m->args_list;
			my $part_msg = 'Leaving';
			$part_msg = pop @channels if @channels and $channels[-1] !~ /^#/;
			if (@channels) {
				$m->check_access(ACCESS_BOT_ADMIN, sub {
					my ($sender, $has_access) = @_;
					if ($has_access) {
						$m->write(part => $_, ":$part_msg") for @channels;
					} else {
						$m->reply("You must be a bot administrator to run this command.");
					}
				});
			} elsif ($m->channel) {
				$m->check_access(ACCESS_CHANNEL_OP, $m->channel, sub {
					my ($sender, $has_access) = @_;
					if ($has_access) {
						$m->write(part => $m->channel, ":$part_msg");
					} else {
						$m->reply("You must be a channel operator to run this command.");
					}
				});
			} else {
				return 'usage';
			}
		},
	);
	
	$bot->on(after_command => sub {
		my ($bot, $m) = @_;
		return unless $m->command->has_on_more;
		my $channel_name = lc ($m->channel // $m->sender);
		$m->bot->_core_more_commands->{$m->network}{$channel_name} = lc $m->command->name;
	});
	
	$bot->add_command(
		name => 'more',
		help_text => 'Show more results',
		usage_text => '[<command>]',
		on_run => sub {
			my $m = shift;
			my ($command_name) = $m->args_list;
			my $channel_name = lc ($m->channel // $m->sender);
			$command_name //= $m->bot->_core_more_commands->{$m->network}{$channel_name};
			return $m->reply("No more to display") unless defined $command_name;
			my $command = $m->bot->get_command($command_name);
			if (!defined $command and $m->config->param('commands','prefixes')) {
				my $cmds = $m->bot->get_commands_by_prefix($command_name);
				foreach my $name (@$cmds) {
					$command = $m->bot->get_command($cmds->[0]);
					last if $command->has_on_more;
				}
			}
			return $m->reply("No more to display for $command_name")
				unless $command and $command->has_on_more;
			$m->bot->_core_more_commands->{$m->network}{$channel_name} = lc $command->name;
			return $command->on_more->($m);
		},
	);
	
	$bot->add_command(
		name => 'nick',
		help_text => 'Change bot\'s nick',
		usage_text => '<nick>',
		required_access => ACCESS_BOT_ADMIN,
		on_run => sub {
			my $m = shift;
			my ($nick) = $m->args_list;
			return 'usage' unless defined $nick and length $nick;
			$m->config->param('irc', 'nick', $nick);
			$m->write(nick => $nick);
		},
	);
	
	$bot->add_command(
		name => 'quit',
		help_text => 'Quit IRC and shutdown',
		usage_text => '[<message>]',
		required_access => ACCESS_BOT_MASTER,
		on_run => sub {
			my $m = shift;
			my $quit_msg = $m->args;
			$quit_msg ||= 'Goodbye';
			$m->bot->stop($quit_msg);
		},
	);
	
	$bot->add_command(
		name => 'reload',
		help_text => 'Reload bot configuration',
		required_access => ACCESS_BOT_MASTER,
		on_run => sub {
			my $m = shift;
			$m->bot->reload;
			$m->reply("Reloaded configuration");
		},
	);
	
	$bot->add_command(
		name => 'set',
		help_text => 'Get/set network or channel-specific bot configuration',
		usage_text => '[network|<channel>] <name> [<value>]',
		required_access => ACCESS_CHANNEL_OP,
		on_run => sub {
			my $m = shift;
			my @args = $m->args_list;
			my $scope = $m->channel;
			if (defined $args[0] and (lc $args[0] eq 'network' or $args[0] =~ /^#/)) {
				$scope = shift @args;
			}
			
			my ($name, $value) = @args;
			return 'usage' unless $name;
			my @required = lc $scope eq 'network' ? (ACCESS_BOT_ADMIN) : (ACCESS_CHANNEL_OP, $scope);
			$m->check_access(@required, sub {
				my ($sender, $has_access) = @_;
				if ($has_access) {
					if (defined $value) {
						$m->config->channel_param($scope, $name, $value);
						$m->reply("Set $scope configuration option $name to $value");
					} else {
						my $value = $m->config->channel_param($scope, $name);
						my $set_str = defined $value ? "is set to $value" : "is not set";
						$m->reply("$scope configuration option $name $set_str");
					}
				} else {
					$m->reply("You must be an operator to run this command.");
				}
			});
		},
	);
	
	$bot->add_command(
		name => 'version',
		help_text => 'Return version information',
		on_run => sub {
			my $m = shift;
			my $name = $m->bot->name;
			my $bot_version = $m->bot->bot_version;
			my $perl_version = $^V;
			$m->reply("I am $name, running Bot::Maverick $bot_version on perl $perl_version");
		},
	);
}

1;

=head1 NAME

Bot::Maverick::Plugin::Core - Core commands plugin for Maverick

=head1 SYNOPSIS

 my $bot = Bot::Maverick->new(
   plugins => { Core => 1 },
 );

=head1 DESCRIPTION

Adds commands for core functionality to a L<Bot::Maverick> IRC bot. This plugin
is included by default unless disabled in the constructor.

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

=head2 set

 !set youtube_trigger 0
 !set network youtube_trigger 0
 !set #bots youtube_trigger 0

Set a network configuration option for either the whole network or a channel,
defaulting to the current channel.

=head2 version

 !version

Respond with the bot name, module version, and perl version.

=head1 BUGS

Report any issues on the public bugtracker.

=head1 AUTHOR

Dan Book, C<dbook@cpan.org>

=head1 COPYRIGHT AND LICENSE

Copyright 2015, Dan Book.

This library is free software; you may redistribute it and/or modify it under
the terms of the Artistic License version 2.0.

=head1 SEE ALSO

L<Bot::Maverick>
