package t::User;
use Mad::Mapper -base;

# Standard class attributes
has email => '';
has id    => undef;

# Define methods to find, delete, insert or update the object in storage
sub _find_sst   { 'SELECT id, email FROM simple_users WHERE email = ?',         $_[0]->email }
sub _delete_sst { 'DELETE FROM simple_users WHERE id = ?',                      $_[0]->id }
sub _insert_sst { 'INSERT INTO simple_users ("email") VALUES (?) RETURNING id', $_[0]->email }
sub _update_sst { 'UPDATE simple_users SET email = ? WHERE id = ?',             $_[0]->email, $_[0]->id }

1;
