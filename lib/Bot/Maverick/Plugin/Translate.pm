package Bot::Maverick::Plugin::Translate;

use Carp 'croak';
use Mojo::URL;
use Time::Seconds;

use Moo;
with 'Bot::Maverick::Plugin';

our $VERSION = '0.50';

use constant TRANSLATE_TOKEN_ENDPOINT => 'https://api.cognitive.microsoft.com/sts/v1.0/issueToken';
use constant TRANSLATE_TOKEN_EXPIRE => 8 * ONE_MINUTE; # to be safe, expiration is 10 minutes
use constant TRANSLATE_API_ENDPOINT => 'https://api.cognitive.microsofttranslator.com';
use constant TRANSLATE_SUBSCRIPTION_KEY_MISSING =>
	"Translate plugin requires configuration option 'microsoft_translator_subscription_key' in section 'apis'\n" .
	"See https://docs.microsoft.com/en-us/azure/cognitive-services/translator/translator-how-to-signup " .
	"for more information on obtaining a Microsoft Translator subscription key.\n";

has 'subscription_key' => (
	is => 'rw',
);

has '_access_token' => (
	is => 'rw',
	predicate => 1,
	clearer => 1,
	init_arg => undef,
);

has '_access_token_expire' => (
	is => 'rw',
	predicate => 1,
	clearer => 1,
	init_arg => undef,
);

sub _retrieve_access_token {
	my ($self) = @_;
	if ($self->_has_access_token_expire and $self->_access_token_expire <= time) {
		$self->_clear_access_token;
		$self->_clear_access_token_expire;
	}
	return $self->bot->new_future->done($self->_access_token) if $self->_has_access_token;
	
	die TRANSLATE_SUBSCRIPTION_KEY_MISSING unless defined $self->subscription_key;
	return $self->bot->ua_request(post => TRANSLATE_TOKEN_ENDPOINT, {'Ocp-Apim-Subscription-Key' => $self->subscription_key})->transform(done => sub {
		my $token = shift->text;
		$self->_access_token_expire(time + TRANSLATE_TOKEN_EXPIRE);
		$self->_access_token($token);
		return $self->_access_token;
	});
}

has '_language_codes_built' => (
	is => 'rw',
	lazy => 1,
	default => 0,
	init_arg => undef,
);

has '_languages_by_code' => (
	is => 'rw',
	lazy => 1,
	default => sub { {} },
	init_arg => undef,
);

has '_languages_by_name' => (
	is => 'ro',
	lazy => 1,
	default => sub { {} },
	init_arg => undef,
);

sub _build_language_codes {
	my ($self) = @_;
	return $self->bot->new_future->done if $self->_language_codes_built;
	$self->_language_codes_built(1);
	
	my $url = Mojo::URL->new(TRANSLATE_API_ENDPOINT)->path('languages')->query('api-version' => '3.0', scope => 'translation');
	return $self->bot->ua_request(get => $url, {'Accept-Language' => 'en'})->on_done(sub {
		my $res = shift;
		my $langs = $res->json->{translation} // {};
		foreach my $lang (sort keys %$langs) {
			my $name = $langs->{$lang}{name};
			my $native_name = $langs->{$lang}{nativeName};
			$self->_languages_by_code->{$lang} = $name;
			my @words = (split(' ', $name), split(' ', $native_name));
			$self->_languages_by_name->{lc $_} //= $lang for $lang, $name, $native_name, @words;
		}
		$self->_languages_by_name->{klingon} = $self->_languages_by_name->{'klingon (latin)'};
	})->on_fail(sub { $self->_language_codes_built(0) });
}

sub register {
	my ($self, $bot) = @_;
	$self->subscription_key($bot->config->param('apis','microsoft_translator_subscription_key'))
		unless defined $self->subscription_key;
	die TRANSLATE_SUBSCRIPTION_KEY_MISSING unless defined $self->subscription_key;
	
	$bot->add_helper(microsoft_translator_subscription_key => sub { $self->subscription_key });
	$bot->add_helper(_microsoft_access_token => sub { $self->_retrieve_access_token });
	$bot->add_helper(_translate_build_language_codes => sub { $self->_build_language_codes });
	$bot->add_helper(_translate_languages_by_code => sub { $self->_languages_by_code });
	$bot->add_helper(_translate_languages_by_name => sub { $self->_languages_by_name });
	$bot->add_helper(detect_language => \&_detect_language);
	$bot->add_helper(translate_language_code => \&_translate_language_code);
	$bot->add_helper(translate_language_name => \&_translate_language_name);
	$bot->add_helper(translate_text => \&_translate_text);
	
	$bot->add_command(
		name => 'translate',
		help_text => 'Translate text from one language to another (default: from detected language to English)',
		usage_text => '["]<text>["] [from <language>] [to <language>]',
		on_run => sub {
			my $m = shift;
			my $args = $m->args;
			
			my ($text, $from, $to);
			if ($args =~ s/\s+from\s+([^"]+?)(?:\s+to\s+([^"]+))?$//i) {
				$text = $args;
				$from = $1;
				$to = $2;
			} elsif ($args =~ s/\s+to\s+([^"]+?)(?:\s+from\s+([^"]+))?$//i) {
				$text = $args;
				$to = $1;
				$from = $2;
			} else {
				$text = $args;
			}
			
			$text =~ s/^\s*"\s*//;
			$text =~ s/\s*"\s*$//;
			return 'usage' unless length $text;
			
			my $future;
			undef $from unless length $from;
			$to = 'en' unless length $to;
			$m->bot->translate_text($text, $from, $to)->on_done(sub {
				my ($translated, $detected) = @_;
				$from = $m->bot->translate_language_name($detected // $from);
				$to = $m->bot->translate_language_name($to);
				$m->reply("Translated $from => $to: $translated");
			})->on_fail(sub { $m->reply("Error translating text: $_[0]") });
		},
	);
}

sub _detect_language {
	my ($bot, $text) = @_;
	croak 'Undefined text to detect' unless defined $text;
	
	return $bot->_microsoft_access_token->then(sub {
		my $token = shift;
		my $url = Mojo::URL->new(TRANSLATE_API_ENDPOINT)->path('detect')->query('api-version' => '3.0');
		return $bot->ua_request(post => $url, {Authorization => "Bearer $token"}, json => [{Text => $text}]);
	})->transform(done => sub { shift->json->[0]{language} });
}

sub _translate_language_code {
	my ($bot, $lang) = @_;
	croak 'Undefined language' unless defined $lang;
	unless (exists $bot->_translate_languages_by_code->{$lang}) {
		$lang = $bot->_translate_languages_by_name->{lc $lang};
		return undef unless defined $lang and exists $bot->_translate_languages_by_code->{$lang};
	}
	return $lang;
}

sub _translate_language_name {
	my ($bot, $lang) = @_;
	croak 'Undefined language' unless defined $lang;
	unless (exists $bot->_translate_languages_by_code->{$lang}) {
		$lang = $bot->_translate_languages_by_name->{lc $lang};
		return undef unless defined $lang and exists $bot->_translate_languages_by_code->{$lang};
	}
	return $bot->_translate_languages_by_code->{$lang};
}

sub _translate_text {
	my ($bot, $text, $from, $to) = @_;
	croak 'Undefined text to translate' unless defined $text;
	return $bot->_translate_build_language_codes->then(sub {
		return $bot->_microsoft_access_token;
	})->then(sub {
		my $token = shift;
		my %query = ('api-version' => '3.0', textType => 'plain');
		if (defined $from) {
			$query{from} = $bot->translate_language_code($from)
				// return $bot->new_future->fail("Unknown from language $from");
		}
		$query{to} = $bot->translate_language_code($to)
			// return $bot->new_future->fail("Unknown to language $to");
		my $url = Mojo::URL->new(TRANSLATE_API_ENDPOINT)->path('translate')->query(%query);
		return $bot->ua_request(post => $url, {Authorization => "Bearer $token"}, json => [{Text => $text}]);
	})->transform(done => sub {
		my $result = shift->json->[0];
		my $detected = $result->{detectedLanguage} // {};
		return ($result->{translations}[0]{text}, $detected->{language});
	});
}

1;

=head1 NAME

Bot::Maverick::Plugin::Translate - Language translation plugin for Maverick

=head1 SYNOPSIS

 my $bot = Bot::Maverick->new(
   plugins => { Translate => 1 },
 );
 
 # Standalone usage
 my $translate = Bot::Maverick::Plugin::Translate->new(subscription_key => $subscription_key);
 my $from = $translate->detect_language($text)->get;
 my $translated = $translate->translate_text($text, $from, $to)->get;

=head1 DESCRIPTION

Adds helper methods and commands for translating text to a L<Bot::Maverick> IRC
bot.

This plugin requires a Microsoft Translator subscription key, configured as
C<microsoft_translator_subscription_key> in the C<apis> section. See
L<https://docs.microsoft.com/en-us/azure/cognitive-services/translator/translator-how-to-signup>
for information on obtaining a subscription key.

=head1 ATTRIBUTES

=head2 subscription_key

Microsoft Translator subscription key, defaults to value of configuration
option C<microsoft_translator_subscription_key> in section C<apis>.

=head1 METHODS

=head2 detect_language

 my $language_code = $bot->detect_language($text)->get;
 my $future = $bot->detect_language($text)->on_done(sub {
   my $language_code = shift;
 })->on_fail(sub { $m->reply("Error detecting language: $_[0]") });

Attempt to detect the language of a text string. Returns a L<Future::Mojo> with
the language code.

=head2 translate_language_code

 my $language_code = $bot->translate_language_code($language_name);

Returns the language code for a given language name or code, or undef if the
language is unknown.

=head2 translate_language_name

 my $language_name = $bot->translate_language_name($language_code);

Returns the language name for a given language name or code, or undef if the
language is unknown.

=head2 translate_text

 my $translated = $bot->translate_text($text, $from, $to)->get;
 my $future = $bot->translate_text($text, $from, $to)->on_done(sub {
   my ($translated, $detected) = @_;
 })->on_fail(sub { $m->reply("Error translating text: $_[0]") });

Attempt to translate a text string from one language to another. Attempts to
detect the language of the text string if C<$from> is undefined. Returns a
L<Future::Mojo> with the translated text, and the detected language code if
C<$from> was not defined.

=head1 COMMANDS

=head2 translate

 !translate tengo un gato en mis pantalones
 !translate a from spanish to german
 !translate "bagels from france" to japanese

Attempt to translate text, with optional from and to languages. Use quotes
to avoid ambiguity if the string contains the words C<from> or C<to>. From
language defaults to auto-detect, and to language defaults to English.

=head1 BUGS

Report any issues on the public bugtracker.

=head1 AUTHOR

Dan Book, C<dbook@cpan.org>

=head1 COPYRIGHT AND LICENSE

Copyright 2015, Dan Book.

This library is free software; you may redistribute it and/or modify it under
the terms of the Artistic License version 2.0.

=head1 SEE ALSO

L<Bot::Maverick>
