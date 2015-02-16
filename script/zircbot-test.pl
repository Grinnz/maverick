#!/usr/bin/env perl

use strict;
use warnings;
use Bot::ZIRC;

my $bot = Bot::ZIRC->new(networks => { socialgamer => {
		class => 'SocialGamer',
		irc => { server => 'irc.socialgamer.net', port => 6697, ssl => 1 },
		users => { master => 'Grinnz' },
		channels => { autojoin => '#bots' },
	}},
	plugins => { DNS => 1 },
);
$bot->start;
