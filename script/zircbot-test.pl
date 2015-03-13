#!/usr/bin/env perl

use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";
use Bot::ZIRC;

my $bot = Bot::ZIRC->new(networks => { socialgamer => {
		class => 'SocialGamer',
		irc => { server => 'irc.socialgamer.net', port => 6697, ssl => 1 },
		users => { master => 'Grinnz' },
		channels => { autojoin => '#bots' },
	}},
	plugins => { DNS => { native => 0 }, LastFM => 1, Google => 1, YouTube => 1,
		GeoIP => 1, Weather => 1, Calc => 1, Wolfram => 1, Wikipedia => 1, PYX => 1,
		Quotes => 1, Twitter => 1 },
);
$bot->start;
