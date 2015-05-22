#!/usr/bin/env perl

use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";
use Bot::Maverick;

my $bot = Bot::Maverick->new(
	networks => {
		socialgamer => {
			class => 'SocialGamer',
			irc => { server => 'irc.socialgamer.net', port => 6697, ssl => 1 },
			users => { master => 'Grinnz' },
		}
	},
	plugins => { DNS => { native => 1 }, LastFM => 1, Google => 1, YouTube => 1,
		GeoIP => 1, Weather => 1, Calc => 1, Wolfram => 1, Wikipedia => 1, PYX => 1,
		Quotes => 1, Twitter => 1, Pick => 1, Translate => 1, Spell => { default_lang => 'en_GB' },
		Repaste => 1, },
);
$bot->start;
