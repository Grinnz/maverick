package Bot::ZIRC::Plugin::Core;

use Bot::ZIRC::Access;

use Moo 2;
use namespace::clean;

with 'Bot::ZIRC::Plugin';

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
				$command = $network->bot->get_command($name);
				if (defined $command) {
					$help_text = $command->help_text // 'No help text for command $name';
					$help_text .= '.' if $help_text =~ /\w\s*$/;
					$help_text .= ' Usage: $trigger$name';
					$help_text .= ' ' . $command->usage_text if defined $command->usage_text;
				} else {
					return $network->reply($sender, $channel, "No such command $name");
				}
			} else {
				$command = $network->bot->get_command('help');
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
						$sender->network->write(part => $_, $message) for @channels;
					} else {
						$sender->network->reply($sender, $channel,
							"You must be a bot administrator to run this command.");
					}
				});
			} else {
				$sender->check_access(ACCESS_CHANNEL_OP, $channel, sub {
					my ($sender, $has_access) = @_;
					if ($has_access) {
						$sender->network->write(part => $channel, $message);
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
		on_run => sub {
			my ($network, $sender, $channel, $command_name) = @_;
			my $channel_name = lc ($channel // $sender);
			$command_name //= $self->more_commands->{$network}{$channel_name};
			return $network->reply($sender, $channel, "No more to display") unless defined $command_name;
			my $command = $network->bot->get_command($command_name);
			return $network->reply($sender, $channel, "No more to display for $command_name")
				unless $command and $command->has_on_more;
			$command->on_more->($network, $sender, $channel);
		},
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
			$network->bot->stop($message);
		},
	);
	
	$bot->add_command(
		name => 'reload',
		help_text => 'Reload bot configuration',
		required_access => ACCESS_BOT_MASTER,
		on_run => sub {
			my ($network, $sender, $channel) = @_;
			$network->bot->reload;
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
						$sender->network->write(privmsg => $in_channel, $message);
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
