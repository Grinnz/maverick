package Bot::ZIRC::Plugin::PYX;

use Mojo::URL;

use Moo;
extends 'Bot::ZIRC::Plugin';

use constant PYX_ENDPOINT_MISSING =>
	"PYX plugin requires configuration option 'pyx_endpoint' in section 'apis'\n";
use constant PYX_MAX_PICK => 3;
use constant PYX_MAX_COUNT => 10;

sub register {
	my ($self, $bot) = @_;
	my $endpoint = $bot->config->get('apis','pyx_endpoint');
	die PYX_ENDPOINT_MISSING unless defined $endpoint;
	
	$bot->add_command(
		name => 'pyx',
		help_text => 'Generate random Cards Against Humanity matches',
		usage_text => '[<pick count>|<black card> [<pick count>]|w <white card> ...]',
		on_run => sub {
			my $m = shift;
			my $args = $m->args;
			
			my ($black_card_text, $white_cards, $black_card_pick, $white_card_count);
			if (length $args) {
				if ($args =~ m/^w\s/i) {
					my @white_cards = $args =~ m/w\s+(.+?)(?=(?:\s+w\s|$))/ig;
					undef $_ for grep { m/^[?_]+$/ } @white_cards;
					splice @white_cards, PYX_MAX_PICK if @white_cards > PYX_MAX_PICK;
					$white_cards = \@white_cards;
					$black_card_pick = @white_cards;
					$white_card_count = grep { !defined } @white_cards;
				} elsif ($args =~ m/^\d+$/) {
					$black_card_pick = $args;
				} elsif ($args =~ m/^(.+?)\s+(\d+)$/) {
					$black_card_text = $1;
					$white_card_count = $2;
				} else {
					$black_card_text = $args;
					$white_card_count =()= $args =~ m/__+/g;
				}
			}
			
			if (defined $black_card_text) {
				$white_card_count = 1 if $white_card_count < 1;
				$self->_get_white_cards($m, $white_card_count, sub {
					my ($err, $cards) = @_;
					return $m->reply($err) if $err;
					$self->_show_pyx_match($m, $black_card_text, $cards);
				});
			} else {
				$self->_get_black_card($m, $black_card_pick, sub {
					my ($err, $black_card) = @_;
					return $m->reply($err) if $err;
					$white_card_count //= $black_card->{pick} // 1;
					if ($white_card_count > 0) {
						$self->_get_white_cards($m, $white_card_count, sub {
							my ($err, $cards) = @_;
							return $m->reply($err) if $err;
							if (defined $white_cards) {
								$_ //= shift @$cards for @$white_cards;
							} else {
								$white_cards = $cards;
							}
							$self->_show_pyx_match($m, $black_card->{text}, $white_cards);
						});
					} else {
						$self->_show_pyx_match($m, $black_card->{text}, $white_cards);
					}
				});
			}
		},
	);
}

sub _get_black_card {
	my ($self, $m, $pick, $cb) = @_;
	if (defined $pick) {
		$pick = 1 if $pick < 1;
		$pick = PYX_MAX_PICK if $pick > PYX_MAX_PICK;
	}
	
	my $endpoint = $m->config->get('apis','pyx_endpoint');
	die PYX_ENDPOINT_MISSING unless defined $endpoint;
	my $card_sets = $m->config->get('apis','pyx_card_sets');
	my @card_sets = defined $card_sets ? split ' ', $card_sets : ();
	
	my $url = Mojo::URL->new($endpoint)->path('black/rand');
	$url->query({card_set => \@card_sets}) if @card_sets;
	$url->query({pick => $pick}) if defined $pick;
	
	$self->ua->get($url, sub {
		my ($ua, $tx) = @_;
		return $cb->($self->ua_error($tx->error)) if $tx->error;
		my $card = $tx->res->json->{card};
		return $cb->('No applicable black cards') unless defined $card and defined $card->{text};
		$card->{text} = _format_pyx_card($card->{text});
		$cb->(undef, $card);
	});
}

sub _get_white_cards {
	my ($self, $m, $count, $cb) = @_;
	$count //= 1;
	$count = 1 if $count < 1;
	$count = PYX_MAX_COUNT if $count > PYX_MAX_COUNT;
	
	my $endpoint = $m->config->get('apis','pyx_endpoint');
	die PYX_ENDPOINT_MISSING unless defined $endpoint;
	my $card_sets = $m->config->get('apis','pyx_card_sets');
	my @card_sets = defined $card_sets ? split ' ', $card_sets : ();
	
	my $url = Mojo::URL->new($endpoint)->path('white/rand');
	$url->query({card_set => \@card_sets}) if @card_sets;
	$url->query({count => $count});
	
	$self->ua->get($url, sub {
		my ($ua, $tx) = @_;
		return $cb->($self->ua_error($tx->error)) if $tx->error;
		my $cards = $tx->res->json->{cards} // [];
		$_ = _format_pyx_card($_->{text}) for @$cards;
		$cb->(undef, $cards);
	});
}

sub _show_pyx_match {
	my ($self, $m, $black_card, $white_cards) = @_;
	$black_card //= '';
	$white_cards //= [];
	
	my $u_code = chr hex '0x1f';
	foreach my $white_card (@$white_cards) {
		my $formatted = "_${u_code}$white_card${u_code}_";
		unless ($black_card =~ s/__+/$formatted/) {
			$black_card = "$black_card $formatted";
		}
	}
	
	$m->reply_bare("PYX Match: $black_card");
}

sub _format_pyx_card {
	my $text = shift // return undef;
	my $b_code = chr 2;
	$text =~ s!</?i>!/!g;
	$text =~ s!</?b>!$b_code!g;
	$text =~ s!</?u>!_!g;
	$text =~ s!<.*?>!!g;
	$text =~ s!\r?\n! !g;
	return $text;
}

1;

=head1 NAME

Bot::ZIRC::Plugin::PYX - Pretend You're Xyzzy plugin for Bot::ZIRC

=head1 SYNOPSIS

 my $bot = Bot::ZIRC->new(
   plugins => { PYX => 1 },
 );

=head1 DESCRIPTION

Adds C<pyx> command for forming random Cards Against Humanity combinations to a
L<Bot::ZIRC> IRC bot.

This plugin requires access to a REST interface to pick random cards, as
implemented by L<cah-cards|https://github.com/Grinnz/cah-cards>. The URL
endpoint must be set with the configuration option C<pyx_endpoint> in section
C<apis>.

=head1 COMMANDS

=head2 pyx

 !pyx
 !pyx __ and __: A perfect match.
 !pyx w A giant snail. w Doritos.

Generate random Cards Against Humanity combinations, using the supplied black
card or white card(s) if any. Blanks in black cards are specified as two or
more consecutive underscores, and white cards are prefixed by the lone letter
C<w>. White cards that consist only of underscores or question marks will
additionally be replaced by random cards.

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
