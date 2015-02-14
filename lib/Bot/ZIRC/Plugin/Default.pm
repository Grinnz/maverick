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
		help_text => 'This is the help command. Type ${trigger}help <command> to get help with a specific command.',
		config => { foo => 'bar' },
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

