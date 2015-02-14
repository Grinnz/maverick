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
		on_run => sub {
			my ($self, $sender, $channel, $name) = @_;
			my $help_text;
			if (defined $name) {
				my $command = $self->bot->get_command($name);
				if (defined $command) {
					$help_text = $command->help_text // "No help text for command $name";
				} else {
					$help_text = "No such command $name";
				}
			} else {
				$help_text = $self->config->{foo}.'Type ${trigger}help <command> to get help with a specific command.';
			}
			$help_text = parse_help_text($self->bot, $self->irc, $help_text);
			$self->irc->write(privmsg => $channel // $sender, $help_text);
		},
		help_text => 'This is the help command. Usage: ${trigger}help [<command>]',
		config => { foo => 'bar' },
	);
	
	$bot->add_command(
		name => 'config',
		on_run => sub {
			my ($self, $sender, $channel, @args) = @_;
			my $scope = $channel;
			if (lc $args[0] eq 'global' or $args[0] =~ /^#/) {
				$scope = shift @args;
				undef $scope if lc $scope eq 'global';
			}
			
			my ($name, $value) = @args;
			if (defined $value) {
				$self->bot->set_config($scope, $name, $value);
				my $scope_str = $scope // 'global';
				$self->irc->write(privmsg => $channel // $sender, "Set $scope_str configuration option $name to $value");
			} else {
				my $value = $self->bot->get_config($scope, $name);
				my $scope_str = $scope // 'Global';
				my $set_str = defined $value ? "is set to $value" : "is not set";
				$self->irc->write(privmsg => $channel // $sender, "$scope configuration option $name $set_str");
			}
		},
		help_text => 'Get/set global or channel-specific bot configuration. ' .
			'Usage: ${trigger}config [global|<channel>] <name> [<value>]',
		required_access => ACCESS_BOT_ADMIN,
	);
	
	$bot->add_command(
		name => 'command',
		on_run => sub {
			my ($self, $sender, $channel, @args) = @_;
			my $scope = $channel;
			if (lc $args[0] eq 'global' or $args[0] =~ /^#/) {
				$scope = shift @args;
				undef $scope if lc $scope eq 'global';
			}
			
			my ($cmd_name, $name, $value) = @args;
			my $command = $self->bot->get_command($cmd_name);
			return $irc->write(privmsg => $channel // $sender, "No such command $cmd_name") unless defined $command;
			if (defined $value) {
				$command->set_config($scope, $name, $value);
				my $scope_str = $scope // 'global';
				$self->irc->write(privmsg => $channel // $sender, "Set $scope_str '$cmd_name' configuration option $name to $value");
			} else {
				my $value = $command->get_config($scope, $name);
				my $scope_str = $scope // 'Global';
				my $set_str = defined $value ? "is set to $value" : "is not set";
				$self->irc->write(privmsg => $channel // $sender, "$scope '$cmd_name' configuration option $name $set_str");
			}
		},
		help_test => 'Get/set global or channel-specific command configuration. ' .
			'Usage: ${trigger}command [global|<channel>] <command> <name> [<value>]',
		required_access => ACCESS_BOT_ADMIN,
	);
}

sub parse_help_text {
	my ($bot, $irc, $text) = @_;
	my $trigger = $bot->config->{commands}{trigger} || $irc->nick . ': ';
	$text =~ s/\$(?:{trigger}|trigger\b)/$trigger/g;
	return $text;
}

1;

