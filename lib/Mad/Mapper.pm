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
        $self->db->query("INSERT INTO users (email) VALUES (?)", $self->email, $delay->begin);
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
use Scalar::Util 'weaken';
use constant DEBUG => $ENV{MAD_DEBUG} || 0;

our $VERSION = '0.01';

my (%COLUMNS, %PK);

=head1 SUGAR

=head2 col

Used to define a column. Follow the same rules as L</has>.

=head2 has

  has name => "Bruce";
  has [qw(name email)];
  has pet => sub { Cat->new };

Same as L<Mojo::Base/has>.

=head2 pk

Used to define a primary key. Follow the same rules as L</has>.

The primary key is used by default in L</refresh> and L</update> to update the
correct row. If omitted, the first L</col> will act as primary key.

Note that L</pk> is not returned by L</columns>.

=head2 table

Used to define a table name. The default is to use the last part of the class
name and add "s" at the end, unless it already has "s" at the end. Examples:

  .----------------------------.
  | Class name        | table  |
  |-------------------|--------|
  | App::Model::User  | users  |
  | App::Model::Users | users  |
  | App::Model::Group | groups |
  '----------------------------'

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

=head2 expand_sst

  ($sst, @args) = $self->expand_sst($sst, @args);

Used to expand a given C<$sst> with variables defined by helpers.

=over 4

=item * %t

Will be replaced by </table>. Example: "SELECT * FROM %t" becomes "SELECT * FROM users".

=item * %c

Will be replaced by L</columns>. Example: "id,name,email".

=item * %c=

Will be replaced by L</columns> assignment. Example: "id=?,name=?,email=?"

=item * %c?

Will be replaced by L</columns> placeholders. Example: "?,?,?"

=item * \%c

Becomes a literal "%c".

=back

=cut

sub expand_sst {
  my ($self, $sst, @args) = @_;

  $sst =~ s|(?<!\\)\%c\=|{join ',', map {"$_=?"} $self->columns}|ge;
  $sst =~ s|(?<!\\)\%c\?|{join ',', map {"?"} $self->columns}|ge;
  $sst =~ s|(?<!\\)\%c|{join ',', $self->columns}|ge;
  $sst =~ s|(?<!\\)\%t|{join ',', $self->table}|ge;
  $sst =~ s|\\%|%|g;

  return $sst, @args;
}

=head2 columns

  @str = $self->columns;

Returns a list of columns, defined by L</col>.

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
    my $table = lc($caller =~ m!::(\w+)$! ? $1 : '');
    $table =~ s!s?$!s!;    # user => users
    Mojo::Util::monkey_patch($caller, col     => sub { $caller->_define_col(@_) });
    Mojo::Util::monkey_patch($caller, columns => sub { @{$COLUMNS{$caller} || []} });
    Mojo::Util::monkey_patch($caller, has     => sub { Mojo::Base::attr($caller, @_) });
    Mojo::Util::monkey_patch($caller,
      pk => sub { return UNIVERSAL::isa($_[0], $caller) ? $PK{$caller} : $caller->_define_pk(@_) });
    Mojo::Util::monkey_patch($caller, table => sub { $table = $_[0] unless UNIVERSAL::isa($_[0], $caller); $table });
    no strict 'refs';
    push @{"${caller}::ISA"}, $flag;
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

sub _define_col {
  my $class = ref($_[0]) || $_[0];
  push @{$COLUMNS{$class}}, ref $_[0] eq 'ARRAY' ? @{$_[1]} : $_[1];
  Mojo::Base::attr(@_);
}

sub _define_pk {
  my $class = ref($_[0]) || $_[0];
  $PK{$class} = $_[1];
  Mojo::Base::attr(@_);
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

sub _find_sst {
  my $self = shift;
  my $pk = $self->pk || ($self->columns)[0];

  $self->expand_sst("SELECT %c FROM %t WHERE $pk=?"), $self->$pk;
}

sub _insert {
  my ($self, $cb) = @_;
  my $pk = $self->pk || ($self->columns)[0];
  my @sst = $self->_insert_sst;

  warn "[Mad::Mapper::insert] ", Mojo::JSON::encode_json(\@sst), "\n" if DEBUG;
  weaken $self;
  $self->db->query(
    @sst,
    sub {
      my ($db, $err, $res) = @_;
      warn "[Mad::Mapper::insert] err=$err\n" if DEBUG and $err;
      $res = eval { $res->hash } || {};
      $res->{$pk} ||= eval { $res->sth->mysql_insertid } if $pk;
      $self->in_storage(1) if $res;
      $self->$_($res->{$_}) for grep { $self->can($_) } keys %$res;
      $self->$cb($err);
    }
  );
}

sub _insert_sst {
  my $self = shift;
  my $pk   = $self->pk;
  my $sql  = "INSERT INTO %t (%c) VALUES (%c?)";

  $sql .= " RETURNING $pk" if $pk and UNIVERSAL::isa($self->db, 'Mojo::Pg::Database');
  $self->expand_sst($sql), map { $self->$_ } $self->columns;
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

sub _update_sst {
  my $self = shift;
  my $pk = $self->pk || ($self->columns)[0];

  $self->expand_sst("UPDATE %t SET %c? WHERE $pk=?"), (map { $self->$_ } $self->columns), $self->$pk;
}

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2014, Jan Henning Thorsen

This program is free software, you can redistribute it and/or modify it under
the terms of the Artistic License version 2.0.

=head1 AUTHOR

Jan Henning Thorsen - C<jhthorsen@cpan.org>

=cut

1;
