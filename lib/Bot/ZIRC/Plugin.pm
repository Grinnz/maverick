package Bot::ZIRC::Plugin;

use Moo::Role 2;

requires 'register';

sub require_methods { () }

sub reload {}
sub start {}
sub stop {}

1;
