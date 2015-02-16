package Bot::ZIRC::Plugin::Default;

use Bot::ZIRC::Access;

use Moo;
use warnings NONFATAL => 'all';
use namespace::clean;

with 'Bot::ZIRC::Plugin';

sub parse_help_text {
	my ($network, $command, $text) = @_;
	my $trigger = $network->config->get('commands','trigger') || $network->nick . ': ';
	my $name = $command->name;
	$text =~ s/\$(?:{trigger}|trigger\b)/$trigger/g;
	$text =~ s/\$(?:{name}|name\b)/$name/g;
	return $text;
}

sub register {
	my ($self, $bot) = @_;
	
	$bot->add_command(
		name => 'help',
		help_text => 'This is the help command. Usage: ${trigger}$name [<command>]',
		on_run => sub {
			my ($self, $network, $sender, $channel, $name) = @_;
			my $help_text;
			my $command = $self;
			if (defined $name) {
				$command = $self->bot->get_command($name);
				if (defined $command) {
					$help_text = $command->help_text // 'No help text for command $name';
				} else {
					$help_text = "No such command $name";
				}
			} else {
				$help_text = 'Type ${trigger}$name <command> to get help with a specific command.'x35;
			}
			$help_text = parse_help_text($network, $command, $help_text);
			$network->reply($sender, $channel, $help_text);
		},
	);
	
	$bot->add_command(
		name => 'quit',
		help_text => 'Tell the bot to quit. Usage: ${trigger}$name [<message>]',
		required_access => ACCESS_BOT_MASTER,
		on_run => sub {
			my ($self, $network, $sender, $channel, $message) = @_;
			$message //= 'Goodbye';
			$self->bot->stop($message);
		},
	);
	
	$bot->add_command(
		name => 'reload',
		help_text => 'Reload bot configuration. Usage: ${trigger}$name',
		required_access => ACCESS_BOT_MASTER,
		on_run => sub {
			my ($self, $network, $sender, $channel) = @_;
			$self->bot->reload;
			$network->reply($sender, $channel, "Reloaded configuration");
		},
	);
	
	$bot->add_command(
		name => 'set',
		help_text => 'Get/set network or channel-specific bot configuration. ' .
			'Usage: ${trigger}$name [network|<channel>] <name> [<value>]',
		required_access => ACCESS_BOT_ADMIN,
		on_run => sub {
			my ($self, $network, $sender, $channel, @args) = @_;
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

