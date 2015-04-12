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

has '_dicts' => (
	is => 'ro',
	lazy => 1,
	default => sub { {} },
	init_arg => undef,
);

sub spell_dict {
	my ($self, $lang) = @_;
	return $self->_dicts->{$lang} //= $self->_build_dict($lang);
}

sub _build_dict {
	my ($self, $lang) = @_;
	my $affix_path = File::Spec->catfile($self->dict_path, "$lang.aff");
	my $dict_path = File::Spec->catfile($self->dict_path, "$lang.dic");
	return undef unless -f $affix_path and -f $dict_path;
	return Text::Hunspell->new($affix_path, $dict_path);
}

sub register {
	my ($self, $bot) = @_;
	
	$bot->add_plugin_method($self, 'spell_dict');
	
	$bot->add_command(
		name => 'spell',
		help_text => 'Check the spelling of a word',
		usage_text => '<word> [<dict>]',
		on_run => sub {
			my ($network, $sender, $channel, $word, $lang) = @_;
			return 'usage' unless defined $word and length $word;
			$lang //= $self->default_lang;
			my $dict = $self->spell_dict($lang);
			return $network->reply($sender, $channel, "Dictionary for $lang not found") unless defined $dict;
			return $network->reply($sender, $channel, "$word is a word.") if $dict->check($word);
			my @suggestions = $dict->suggest($word);
			my $msg = "$word is not a word. Did you mean: ".join ' ', @suggestions;
			$network->reply($sender, $channel, $msg);
		},
	);
}

1;

=head1 NAME

Bot::ZIRC::Plugin::Spell - Spell-check plugin for Bot::ZIRC

=head1 SYNOPSIS

 my $bot = Bot::ZIRC->new(
   plugins => { Spell => 1 },
 );

=head1 DESCRIPTION

Adds plugin method and command for spell-checking to a L<Bot::ZIRC> IRC bot.

This plugin requires L<hunspell|http://hunspell.sourceforge.net/> to be
installed, as well as hunspell dictionaries for any language you wish to use
for spell-checking.

=head1 ATTRIBUTES

=head2 dict_path

Path to dictionaries, defaults to C</usr/share/myspell>.

=head2 default_lang

Default dictionary language, defaults to C<en_US>.

=head1 METHODS

=head2 spell_dict

 my $dict = $bot->spell_dict('fr_FR');

Retrieves the dictionary for a specified language as a L<Text::Hunspell>
object.

=head1 COMMANDS

=head2 spell

 !spell rythym
 !spell theater en_GB

Check the spelling of a word, optionally specifying the dictionary to use.
Display suggestions if the word is spelled incorrectly.

=head1 BUGS

Report any issues on the public bugtracker.

=head1 AUTHOR

Dan Book, C<dbook@cpan.org>

=head1 COPYRIGHT AND LICENSE

Copyright 2015, Dan Book.

This library is free software; you may redistribute it and/or modify it under
the terms of the Artistic License version 2.0.

=head1 SEE ALSO

L<Bot::ZIRC>, L<Text::Hunspell>
