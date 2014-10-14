use Mojo::Base -base;
use Test::More;
use t::User;

plan skip_all => 'set TEST_ONLINE to enable this test' unless $ENV{TEST_ONLINE};
plan skip_all => 'Mojo::Pg is required' unless eval 'use Mojo::Pg; 1';

my $pg = Mojo::Pg->new($ENV{TEST_ONLINE});
my $user = t::User->new(db => $pg->db);
my $err;

$pg->db->do('CREATE TABLE IF NOT EXISTS simple_users (id SERIAL, email varchar(255))');

ok !$user->in_storage, 'not in_storage';

$user->email('test@example.com');
is $user->save, $user, 'save() returned $self';
ok $user->in_storage, 'user is in_storage';

$user->email('foo@example.com');
$user->save(
  sub {
    (my $user, $err) = @_;
    Mojo::IOLoop->stop;
  },
);
$err = 'not saved';
Mojo::IOLoop->start;
ok !$err, 'save() updated' or diag $err;

is $user->delete, $user, 'delete() return $self';
ok !$user->in_storage, 'not in_storage';

$user = t::User->new_from_storage(db => $pg->db, email => 'test@example.com');
ok !$user->in_storage, 'could not find user in storage';

$user = t::User->new_from_storage(db => $pg->db, email => 'foo@example.com');
ok $user->in_storage, 'found user in storage';

$pg->db->do('DROP TABLE simple_users');

done_testing;
