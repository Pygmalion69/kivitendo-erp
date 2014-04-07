package SL::DB::PeriodicInvoicesConfig;

use strict;

use SL::DB::MetaSetup::PeriodicInvoicesConfig;

use List::Util qw(max min);

__PACKAGE__->meta->initialize;

# Creates get_all, get_all_count, get_all_iterator, delete_all and update_all.
__PACKAGE__->meta->make_manager_class;

our @PERIODICITIES  = qw(m q f b y);
our %PERIOD_LENGTHS = ( m => 1, q => 3, f => 4, b => 6, y => 12 );

sub get_period_length {
  my $self = shift;
  return $PERIOD_LENGTHS{ $self->periodicity } || 1;
}

sub _log_msg {
  $::lxdebug->message(LXDebug->DEBUG1(), join('', @_));
}

sub handle_automatic_extension {
  my $self = shift;

  _log_msg("HAE for " . $self->id . "\n");
  # Don't extend configs that have been terminated. There's nothing to
  # extend if there's no end date.
  return if $self->terminated || !$self->end_date;

  my $today    = DateTime->now_local;
  my $end_date = $self->end_date;

  _log_msg("today $today end_date $end_date\n");

  # The end date has not been reached yet, therefore no extension is
  # needed.
  return if $today <= $end_date;

  # The end date has been reached. If no automatic extension has been
  # set then terminate the config and return.
  if (!$self->extend_automatically_by) {
    _log_msg("setting inactive\n");
    $self->active(0);
    $self->save;
    return;
  }

  # Add the automatic extension period to the new end date as long as
  # the new end date is in the past. Then save it and get out.
  $end_date->add(months => $self->extend_automatically_by) while $today > $end_date;
  _log_msg("new end date $end_date\n");

  $self->end_date($end_date);
  $self->save;

  return $end_date;
}

sub get_previous_billed_period_start_date {
  my $self  = shift;

  my $query = <<SQL;
    SELECT MAX(period_start_date)
    FROM periodic_invoices
    WHERE config_id = ?
SQL

  my ($date) = $self->dbh->selectrow_array($query, undef, $self->id);

  return undef unless $date;
  return ref $date ? $date : $self->db->parse_date($date);
}

sub calculate_invoice_dates {
  my ($self, %params) = @_;

  my $period_len = $self->get_period_length;
  my $cur_date   = $self->first_billing_date || $self->start_date;
  my $end_date   = $self->end_date           || DateTime->today_local->add(years => 10);
  my $start_date = $params{past_dates} ? undef                       : $self->get_previous_billed_period_start_date;
  $start_date    = $start_date         ? $start_date->add(days => 1) : $cur_date->clone;

  $start_date    = max($start_date, $params{start_date}) if $params{start_date};
  $end_date      = min($end_date,   $params{end_date})   if $params{end_date};

  my @dates;

  while ($cur_date <= $end_date) {
    push @dates, $cur_date->clone if $cur_date >= $start_date;

    $cur_date->add(months => $period_len);
  }

  return @dates;
}

1;
