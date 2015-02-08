#!/usr/bin/env perl

use strict;
use warnings;
use ZIRCBot;

my $bot = ZIRCBot->new(irc_role => 'SocialGamer');
$bot->start;
