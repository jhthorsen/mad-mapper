package Mad::Mapper;

=head1 NAME

Mad::Mapper - Map Perl objects to MySQL or PostgreSQL row data

=head1 VERSION

0.01

=head1 DESCRIPTION

L<Mad::Mapper> is base class that allow your objects to map to database rows.
It is different from other ORMs, where your objects are now in center instead
of the database.

=head1 SYNOPSIS

=head2 Simple

  package MyApp::Model::User;
  use Mad::Mapper -base;

  # Standard class attributes
  has email => '';
  has id => undef;

  # Return array-ref of User::Group objects: $groups = $self->groups;
  # Same, but async: $self = $self->groups(sub { my ($self, $groups) = @_; ... });
  # The result is also cached until $self->fresh->groups(...) is called
  has_many groups => sub {
    'MyApp::Model::Group',
    'SELECT name FROM users WHERE user_id = ?', sub { $_[0]->id },
  }

  # Define methods to find, delete, insert or update the object in storage
  sub _find   { 'SELECT id, email FROM users WHERE email = ?', $_[0]->email }
  sub _delete { 'DELETE FROM users WHERE id = ?', $_[0]->id }
  sub _insert { 'INSERT INTO users ("email") VALUES(?)', $_[0]->email }
  sub _update { 'UPDATE users SET email = ? WHERE id = ?', $_[0]->email, $_[0]->id }

=head2 Complex

Instead of using the automatic generated methods from simple SQL statements,
it is possible to do the complete query yourself. Below is the example of how
the simple C<_insert()> method above can be done complex:

  package MyApp::Model::User;
  use Mad::Mapper -base;

  sub _insert {
    my ($self, $cb) = @_;

    Mojo::IOLoop->delay(
      sub {
        my ($delay) = @_;
        $self->db->query('INSERT INTO users ("email") VALUES(?)', $self->email, $delay->begin);
      },
      sub {
        my ($delay, $err, $res) = @_;
        return $self->$cb($err) if $err;
        $self->in_storage(1);
        $self->id($res->sth->mysql_insertid);
        $self->$cb('');
      },
    );
  }

Note! The trick is to return an object, instead of a list.

=cut

use Mojo::Base -base;
use Mojo::IOLoop;

our $VERSION = '0.01';

=head1 ATTRIBUTES

=head2 db

  $db = $self->db;
  $self->db($db_obj);

Need to hold either a L<Mojo::Pg::Database> or L<Mojo::mysql::Database> object.

=head2 in_storage

  $bool = $self->in_storage;
  $self = $self->in_storage($bool);

=cut

has db => sub { die "'db' is required in constructor." };
has in_storage => 0;

=head1 METHODS

=head2 delete

  $self = $self->delete;
  $self = $self->delete(sub { my ($self, $err) = @_, ... });

Will delete the object from database if L</in_storage>.

=cut

sub delete {
  my ($self, $cb) = @_;

  if ($cb) {
    $self->in_storage ? $self->_delete($cb) : $self->$cb('');
    return $self;
  }

  my $err;
  $cb = sub { (my $self, $err) = @_; Mojo::IOLoop->stop; };
  $self->_delete($cb) if $self->in_storage;
  die $err if $err;
  return $self;

}

=head2 save

  $self = $self->save;
  $self = $self->save(sub { my ($self, $err) = @_, ... });

Will update the object in database if L</in_storage> or insert it if not.

=cut

sub save {
  my ($self, $cb) = @_;

  if ($cb) {
    $self->in_storage ? $self->_update($cb) : $self->_insert($cb);
    return $self;
  }

  my $err;
  $cb = sub { (my $self, $err) = @_; Mojo::IOLoop->stop; };
  $self->in_storage ? $self->_update($cb) : $self->_insert($cb);
  die $err if $err;
  return $self;
}

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2014, Jan Henning Thorsen

This program is free software, you can redistribute it and/or modify it under
the terms of the Artistic License version 2.0.

=head1 AUTHOR

Jan Henning Thorsen - C<jhthorsen@cpan.org>

=cut

1;
