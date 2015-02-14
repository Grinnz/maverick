#!/usr/bin/env perl

use strict;
use warnings;
use Bot::ZIRC;

my $bot = Bot::ZIRC->new(irc_role => 'SocialGamer', config => {
	users => { master => 'Grinnz' },
	irc => { server => 'irc.socialgamer.net', port => 6697, ssl => 1 },
	channels => { autojoin => '#bots' },
});
$bot->register_plugin('Bot::ZIRC::Plugin::Default');
$bot->start;
