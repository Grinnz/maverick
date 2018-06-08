#!/usr/bin/env perl

use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";
use Bot::Maverick;

my $bot = Bot::Maverick->new(
	name => 'Repaster',
	networks => {
		freenode => {
			class => 'Freenode',
			config => {
				irc => { server => 'chat.freenode.net', port => 6697, ssl => 1 },
				users => { master => 'Grinnz' },
			},
		},
		magnet => {
			config => {
				irc => { server => 'irc.perl.org', port => 7062, ssl => 1, insecure => 1 },
				users => { master => 'Grinnz' },
			},
		},
	},
	plugins => { Repaste => 1 },
);
$bot->start;
