package Bot::ZIRC::Plugin::PYX;

use Mojo::URL;

use Moo;
with 'Bot::ZIRC::Plugin';

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
		tokenize => 0,
		on_run => sub {
			my ($network, $sender, $channel, $args) = @_;
			
			my ($black_card_text, $white_cards, $black_card_pick, $white_card_count);
			if (length $args) {
				if ($args =~ m/^w\s/) {
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
				get_white_cards($network, $white_card_count, sub {
					my ($err, $cards) = @_;
					return $network->reply($sender, $channel, $err) if $err;
					show_pyx_match($network, $sender, $channel, $black_card_text, $cards);
				});
			} else {
				get_black_card($network, $black_card_pick, sub {
					my ($err, $black_card) = @_;
					return $network->reply($sender, $channel, $err) if $err;
					$white_card_count //= $black_card->{pick} // 1;
					if ($white_card_count > 0) {
						get_white_cards($network, $white_card_count, sub {
							my ($err, $cards) = @_;
							return $network->reply($sender, $channel, $err) if $err;
							if (defined $white_cards) {
								$_ //= shift @$cards for @$white_cards;
							} else {
								$white_cards = $cards;
							}
							show_pyx_match($network, $sender, $channel, $black_card->{text}, $white_cards);
						});
					} else {
						show_pyx_match($network, $sender, $channel, $black_card->{text}, $white_cards);
					}
				});
			}
		},
	);
}

sub get_black_card {
	my ($network, $pick, $cb) = @_;
	if (defined $pick) {
		$pick = 1 if $pick < 1;
		$pick = PYX_MAX_PICK if $pick > PYX_MAX_PICK;
	}
	
	my $endpoint = $network->config->get('apis','pyx_endpoint');
	die PYX_ENDPOINT_MISSING unless defined $endpoint;
	my $card_sets = $network->config->get('apis','pyx_card_sets');
	my @card_sets = defined $card_sets ? split ' ', $card_sets : ();
	
	my $url = Mojo::URL->new($endpoint)->path('black/rand');
	$url->query({card_set => \@card_sets}) if @card_sets;
	$url->query({pick => $pick}) if defined $pick;
	
	$network->ua->get($url, sub {
		my ($ua, $tx) = @_;
		return $cb->(ua_error($tx->error)) if $tx->error;
		my $card = $tx->res->json->{card};
		return $cb->('No applicable black cards') unless defined $card and defined $card->{text};
		$card->{text} = format_pyx_card($card->{text});
		$cb->(undef, $card);
	});
}

sub get_white_cards {
	my ($network, $count, $cb) = @_;
	$count //= 1;
	$count = 1 if $count < 1;
	$count = PYX_MAX_COUNT if $count > PYX_MAX_COUNT;
	
	my $endpoint = $network->config->get('apis','pyx_endpoint');
	die PYX_ENDPOINT_MISSING unless defined $endpoint;
	my $card_sets = $network->config->get('apis','pyx_card_sets');
	my @card_sets = defined $card_sets ? split ' ', $card_sets : ();
	
	my $url = Mojo::URL->new($endpoint)->path('white/rand');
	$url->query({card_set => \@card_sets}) if @card_sets;
	$url->query({count => $count});
	
	$network->ua->get($url, sub {
		my ($ua, $tx) = @_;
		return $cb->(ua_error($tx->error)) if $tx->error;
		my $cards = $tx->res->json->{cards} // [];
		$_ = format_pyx_card($_->{text}) for @$cards;
		$cb->(undef, $cards);
	});
}

sub show_pyx_match {
	my ($network, $sender, $channel, $black_card, $white_cards) = @_;
	$black_card //= '';
	$white_cards //= [];
	
	my $u_code = chr hex '0x1f';
	foreach my $white_card (@$white_cards) {
		my $formatted = "_${u_code}$white_card${u_code}_";
		unless ($black_card =~ s/__+/$formatted/) {
			$black_card = "$black_card $formatted";
		}
	}
	
	$network->reply($sender, $channel, "PYX Match: $black_card");
}

sub format_pyx_card {
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
