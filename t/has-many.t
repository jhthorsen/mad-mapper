use Mojo::Base -base;
use Test::More;
use t::User;

plan skip_all => "TEST_ONLINE=postgresql://@{[scalar getpwuid $<]}\@/test" unless $ENV{TEST_ONLINE};
plan skip_all => 'Mojo::Pg is required' unless eval 'use Mojo::Pg; 1';

# change table name
t::User::table('mad_mapper_has_many_users');

my $pg = Mojo::Pg->new($ENV{TEST_ONLINE});
my $user = t::User->new(db => $pg->db);
my $err;

$pg->db->query('DROP TABLE IF EXISTS mad_mapper_has_many_groups');
$pg->db->query('DROP TABLE IF EXISTS mad_mapper_has_many_users');
$pg->db->query('CREATE TABLE mad_mapper_has_many_users (id SERIAL PRIMARY KEY, email TEXT, name TEXT)');
$pg->db->query(
  'CREATE TABLE mad_mapper_has_many_groups (id SERIAL PRIMARY KEY, user_id INTEGER REFERENCES mad_mapper_has_many_users (id), name TEXT)'
);

$user->email('test@example.com')->save;
my $col = $user->groups;
isa_ok($col, 'Mojo::Collection');
is($col->size, 0, 'zero');

$pg->db->query('DROP TABLE mad_mapper_has_many_groups');
$pg->db->query('DROP TABLE mad_mapper_has_many_users');

done_testing;
