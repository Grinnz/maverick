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

has 'default_lang' => (
	is => 'ro',
	lazy => 1,
	default => 'en_US',
);

has 'dicts' => (
	is => 'ro',
	lazy => 1,
	default => sub { {} },
	init_arg => undef,
);

sub _build_dict {
	my ($self, $lang) = @_;
	my $affix_path = File::Spec->catfile($self->dict_path, "$lang.aff");
	my $dict_path = File::Spec->catfile($self->dict_path, "$lang.dic");
	return undef unless -f $affix_path and -f $dict_path;
	return Text::Hunspell->new($affix_path, $dict_path);
}

sub register {
	my ($self, $bot) = @_;
	
	$bot->add_command(
		name => 'spell',
		help_text => 'Check the spelling of a word',
		usage_text => '<word> [<dict>]',
		on_run => sub {
			my ($network, $sender, $channel, $word, $lang) = @_;
			return 'usage' unless defined $word and length $word;
			$lang //= $self->default_lang;
			my $dict = $self->dicts->{$lang} //= $self->_build_dict($lang);
			return $network->reply($sender, $channel, "Unknown language $lang") unless defined $dict;
			return $network->reply($sender, $channel, "$word is a word.") if $dict->check($word);
			my @suggestions = $dict->suggest($word);
			my $msg = "$word is not a word. Did you mean: ".join ' ', @suggestions;
			$network->reply($sender, $channel, $msg);
		},
	);
}

1;
