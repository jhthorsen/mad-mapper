use t::Helper;
use t::User;

# change table name
t::User::table('mad_mapper_has_many_users');

my $pg = t::Helper->pg;
my $user = t::User->new(db => $pg->db);
my ($col, $group);

$pg->db->query('DROP TABLE IF EXISTS mad_mapper_has_many_groups');
$pg->db->query('DROP TABLE IF EXISTS mad_mapper_has_many_users');
$pg->db->query('CREATE TABLE mad_mapper_has_many_users (id SERIAL PRIMARY KEY, email TEXT, name TEXT)');
$pg->db->query(<<'HERE');
CREATE TABLE mad_mapper_has_many_groups
  (id SERIAL PRIMARY KEY, user_id INTEGER REFERENCES mad_mapper_has_many_users (id), name TEXT)
HERE

$user->email('test@example.com')->save;
$col = $user->groups;
isa_ok($col, 'Mojo::Collection');
is($col->size, 0, 'zero');

$group = $user->add_group(name => 'admin')->save;

$col = $user->groups;
is($col->size, 0, 'still zero');

$col = $user->fresh->groups;
is($col->size, 1, 'fresh from db');

$pg->db->query('DROP TABLE mad_mapper_has_many_groups');
$pg->db->query('DROP TABLE mad_mapper_has_many_users');

done_testing;
