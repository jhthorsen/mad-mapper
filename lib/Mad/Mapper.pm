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

The synopsis is split into three parts: The two first is for developers and the
last is for end user.

=head2 Simple

  package MyApp::Model::User;
  use Mad::Mapper -base;

  # Class attributes
  col id => undef;
  col email => '';

  # TODO!
  # Return array-ref of User::Group objects: $groups = $self->groups;
  # Same, but async: $self = $self->groups(sub { my ($self, $groups) = @_; ... });
  # The result is also cached until $self->fresh->groups(...) is called
  has_many groups => sub {
    "MyApp::Model::Group",
    "SELECT name FROM users WHERE user_id = ?", sub { $_[0]->id },
  }

  # Define methods to find, delete, insert or update the object in storage
  sub _find_sst   { "SELECT id, email FROM users WHERE email = ?", $_[0]->email }
  sub _delete_sst { "DELETE FROM users WHERE id = ?", $_[0]->id }
  sub _insert_sst { "INSERT INTO users (email) VALUES(?)", $_[0]->email }
  sub _update_sst { "UPDATE users SET email = ? WHERE id = ?", $_[0]->email, $_[0]->id }

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
        $self->db->query("INSERT INTO users (email) VALUES(?)", $self->email, $delay->begin);
      },
      sub {
        my ($delay, $err, $res) = @_;
        return $self->$cb($err) if $err;
        $self->in_storage(1);
        $self->id($res->sth->mysql_insertid);
        $self->$cb("");
      },
    );
  }

=head2 High level usage

  use Mojolicious::Lite;
  use MyApp::Model::User;

  get "/profile" => sub {
    my $c = shift;
    my $user = MyApp::Model::User->new(id => $c->session("uid"));

    $c->delay(
      sub {
        my ($delay) = @_;
        $user->refresh($delay->begin);
      },
      sub {
        my ($delay, $err) = @_;
        return $self->render_exception($err) if $err;
        return $self->render(user => $user);
      },
    );
  };

  post "/profile" => sub {
    my $c = shift;
    my $user = MyApp::Model::User->new(id => $c->session("uid"));

    $c->delay(
      sub {
        my ($delay) = @_;
        $user->email($self->param("email"));
        $user->save($delay->begin);
      },
      sub {
        my ($delay, $err) = @_;
        return $self->render_exception($err) if $err;
        return $self->render(user => $user);
      },
    );
  };

=cut

use Mojo::Base -base;
use Mojo::IOLoop;
use Mojo::JSON ();
use Scalar::Util qw( blessed weaken );
use constant DEBUG => $ENV{MAD_DEBUG} || 0;

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

=head2 refresh

  $self = $self->refresh;
  $self = $class->refresh(sub { my ($self, $err) = @_; });

Used to fetch data from storage and update the object attributes.

=cut

sub refresh {
  my $cb = ref $_[-1] eq 'CODE' ? pop : undef;
  my $self = shift;

  if ($cb) {
    $self->_find($cb);
  }
  else {
    my $err;
    $self->_find(sub { (my $self, $err) = @_; Mojo::IOLoop->stop; });
    Mojo::IOLoop->start;
    die $err if $err;
  }

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
    my @columns;
    no strict 'refs';
    push @{"${caller}::ISA"}, $flag;
    *{"${caller}::has"} = sub { Mojo::Base::attr($caller, @_) };
    *{"${caller}::col"} = sub {
      push @columns, ref $_[0] eq 'ARRAY' ? @{$_[0]} : $_[0];
      Mojo::Base::attr($caller, @_);
    };
    *{"${caller}::column_names"} = sub {@columns};
  }

  $_->import for qw(strict warnings utf8);
  feature->import(':5.10');
}

sub _delete {
  my ($self, $cb) = @_;
  my @sst = $self->_delete_sst;

  weaken $self;
  warn "[Mad::Mapper::delete] ", Mojo::JSON::encode_json(\@sst), "\n" if DEBUG;
  $self->db->query(
    @sst,
    sub {
      my ($db, $err, $res) = @_;
      warn "[Mad::Mapper::delete] err=$err\n" if DEBUG and $err;
      $self->in_storage(0) unless $err;
      $self->$cb($err);
    }
  );
}

sub _find {
  my ($self, $cb) = @_;
  my @sst = $self->_find_sst;

  warn "[Mad::Mapper::find] ", Mojo::JSON::encode_json(\@sst), "\n" if DEBUG;
  weaken $self;
  $self->db->query(
    @sst,
    sub {
      my ($db, $err, $res) = @_;
      warn "[Mad::Mapper::find] err=$err\n" if DEBUG and $err;
      $res = $err ? {} : $res->hash || {};
      $self->in_storage(1) if %$res and !$err;
      $self->{$_} = $res->{$_} for keys %$res;
      $self->$cb($err);
    }
  );
}

sub _insert {
  my ($self, $cb) = @_;
  my @sst = $self->_insert_sst;

  warn "[Mad::Mapper::insert] ", Mojo::JSON::encode_json(\@sst), "\n" if DEBUG;
  weaken $self;
  $self->db->query(
    @sst,
    sub {
      my ($db, $err, $res) = @_;
      warn "[Mad::Mapper::insert] err=$err\n" if DEBUG and $err;
      $self->in_storage(1) unless $err;
      $res = eval { $res->hash } || {};
      $self->id($res->{id}) if $res->{id} and $self->can('id');
      $self->$cb($err);
    }
  );
}

sub _update {
  my ($self, $cb) = @_;
  my @sst = $self->_update_sst;

  warn "[Mad::Mapper::update] ", Mojo::JSON::encode_json(\@sst), "\n" if DEBUG;
  weaken $self;
  $self->db->query(
    @sst,
    sub {
      my ($db, $err, $res) = @_;
      warn "[Mad::Mapper::update] err=$err\n" if DEBUG and $err;
      $self->$cb($err);
    }
  );
}

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2014, Jan Henning Thorsen

This program is free software, you can redistribute it and/or modify it under
the terms of the Artistic License version 2.0.

=head1 AUTHOR

Jan Henning Thorsen - C<jhthorsen@cpan.org>

=cut

1;
