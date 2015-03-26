package Bot::ZIRC::Plugin::Pick;

use Moo;
extends 'Bot::ZIRC::Plugin';

sub register {
	my ($self, $bot) = @_;
	
	$bot->add_command(
		name => 'pick',
		help_text => 'Pick a random item from a list',
		usage_text => '<item>[, <item>...]',
		tokenize => 0,
		on_run => sub {
			my ($network, $sender, $channel, $items) = @_;
			return 'usage' unless length $items;
			my @items = split /\s*,\s*/, $items;
			my $choice = 1+int rand @items;
			my $item = $items[$choice-1];
			$network->reply($sender, $channel, "$choice: $item");
		},
	);
}

1;
