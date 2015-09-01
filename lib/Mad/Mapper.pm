package Mad::Mapper;

=head1 NAME

Mad::Mapper - Map Perl objects to MySQL or PostgreSQL row data

=head1 VERSION

0.04

=head1 DESCRIPTION

L<Mad::Mapper> is base class for objects that should be stored to the a
persistent SQL database. Currently the supported backends are L<Mojo::Pg>
or L<Mojo::mysql>, both which are optional dependencies.

THIS MODULE IS EXPERIMENTAL!

=head1 SYNOPSIS

The synopsis is split into three parts: The two first is for model developers,
and the last is for the developer using the models.

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
        $self->id($db->dbh->last_insert_id(undef, undef, $self->table, $self->pk));
        $self->$cb("");
      },
    );
  }

=head2 High level usage

  use Mojolicious::Lite;
  use MyApp::Model::User;
  use Mojo::Pg;

  my $pg = Mojo::Pg->new;

  helper model => sub {
    my $c = shift;
    my $model = "MyApp::Model::" .shift;
    return $model->new(db => $pg->db, @_);
  };

  get "/profile" => sub {
    my $c    = shift;
    my $user = $c->model(User => id => $c->session("uid"));

    $c->delay(
      sub {
        my ($delay) = @_;
        $user->load($delay->begin);
      },
      sub {
        my ($delay, $err) = @_;
        return $self->render_exception($err) if $err;
        return $self->render(user => $user);
      },
    );
  };

  post "/profile" => sub {
    my $c    = shift;
    my $user = $c->model(User => id => $c->session("uid"));

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

=head1 RELATIONSHIPS

Currently one a basic L</has_many> relationship is supported.

TODO: C<belongs_to()> to and maybe C<has_one()>.

=head2 Has many

Define a relationship:

  package MyApp::Model::User;
  use Mad::Mapper -base;
  has_many groups => "MyApp::Model::Group", "id_user";

Here "id_user" in the "groups" table should reference back to
the L<primary key|/pk> in the current table.

Return L<Mojo::Collection> of C<MyApp::Model::Group> objects:

  $groups = $self->groups;

Same, but async:

  $self = $self->groups(sub { my ($self, $err, $groups) = @_; ... });

Create a new C<MyApp::Model::Group> object:

  $group = $self->add_group(\%constructor_args);
  $group->save;

=cut

use Mojo::Base -base;
use Mojo::IOLoop;
use Mojo::JSON ();
use Mojo::Loader 'load_class';
use Scalar::Util 'weaken';
use constant DEBUG => $ENV{MAD_DEBUG} || 0;

our $VERSION = '0.04';

my (%COLUMNS, %LOADED, %PK);

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

The primary key is used by default in L</load> and L</update> to update the
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

Will be replaced by L</columns>. Example: "name,email".

=item * %c=

Will be replaced by L</columns> assignment. Example: "name=?,email=?"

=item * %c?

Will be replaced by L</columns> placeholders. Example: "?,?,?"

=item * %pc

Include L</pk> in list of columns. Example: "id,name,email".

=item * \%c

Becomes a literal "%c".

=back

=cut

sub expand_sst {
  my ($self, $sst, @args) = @_;

  $sst =~ s|(?<!\\)\%c\=|{join ',', map {"$_=?"} $self->columns}|ge;
  $sst =~ s|(?<!\\)\%c\?|{join ',', map {"?"} $self->columns}|ge;
  $sst =~ s|(?<!\\)\%c|{join ',', $self->columns}|ge;
  $sst =~ s|(?<!\\)\%pc|{join ',', $self->pk, $self->columns}|ge;
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
  my $self = shift;
  $self->_delete(@_) if $self->in_storage;
  $self;
}

=head2 fresh

  $self = $self->fresh;

Will mark the next relationship accessor to fetch new data from database,
instead of using the cached data on C<$self>.

=cut

sub fresh { $_[0]->{fresh}++; $_[0] }

=head2 load

  $self = $self->load;
  $self = $class->load(sub { my ($self, $err) = @_; });

Used to fetch data from storage and update the object attributes.

=cut

sub load {
  my $self = shift;
  $self->_find(@_);
  $self;
}

=head2 save

  $self = $self->save;
  $self = $self->save(sub { my ($self, $err) = @_, ... });

Will update the object in database if L</in_storage> or insert it if not.

=cut

sub save {
  my $self = shift;
  $self->in_storage ? $self->_update(@_) : $self->_insert(@_);
  $self;
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
    my $table = lc +(split /::/, $caller)[-1];
    $table =~ s!s?$!s!;    # user => users
    Mojo::Util::monkey_patch($caller, col      => sub { $caller->_define_col(@_) });
    Mojo::Util::monkey_patch($caller, columns  => sub { @{$COLUMNS{$caller} || []} });
    Mojo::Util::monkey_patch($caller, has      => sub { Mojo::Base::attr($caller, @_) });
    Mojo::Util::monkey_patch($caller, has_many => sub { $caller->_define_has_many(@_) });
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

  warn "[Mad::Mapper::delete] ", Mojo::JSON::encode_json(\@sst), "\n" if DEBUG;

  if ($cb) {
    weaken $self;
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
  else {
    $self->db->query(@sst);
    $self->in_storage(0);
  }
}

sub _delete_sst {
  my $self = shift;
  my $pk   = $self->_pk_or_first_column;

  $self->expand_sst("DELETE FROM %t WHERE $pk=?"), $self->$pk;
}

sub _define_col {
  my $class = ref($_[0]) || $_[0];
  push @{$COLUMNS{$class}}, ref $_[0] eq 'ARRAY' ? @{$_[1]} : $_[1];
  Mojo::Base::attr(@_);
}

sub _define_has_many {
  my ($class, $method, $related_class, $related_col) = @_;
  my $pk = $class->_pk_or_first_column;

  Mojo::Util::monkey_patch(
    $class => $method => sub {
      my ($self, $cb) = @_;
      my $err = $LOADED{$related_class}++ ? 0 : load_class $related_class;
      my $fresh = delete $self->{fresh};
      my @sst;

      die ref $err ? "Exception: $err" : "Could not find class $related_class!" if $err;

      @sst = $related_class->expand_sst("SELECT %pc FROM %t WHERE $related_col=?", $self->$pk);
      warn sprintf "[Mad::Mapper::has_many::$method] %s\n",
        (!$fresh and $self->{cache}{$method}) ? 'CACHED' : Mojo::JSON::encode_json(\@sst)
        if DEBUG;

      if ($cb) {
        if ($fresh or !$self->{cache}{$method}) {
          $self->db->query(
            \@sst,
            sub {
              my ($db, $err, $res) = @_;
              warn "[Mad::Mapper::has_many::$method] err=$err\n" if DEBUG and $err;
              $self->{cache}{$method} = $res->hashes->map(sub { $related_class->new($_)->in_storage(1) });
              $self->$cb($err, $self->{cache}{$method});
            }
          );
        }
        else {
          $self->$cb('', $self->{cache}{$method});
        }
        return $self;
      }
      else {
        delete $self->{cache}{$method} if $fresh;
        return $self->{cache}{$method}
          ||= $self->db->query(@sst)->hashes->map(sub { $related_class->new($_)->in_storage(1) });
      }
    }
  );

  my $add_method = "add_$method";
  $add_method =~ s!s?$!!;
  Mojo::Util::monkey_patch(
    $class => $add_method => sub {
      my $self = shift;
      my $err = $LOADED{$related_class}++ ? 0 : load_class $related_class;
      $related_class->new(db => $self->db, @_, $related_col => $self->$pk);
    }
  );
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
  if ($cb) {
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
  else {
    my $res = $self->db->query(@sst)->hash || {};
    $self->in_storage(1) if keys %$res;
    $self->{$_} = $res->{$_} for keys %$res;
  }
}

sub _find_sst {
  my $self = shift;
  my $pk   = $self->_pk_or_first_column;

  $self->expand_sst("SELECT %pc FROM %t WHERE $pk=?"), $self->$pk;
}

sub _insert {
  my ($self, $cb) = @_;
  my $pk  = $self->_pk_or_first_column;
  my $db  = $self->db;
  my @sst = $self->_insert_sst;

  warn "[Mad::Mapper::insert] ", Mojo::JSON::encode_json(\@sst), "\n" if DEBUG;

  if ($cb) {
    weaken $self;
    $db->query(
      @sst,
      sub {
        my ($db, $err, $res) = @_;
        warn "[Mad::Mapper::insert] err=$err\n" if DEBUG and $err;
        $res = eval { $res->hash } || {};

        if ($pk) {
          $res->{$pk} ||= $db->dbh->last_insert_id(undef, undef, $self->table, $self->pk);
          $res->{$pk} ||= eval { $res->sth->mysql_insertid };    # can probably be removed
        }

        $self->in_storage(1) if keys %$res;
        $self->$_($res->{$_}) for grep { $self->can($_) } keys %$res;
        $self->$cb($err);
      }
    );
  }
  else {
    my $res = $db->query(@sst);
    $res = eval { $res->hash } || {};

    if ($pk) {
      $res->{$pk} ||= $db->dbh->last_insert_id(undef, undef, $self->table, $self->pk);
      $res->{$pk} ||= eval { $res->sth->mysql_insertid }    # can probably be removed;
    }

    $self->in_storage(1) if keys %$res;
    $self->$_($res->{$_}) for grep { $self->can($_) } keys %$res;    # used with Mojo::Pg and RETURNING
  }
}

sub _insert_sst {
  my $self = shift;
  my $pk   = $self->pk;
  my $sql  = "INSERT INTO %t (%c) VALUES (%c?)";

  $sql .= " RETURNING $pk" if $pk and UNIVERSAL::isa($self->db, 'Mojo::Pg::Database');
  $self->expand_sst($sql), map { $self->$_ } $self->columns;
}

sub _pk_or_first_column { $_[0]->pk || ($_[0]->columns)[0] }

sub _update {
  my ($self, $cb) = @_;
  my @sst = $self->_update_sst;

  warn "[Mad::Mapper::update] ", Mojo::JSON::encode_json(\@sst), "\n" if DEBUG;

  if ($cb) {
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
  else {
    $self->db->query(@sst);
  }
}

sub _update_sst {
  my $self = shift;
  my $pk   = $self->_pk_or_first_column;

  $self->expand_sst("UPDATE %t SET %c= WHERE $pk=?"), (map { $self->$_ } $self->columns), $self->$pk;
}

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2014, Jan Henning Thorsen

This program is free software, you can redistribute it and/or modify it under
the terms of the Artistic License version 2.0.

=head1 AUTHOR

Jan Henning Thorsen - C<jhthorsen@cpan.org>

=cut

1;
