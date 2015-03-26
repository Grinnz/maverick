package Bot::ZIRC::Plugin::Calc;

use Math::Calc::Parser 'calc';

use Moo;
extends 'Bot::ZIRC::Plugin';

sub register {
	my ($self, $bot) = @_;
	
	$bot->add_command(
		name => 'calc',
		help_text => 'Calculate the result of a mathematical expression',
		usage_text => '<expression>',
		tokenize => 0,
		on_run => sub {
			my ($network, $sender, $channel, $expr) = @_;
			return 'usage' unless length $expr;
			my $result = Math::Calc::Parser->try_evaluate($expr);
			return $network->reply($sender, $channel, "Error evaluating expression: $Math::Calc::Parser::ERROR")
				unless defined $result;
			$network->reply($sender, $channel, "Result: $result");
		},
	);
}

1;
