package t::Helper;
use Mojo::Base -base;
use Test::More;

my $USERNAME = $^O eq 'Win32' ? 'username' : scalar getpwuid $<;

sub pg {
  my $class = shift;
  plan skip_all => 'Mojo::Pg is required' unless eval 'use Mojo::Pg; 1';
  plan skip_all => "TEST_ONLINE=postgresql://$USERNAME\@/test" unless $ENV{TEST_ONLINE};
  Mojo::Pg->new($ENV{TEST_ONLINE});
}

sub import {
  my $class  = shift;
  my $caller = caller;

  eval <<"HERE" or die $@;
  package $caller;
  use Mojo::Base -base;
  use Test::More;
  1;
HERE
}

1;
