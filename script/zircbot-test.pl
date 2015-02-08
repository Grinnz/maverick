#!/usr/bin/env perl

use strict;
use warnings;
use ZIRCBot;

my $bot = ZIRCBot->new(irc_role => 'SocialGamer', config => {
	users => { master => 'Grinnz' },
	irc => { server => 'irc.socialgamer.net', port => 6697, ssl => 1 },
	channels => { autojoin => '#bots' },
});
$bot->start;
