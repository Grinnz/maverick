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
		}
	},
	plugins => { Repaste => 1 },
);
$bot->start;
