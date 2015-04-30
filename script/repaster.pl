#!/usr/bin/env perl

use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";
use Mojo::JSON::MaybeXS;
use Bot::ZIRC;

my $bot = Bot::ZIRC->new(
	name => 'Repaster',
	networks => {
		freenode => {
			class => 'Freenode',
			irc => { server => 'chat.freenode.net', port => 6697, ssl => 1 },
			users => { master => 'Grinnz' },
			channels => { autojoin => '#perl' },
		},
		magnet => {
			irc => { server => 'irc.perl.org', port => 7062, ssl => 1 },
			users => { master => 'Grinnz' },
			channels => { autojoin => '#mojo' },
		},
	},
	plugins => { Repaste => 1 },
);
$bot->start;
