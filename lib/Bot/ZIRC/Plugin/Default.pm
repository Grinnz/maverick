package Bot::ZIRC::Plugin::Default;

use Bot::ZIRC::Access;
use Bot::ZIRC::Command;

use Moo;
use warnings NONFATAL => 'all';
use namespace::clean;

with 'Bot::ZIRC::Plugin';

sub register {
	my ($self, $bot) = @_;
	
	$bot->add_command(Bot::ZIRC::Command->new(
		name => 'help',
		on_run => sub {
			my ($bot, $irc, $sender, $channel, $name) = @_;
			my $help_text;
			if (defined $name) {
				my $command = $bot->get_command($name);
				if (defined $command) {
					$help_text = $command->help_text // "No help text for command $name";
				} else {
					$help_text = "No such command $name";
				}
			} else {
				$help_text = help_text_global();
			}
			$help_text = parse_help_text($bot, $irc, $help_text);
			$irc->write(privmsg => $channel // $sender, $help_text);
		},
		help_text => 'This is the help command. Type ${trigger}help <command> to get help with a specific command.',
	));
}

sub parse_help_text {
	my ($bot, $irc, $text) = @_;
	my $trigger = $bot->config->{commands}{trigger} || $irc->nick . ': ';
	$text =~ s/\$(?:{trigger}|trigger\b)/$trigger/g;
	return $text;
}

sub help_text_global {
	'Type ${trigger}help <command> to get help with a specific command.';
}

1;

