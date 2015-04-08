package Bot::ZIRC::Plugin::Spell;

use File::Spec;
use Text::Hunspell;

use Moo;
extends 'Bot::ZIRC::Plugin';

has 'dict_path' => (
	is => 'ro',
	lazy => 1,
	default => '/usr/share/myspell',
);

has 'dict_lang' => (
	is => 'ro',
	lazy => 1,
	default => 'en_US',
);

has 'dict' => (
	is => 'lazy',
	init_arg => undef,
);

sub _build_dict {
	my $self = shift;
	my $affix_path = File::Spec->catfile($self->dict_path, $self->dict_lang . '.aff');
	my $dict_path = File::Spec->catfile($self->dict_path, $self->dict_lang . '.dic');
	return Text::Hunspell->new($affix_path, $dict_path);
}

sub register {
	my ($self, $bot) = @_;
	
	$bot->add_command(
		name => 'spell',
		help_text => 'Check the spelling of a word',
		usage_text => '<word>',
		on_run => sub {
			my ($network, $sender, $channel, $word) = @_;
			return 'usage' unless defined $word and length $word;
			if ($self->dict->check($word)) {
				return $network->reply($sender, $channel, "$word is a word.");
			}
			my @suggestions = $self->dict->suggest($word);
			my $msg = "$word is not a word. Did you mean: ".join ' ', @suggestions;
			$network->reply($sender, $channel, $msg);
		},
	);
}

1;
