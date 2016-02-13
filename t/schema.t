use Mojo::Base -strict;
use Test::More;

eval <<'HERE' or die $@;
package User;
use Mad::Mapper -base;
use Mojo::UserAgent;
pk 'id';
col forename => '';
col surname => 'Doe';
col email => sub { lc sprintf '%s@%s.com', $_[0]->forename, $_[0]->surname };
has _ua => sub { Mojo::UserAgent->new };
sub name { sprintf '%s, %s', $_[0]->surname, $_[0]->forename }
1;
HERE

ok(User->can($_), "user can $_") for qw( id forename surname email _ua name );

is User->table, 'users', 'table';
is_deeply [User->columns], [qw( forename surname email )], 'columns';

my $user = User->new;
is $user->id,      undef, 'id';
is $user->surname, 'Doe', 'surname';
isa_ok($user->_ua, 'Mojo::UserAgent');
is $user->name, 'Doe, ', 'name';
is $user->forename('Lucy'), $user, 'forename';
is $user->email, 'lucy@doe.com', 'email';
is_deeply($user->TO_JSON, {id => undef, forename => 'Lucy', surname => 'Doe', email => 'lucy@doe.com'}, 'TO_JSON');

# Test plural form of singular table
eval <<'HERE' or die $@;
package Model::MyInventory;
use Mad::Mapper -base;
pk 'id';
1;
HERE

ok(Model::MyInventory->can($_), "MyInventory can $_") for (qw( id table ));
is(Model::MyInventory->new->table, 'my_inventories','class decamelized to table');

# Test plural form of singular table when already plural
eval <<'HERE' or die $@;
package Model::MyInventories;
use Mad::Mapper -base;
pk 'id';
1;
HERE

ok(Model::MyInventories->can($_), "MyInventories can $_") for (qw( id table ));
is(Model::MyInventories->new->table, 'my_inventories','class decamelized to table');

# Test plural form of singular table
eval <<'HERE' or die $@;
package Model::Menu;
use Mad::Mapper -base;
pk 'id';
1;
HERE

ok(Model::Menu->can($_), "Menu can $_") for (qw( id table ));
is(Model::Menu->new->table, 'menus','class decamelized to table');

# Lingua:EN::Inflect::Number fails in some very spectacular ways: menuses???
eval <<'HERE' or die $@;
package Model::Menus;
use Mad::Mapper -base;
pk 'id';
1;
HERE

ok(Model::Menus->can($_), "Menus can $_") for (qw( id table ));
is(Model::Menus->new->table, 'menuses','class decamelized to table');

done_testing;
