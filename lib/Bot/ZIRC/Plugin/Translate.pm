package Bot::ZIRC::Plugin::Translate;

use Carp 'croak';
use Mojo::IOLoop;
use Mojo::URL;

use Moo;
extends 'Bot::ZIRC::Plugin';

use constant MICROSOFT_OAUTH_ENDPOINT => 'https://datamarket.accesscontrol.windows.net/v2/OAuth2-13/';
use constant MICROSOFT_ARRAY_SCHEMA => 'http://schemas.microsoft.com/2003/10/Serialization/Arrays';
use constant XML_SCHEMA_INSTANCE => 'http://www.w3.org/2001/XMLSchema-instance';
use constant TRANSLATE_OAUTH_SCOPE => 'http://api.microsofttranslator.com';
use constant TRANSLATE_API_ENDPOINT => 'http://api.microsofttranslator.com/v2/Http.svc/';
use constant MICROSOFT_API_KEY_MISSING => 
	"Translate plugin requires configuration options 'microsoft_client_id' and 'microsoft_client_secret' in section 'apis'\n" .
	"See http://blogs.msdn.com/b/translation/p/gettingstarted1.aspx " .
	"for more information on obtaining a Microsoft Client ID and Client secret.\n";

has 'client_id' => (
	is => 'rw',
);

has 'client_secret' => (
	is => 'rw',
);

has '_access_token' => (
	is => 'rw',
	lazy => 1,
	builder => 1,
	clearer => 1,
	init_arg => undef,
);

has '_access_token_expire' => (
	is => 'rw',
	predicate => 1,
	clearer => 1,
	init_arg => undef,
);

sub _build__access_token {
	my $self = shift;
	die MICROSOFT_API_KEY_MISSING unless defined $self->client_id and defined $self->client_secret;
	
	my $url = Mojo::URL->new(MICROSOFT_OAUTH_ENDPOINT);
	my %form = (
		client_id => $self->client_id,
		client_secret => $self->client_secret,
		scope => TRANSLATE_OAUTH_SCOPE,
		grant_type => 'client_credentials'
	);
	my $tx = $self->ua->post($url, form => \%form);
	die $self->ua_error($tx->error) if $tx->error;
	my $data = $tx->res->json;
	$self->_access_token_expire(time+$data->{expires_in});
	return $data->{access_token};
}

sub _retrieve_access_token {
	my $self = shift;
	if ($self->_has_access_token_expire and $self->_access_token_expire <= time) {
		$self->_clear_access_token;
		$self->_clear_access_token_expire;
	}
	return $self->_access_token;
}

has '_translate_languages' => (
	is => 'lazy',
	init_arg => undef,
);

has '_languages_by_name' => (
	is => 'ro',
	lazy => 1,
	default => sub { {} },
	init_arg => undef,
);

sub _build__translate_languages {
	my $self = shift;
	
	my $url = Mojo::URL->new(TRANSLATE_API_ENDPOINT)->path('GetLanguagesForTranslate');
	my $access_token = $self->_retrieve_access_token;
	my %headers = (Authorization => "Bearer $access_token");
	my $tx = $self->ua->get($url, \%headers);
	die $self->ua_error($tx->error) if $tx->error;
	my @languages = $tx->res->dom->xml(1)->find('string')->map('text')->each;
	
	$url = Mojo::URL->new(TRANSLATE_API_ENDPOINT)->path('GetLanguageNames')->query(locale => 'en');
	$headers{'Content-Type'} = 'text/xml';
	$tx = $self->ua->post($url, \%headers, _xml_string_array(@languages));
	die $self->ua_error($tx->error) if $tx->error;
	my @names = $tx->res->dom->xml(1)->find('string')->map('text')->each;
	
	my %languages;
	for my $i (0..$#languages) {
		my $lang = $languages[$i] // next;
		my $name = $names[$i] // next;
		$languages{$lang} = $name;
		$self->_languages_by_name->{lc $name} = $lang;
		my @words = split ' ', $name;
		if (@words > 1) {
			$self->_languages_by_name->{lc $_} //= $lang for @words;
		}
		$self->_languages_by_name->{lc $lang} //= $lang;
	}
	
	return \%languages;
}

sub _xml_string_array {
	my $xml = Mojo::DOM->new->xml(1)->content('<ArrayOfstring></ArrayOfstring>');
	my $array = $xml->at('ArrayOfstring');
	$array->attr(xmlns => MICROSOFT_ARRAY_SCHEMA, 'xmlns:i' => XML_SCHEMA_INSTANCE);
	foreach my $string (@_) {
		my $elem = Mojo::DOM->new->xml(1)->content('<string></string>')->at('string');
		$elem->content($string);
		$array->append_content($elem->to_string);
	}
	return $xml->to_string;
}

sub register {
	my ($self, $bot) = @_;
	$self->client_id($bot->config->get('apis','microsoft_client_id'))
		unless defined $self->client_id;
	$self->client_secret($bot->config->get('apis','microsoft_client_secret'))
		unless defined $self->client_secret;
	die MICROSOFT_API_KEY_MISSING unless defined $self->client_id and defined $self->client_secret;
	
	$bot->add_plugin_method($self, 'detect_language');
	$bot->add_plugin_method($self, 'translate_language_code');
	$bot->add_plugin_method($self, 'translate_language_name');
	$bot->add_plugin_method($self, 'translate_text');
	
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
			
			Mojo::IOLoop->delay(sub {
				my $delay = shift;
				$to = 'en' unless defined $to and length $to;
				if (defined $from and length $from) {
					$delay->pass($from);
				} else { # Detect language
					$self->detect_language($text, $delay->begin(0))
						->catch(sub { $m->reply("Error detecting language: $_[1]") });
				}
			}, sub {
				my ($delay, $from) = @_;
				return $m->reply("Unknown from language $from")
					unless defined (my $from_code = $self->translate_language_code($from));;
				return $m->reply("Unknown to language $to")
					unless defined (my $to_code = $self->translate_language_code($to));
				$delay->data(from => $from_code, to => $to_code);
				$self->translate_text($text, $from_code, $to_code, $delay->begin(0))
					->catch(sub { $m->reply("Error translating text: $_[1]") });
			}, sub {
				my ($delay, $translated) = @_;
				my ($from, $to) = @{$delay->data}{'from','to'};
				$from = $self->translate_language_name($from);
				$to = $self->translate_language_name($to);
				$m->reply("Translated $from => $to: $translated");
			})->catch(sub { $m->reply("Internal error"); die $_[1] });
		},
	);
}

sub detect_language {
	my ($self, $text, $cb) = @_;
	croak 'Undefined text to detect' unless defined $text;
	
	my $url = Mojo::URL->new(TRANSLATE_API_ENDPOINT)->path('Detect')->query(text => $text);
	my $access_token = $self->_retrieve_access_token;
	my %headers = (Authorization => "Bearer $access_token");
	unless ($cb) {
		my $tx = $self->ua->get($url, \%headers);
		die $self->ua_error($tx->error) if $tx->error;
		return $tx->res->dom->xml(1)->at('string')->text;
	}
	return Mojo::IOLoop->delay(sub {
		$self->ua->get($url, \%headers, shift->begin);
	}, sub {
		my ($delay, $tx) = @_;
		die $self->ua_error($tx->error) if $tx->error;
		$cb->($tx->res->dom->xml(1)->at('string')->text);
	});
}

sub translate_language_code {
	my ($self, $lang) = @_;
	croak 'Undefined language' unless defined $lang;
	unless (exists $self->_translate_languages->{$lang}) {
		$lang = $self->_languages_by_name->{lc $lang};
		return undef unless defined $lang and exists $self->_translate_languages->{$lang};
	}
	return $lang;
}

sub translate_language_name {
	my ($self, $lang) = @_;
	croak 'Undefined language' unless defined $lang;
	unless (exists $self->_translate_languages->{$lang}) {
		$lang = $self->_languages_by_name->{lc $lang};
		return undef unless defined $lang and exists $self->_translate_languages->{$lang};
	}
	return $self->_translate_languages->{$lang};
}

sub translate_text {
	my ($self, $text, $from, $to, $cb) = @_;
	croak 'Undefined text to translate' unless defined $text;
	croak "Unknown from language $from"
		unless defined (my $from_code = $self->translate_language_code($from));
	croak "Unknown to language $to"
		unless defined (my $to_code = $self->translate_language_code($to));
	
	my $url = Mojo::URL->new(TRANSLATE_API_ENDPOINT)->path('Translate')
		->query(text => $text, from => $from_code, to => $to_code, contentType => 'text/plain');
	my $access_token = $self->_retrieve_access_token;
	my %headers = (Authorization => "Bearer $access_token");
	unless ($cb) {
		my $tx = $self->ua->get($url, \%headers);
		die $self->ua_error($tx->error) if $tx->error;
		return $tx->res->dom->xml(1)->at('string')->text;
	}
	return Mojo::IOLoop->delay(sub {
		$self->ua->get($url, \%headers, shift->begin);
	}, sub {
		my ($delay, $tx) = @_;
		die $self->ua_error($tx->error) if $tx->error;
		$cb->($tx->res->dom->xml(1)->at('string')->text);
	});
}

1;

=head1 NAME

Bot::ZIRC::Plugin::Translate - Language translation plugin for Bot::ZIRC

=head1 SYNOPSIS

 my $bot = Bot::ZIRC->new(
   plugins => { Translate => 1 },
 );
 
 # Standalone usage
 my $translate = Bot::ZIRC::Plugin::Translate->new(client_id => $client_id, client_secret => $client_secret);
 my $from = $translate->detect_language($text);
 my $translated = $translate->translate_text($text, $from, $to);

=head1 DESCRIPTION

Adds plugin methods and commands for translating text to a L<Bot::ZIRC> IRC
bot.

This plugin requires a Microsoft Client ID and Client secret that is registered
for the Bing Translate API. These must be configured as C<microsoft_client_id>
and C<microsoft_client_secret> in the C<apis> section. See
L<http://blogs.msdn.com/b/translation/p/gettingstarted1.aspx> for information
on obtaining a Microsoft Client ID and Client secret.

=head1 ATTRIBUTES

=head2 client_id

Client ID for Microsoft API, defaults to value of configuration option
C<microsoft_client_id> in section C<apis>.

=head2 client_secret

Client secret for Microsoft API, defaults to value of configuration option
C<microsoft_client_secret> in section C<apis>.

=head1 METHODS

=head2 detect_language

 my $language_code = $bot->detect_language($text);
 $bot->detect_language($text, sub {
   my $language_code = shift;
 })->catch(sub { $m->reply("Error detecting language: $_[1]") });

Attempt to detect the language of a text string. Returns the language code on
success, or throws an exception on error. Pass a callback to perform the query
non-blocking.

=head2 translate_language_code

 my $language_code = $bot->translate_language_code($language_name);

Returns the language code for a given language name or code, or undef if the
language is unknown.

=head2 translate_language_name

 my $language_name = $bot->translate_language_name($language_code);

Returns the language name for a given language name or code, or undef if the
language is unknown.

=head2 translate_text

 my $translated = $bot->translate_text($text, $from, $to);
 $bot->translate_text($text, $from, $to, sub {
   my $translated = shift;
 })->catch(sub { $m->reply("Error translating text: $_[1]") });

Attempt to translate a text string from one language to another. Returns the
translated text on success, or throws an exception on error. Pass a callback to
perform the query non-blocking.

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

L<Bot::ZIRC>
