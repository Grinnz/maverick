#!/usr/bin/env perl

use strict;
use warnings;
use ZIRCBot;
use POE;

my $bot = ZIRCBot->new;
$bot->create_poe_session;
POE::Kernel->run;
