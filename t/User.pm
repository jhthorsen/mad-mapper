package t::User;
use Mad::Mapper -base;

table 'mad_mapper_simple_users';

pk 'id';
col email => '';
col name  => '';

has_many groups => 't::Group' => 'user_id';

sub _find_sst {
  my $self = shift;
  my $pk   = $self->_pk_or_first_column;

  return $self->expand_sst("SELECT %pc FROM %t WHERE $pk=?"), $self->$pk if $self->$pk;
  return $self->expand_sst("SELECT %pc FROM %t WHERE email=?"), $self->email;
}

1;
