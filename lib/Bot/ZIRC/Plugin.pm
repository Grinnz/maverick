package Bot::ZIRC::Plugin;

use Moo::Role;
use warnings NONFATAL => 'all';

requires 'register';

sub reload {}
sub start {}
sub stop {}

1;
