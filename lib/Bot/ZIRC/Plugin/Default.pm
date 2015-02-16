package Bot::ZIRC::Plugin::Default;

use Bot::ZIRC::Access;

use Moo;
use warnings NONFATAL => 'all';
use namespace::clean;

with 'Bot::ZIRC::Plugin';

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
					$help_text = $command->help_text // 'No help text for command $name.';
					my $usage_text = $command->usage_text;
					$help_text .= '.' if $help_text =~ /\w\s*$/;
					$help_text .= ' Usage: ${trigger}$name';
					$help_text .= ' ' . $usage_text if defined $usage_text;
				} else {
					return $network->reply($sender, $channel, "No such command $name");
				}
			} else {
				$command = $network->bot->get_command('help');
				$help_text = 'Type ${trigger}$name <command> to get help with a specific command.';
			}
			$help_text = $command->parse_usage_text($network, $help_text);
			$network->reply($sender, $channel, $help_text);
		},
	);
	
	$bot->add_command(
		name => 'quit',
		help_text => 'Tell the bot to quit',
		usage_text => '[<message>]',
		required_access => ACCESS_BOT_MASTER,
		on_run => sub {
			my ($network, $sender, $channel, $message) = @_;
			$message //= 'Goodbye';
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
		name => 'set',
		help_text => 'Get/set network or channel-specific bot configuration',
		usage_text => '[network|<channel>] <name> [<value>]',
		required_access => ACCESS_BOT_ADMIN,
		on_run => sub {
			my ($network, $sender, $channel, @args) = @_;
			my $scope = $channel;
			if (lc $args[0] eq 'network' or $args[0] =~ /^#/) {
				$scope = shift @args;
			}
			
			my ($name, $value) = @args;
			if (defined $value) {
				$network->config->set_channel($scope, $name, $value);
				$network->reply($sender, $channel, "Set $scope configuration option $name to $value");
			} else {
				my $value = $network->config->get_channel($scope, $name);
				my $set_str = defined $value ? "is set to $value" : "is not set";
				$network->reply($sender, $channel, "$scope configuration option $name $set_str");
			}
		},
	);
}

1;
