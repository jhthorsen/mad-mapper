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
  sub _find_sst   { 'SELECT id, email FROM users WHERE email = ?', $_[0]->email }
  sub _delete_sst { 'DELETE FROM users WHERE id = ?', $_[0]->id }
  sub _insert_sst { 'INSERT INTO users ("email") VALUES(?)', $_[0]->email }
  sub _update_sst { 'UPDATE users SET email = ? WHERE id = ?', $_[0]->email, $_[0]->id }

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

=cut

use Mojo::Base -base;
use Mojo::IOLoop;
use Scalar::Util qw( blessed weaken );

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
  Mojo::IOLoop->start;
  die $err if $err;
  return $self;
}

=head2 new_from_storage

  $self = $class->new_from_storage(@_);
  $self = $class->new_from_storage(@_, sub { my ($self, $err) = @_; });

Same as C<new()>, but tries to look up additional attributes from database.

=cut

sub new_from_storage {
  my $cb    = ref $_[-1] eq 'CODE' ? pop : undef;
  my $class = shift;
  my $self  = $class->new(@_);

  if ($cb) {
    $self->_find($cb);
    return $self;
  }

  my $err;
  $self->_find(sub { (my $self, $err) = @_; Mojo::IOLoop->stop; });
  Mojo::IOLoop->start;
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
  Mojo::IOLoop->start;
  die $err if $err;
  return $self;
}

=head2 import

Will set up the caller class with L<Mad::Mapper> functionality if "-base"
is given as argument. See L</SYNOPSIS> for example.

=cut

# Most of this code is copy/paste from Mojo::Base
sub import {
  my $class = shift;
  return unless my $flag = shift;

  if    ($flag eq '-base')   { $flag = $class }
  elsif ($flag eq '-strict') { $flag = undef }
  elsif ((my $file = $flag) && !$flag->can('new')) {
    $file =~ s!::|'!/!g;
    require "$file.pm";
  }

  if ($flag) {
    my $caller = caller;
    no strict 'refs';
    push @{"${caller}::ISA"}, $flag;
    *{"${caller}::has"} = sub { Mojo::Base::attr($caller, @_) };
  }

  $_->import for qw(strict warnings utf8);
  feature->import(':5.10');
}

sub _delete {
  my ($self, $cb) = @_;

  weaken $self;
  $self->db->query(
    $self->_delete_sst,
    sub {
      my ($db, $err, $res) = @_;
      $self->in_storage(0) unless $err;
      $self->$cb($err);
    }
  );
}

sub _find {
  my ($self, $cb) = @_;

  weaken $self;
  $self->db->query(
    $self->_find_sst,
    sub {
      my ($db, $err, $res) = @_;
      $res = $res->hash if $res;
      $self->in_storage(1) if $res and !$err;
      $self->{$_} = $res->{$_} for keys %$res;
      $self->$cb($err);
    }
  );
}

sub _insert {
  my ($self, $cb) = @_;

  weaken $self;
  $self->db->query(
    $self->_insert_sst,
    sub {
      my ($db, $err, $res) = @_;
      $self->in_storage(1) unless $err;
      $res = $res->hash;
      $self->id($res->{id}) if $res->{id} and $self->can('id');
      $self->$cb($err);
    }
  );
}

sub _update {
  my ($self, $cb) = @_;
  $self->db->query($self->_update_sst, sub { shift->$cb(shift); });
}

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2014, Jan Henning Thorsen

This program is free software, you can redistribute it and/or modify it under
the terms of the Artistic License version 2.0.

=head1 AUTHOR

Jan Henning Thorsen - C<jhthorsen@cpan.org>

=cut

1;
