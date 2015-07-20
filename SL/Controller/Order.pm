package SL::Controller::Order;

use strict;
use parent qw(SL::Controller::Base);

use SL::Helper::Flash;
use SL::ClientJS;
use SL::Presenter;

use SL::DB::Order;
use SL::DB::Customer;
use SL::DB::Vendor;
use SL::DB::TaxZone;
use SL::DB::Employee;
use SL::DB::Project;
use SL::DB::Default;
use SL::DB::Unit;

use SL::Helper::DateTime;

use List::Util qw(max);
use List::MoreUtils qw(none);

use Rose::Object::MakeMethods::Generic
(
 'scalar' => [ qw(order) ],
 'scalar --get_set_init' => [ qw(valid_types type cv js p) ],
);


# safety
__PACKAGE__->run_before('_check_auth');

__PACKAGE__->run_before('_load_or_new_order',
                        only => [ qw(add edit update save customer_vendor_changed set_item_values) ]);

__PACKAGE__->run_before('_setup',
                        only => [ qw(edit update save) ]);


#
# actions
#

sub action_add {
  my ($self) = @_;

  $self->order->transdate(DateTime->now_local());

  $self->_pre_render();
  $self->render(
    'order/form',
    title => $self->type eq _sales_order_type()    ? $::locale->text('Add Sales Order')
           : $self->type eq _purchase_order_type() ? $::locale->text('Add Purchase Order')
           : '',
    %{$self->{template_args}}
  );
}

sub action_edit {
  my ($self) = @_;

  $self->_pre_render();
  $self->render(
    'order/form',
    title => $self->type eq _sales_order_type()    ? $::locale->text('Edit Sales Order')
           : $self->type eq _purchase_order_type() ? $::locale->text('Edit Purchase Order')
           : '',
    %{$self->{template_args}}
  );
}

sub action_update {
  my ($self) = @_;

  $self->_pre_render();
  $self->render(
    'order/form',
    title => $self->type eq _sales_order_type()    ? $::locale->text('Edit Sales Order')
           : $self->type eq _purchase_order_type() ? $::locale->text('Edit Purchase Order')
           : '',
    %{$self->{template_args}}
  );
}

sub action_save {
  my ($self) = @_;

  $self->_save();

  my @redirect_params = (
    action => 'edit',
    type   => $self->type,
    id     => $self->order->id,
  );

  $self->redirect_to(@redirect_params);
}

sub action_customer_vendor_changed {
  my ($self) = @_;

  if ($self->type eq _sales_order_type()) {
    $self->order->customer(SL::DB::Manager::Customer->find_by_or_create(id => $::form->{cv_id}));

  } elsif ($self->type eq _purchase_order_type()) {
    $self->order->vendor(SL::DB::Manager::Vendor->find_by_or_create(id => $::form->{cv_id}));
  }

  if ($self->order->{$self->cv}->contacts && scalar @{ $self->order->{$self->cv}->contacts } > 0) {
    $self->js->show('#cp_row');
  } else {
    $self->js->hide('#cp_row');
  }

  if ($self->order->{$self->cv}->shipto && scalar @{ $self->order->{$self->cv}->shipto } > 0) {
    $self->js->show('#shipto_row');
  } else {
    $self->js->hide('#shipto_row');
  }

  $self->js
    ->replaceWith('#order_cp_id',     $self->build_contact_select)
    ->replaceWith('#order_shipto_id', $self->build_shipto_select)
    ->val('#order_taxzone_id', $self->order->{$self->cv}->taxzone_id)
    ->focus('#order_cv_id')
    ->render($self);
}

sub action_add_item_row {
  my ($self) = @_;

  my $random_id = join('_', 'new', Time::HiRes::gettimeofday(), int rand 1000000000000);
  my $row_as_html = $self->p->render('order/tabs/_row', ITEM => {id => $random_id});

  $self->js
    ->append('#row_table_id tbody', $row_as_html)
    ->focus('#row_table_id tr:last [id$="parts_id_name"]')
    ->off('[id^="order_orderitems"][id$="parts_id"]', 'change', 'set_item_values')
    ->on('[id^="order_orderitems"][id$="parts_id"]', 'change', 'set_item_values')
    ->render($self);
}

sub action_set_item_values {
  my ($self) = @_;

  my $part = SL::DB::Part->new(id => $::form->{parts_id})->load;

  my $is_new  = $::form->{item_id} =~ m{^new_};
  my $item_id = $is_new ? undef : $::form->{item_id};
  my $item    = SL::DB::Manager::OrderItem->find_by_or_create(id => $item_id);

  my $cv_class    = "SL::DB::" . ucfirst($self->cv);
  my $cv_discount = $::form->{cv_id}? $cv_class->new(id => $::form->{cv_id})->load->discount :0.0;

  $item->assign_attributes(
    parts_id  => $part->id,
    qty       => $::form->{qty}       ? $::form->parse_amount(\%::myconfig, $::form->{qty})       : 1.0,
    unit      => $part->unit,
    discount  => $::form->{discount}  ? $::form->parse_amount(\%::myconfig, $::form->{discount})  : $cv_discount,
    sellprice => $::form->{sellprice} ? $::form->parse_amount(\%::myconfig, $::form->{sellprice}) : $part->sellprice,
  );

  $self->order->add_items([$item]);
  $self->_setup();
  my $linetotal = _linetotal($self->order, $item);

  $self->js
    ->val( '#' . $::form->{qty_dom_id},       $item->qty_as_number)
    ->val( '#' . $::form->{unit_dom_id},      $item->unit)
    ->val( '#' . $::form->{sellprice_dom_id}, $item->sellprice_as_number)
    ->val( '#' . $::form->{discount_dom_id},  $item->discount_as_number)
    ->run('recalc_linetotal', $::form->{item_id}, $::form->format_amount(\%::myconfig, $linetotal, -2))
    ->render($self);
}


#
# helpers
#

sub init_valid_types {
  [ _sales_order_type(), _purchase_order_type() ];
}

sub init_type {
  my ($self) = @_;

  if (none { $::form->{type} eq $_ } @{$self->valid_types}) {
    die "Not a valid type for order";
  }

  $self->type($::form->{type});
}

sub init_cv {
  my ($self) = @_;

  my $cv = $self->type eq _sales_order_type()    ? 'customer'
         : $self->type eq _purchase_order_type() ? 'vendor'
         : die "Not a valid type for order";

  return $cv;
}

sub init_js {
  SL::ClientJS->new;
}

sub init_p {
  SL::Presenter->get;
}

sub _check_auth {
  my ($self) = @_;

  my $right_for = { map { $_ => $_.'_edit' } @{$self->valid_types} };

  my $right   = $right_for->{ $self->type };
  $right    ||= 'DOES_NOT_EXIST';

  $::auth->assert($right);
}

sub build_contact_select {
  my ($self) = @_;

  $self->p->select_tag('order.cp_id', [ $self->order->{$self->cv}->contacts ],
                       value_key  => 'cp_id',
                       title_key  => 'full_name_dep',
                       default    => $self->order->cp_id,
                       with_empty => 1,
                       style      => 'width: 300px',
  );
}

sub build_shipto_select {
  my ($self) = @_;

  $self->p->select_tag('order.shipto_id', [ $self->order->{$self->cv}->shipto ],
                       value_key  => 'shipto_id',
                       title_key  => 'displayable_id',
                       default    => $self->order->shipto_id,
                       with_empty => 1,
                       style      => 'width: 300px',
  );
}

sub _load_or_new_order {
  my ($self) = @_;

  return $self->order(SL::DB::Manager::Order->find_by_or_create(id => $::form->{id}));
}

sub _setup {
  my ($self) = @_;

  $::form->{order}->{ $self->cv . '_id' } = delete $::form->{order}->{cv_id} if $::form->{order}->{cv_id};
  $self->order->assign_attributes(%{$::form->{order}});

  # bb: todo: currency later
  $self->order->currency_id($::instance_conf->get_currency_id());

  my %pat = $self->order->calculate_prices_and_taxes();

  foreach my $tax_chart_id (keys %{ $pat{taxes} }) {
    my $tax = SL::DB::Manager::Tax->find_by(chart_id => $tax_chart_id);
    push(@{ $self->{taxes} }, { amount => $pat{taxes}->{$tax_chart_id},
                                tax    => $tax });
  }

  $self->{totalweight}  = 0;
  foreach my $item ($self->order->items) {
    $item->{linetotal} = _linetotal($self->order, $item);
    my $item_unit = SL::DB::Manager::Unit->find_by(name => $item->unit);
    my $part_unit = SL::DB::Manager::Unit->find_by(name => $item->part->unit);
    my $base_qty = $item_unit->convert_to($item->qty, $part_unit);
    $item->{weight} = $base_qty * $item->part->weight;

    # Calculate total weight/tare weight
    $self->{totalweight} += $item->{weight};
  }
}

sub _save {
  my ($self) = @_;

  my $db = $self->order->db;

  $db->do_transaction(
    sub {
      $self->order->save();
  }) || die($db->error);
}


sub _pre_render {
  my ($self) = @_;

  $self->{all_taxzones}  = SL::DB::Manager::TaxZone->get_all();
  $self->{all_employees} = SL::DB::Manager::Employee->get_all(where => [ or => [ id => $self->order->employee_id,
                                                                                 deleted => 0 ] ],
                                                              sort_by => 'name');
  $self->{all_projects}  = SL::DB::Manager::Project->get_all(where => [ or => [ id => $self->order->globalproject_id,
                                                                                active => 1 ] ],
                                                             sort_by => 'projectnumber');

  $self->{current_employee_id} = SL::DB::Manager::Employee->current->id;
  $self->{show_weight}         = SL::DB::Default->get()->show_weight;
}

# The following subs are more or less copied/pasted from SL::DB::Helper::PriceTaxCalculator.
sub _linetotal {
  my ($order, $item) = @_;

  # bb: todo: currencies are not handled by now
  my $exchangerate = _get_exchangerate($order);

  my $num_dec   = max 2, _num_decimal_places($item->sellprice);
  my $discount  = _round($item->sellprice * ($item->discount || 0),           $num_dec);
  my $sellprice = _round($item->sellprice - $discount,                        $num_dec);
  my $linetotal = _round($sellprice * $item->qty / $item->price_factor,       2       ) * $exchangerate;
  $linetotal    = _round($linetotal,                                          2       );

  return $linetotal;
}

sub _get_exchangerate {
  my ($order) = @_;
  require SL::DB::Default;

  my $exchangerate = 1;
  my $currency = $order->currency_id ? $order->currency->name || '' : '';
  if ($currency ne SL::DB::Default->get_default_currency) {
    $exchangerate = $::form->check_exchangerate(\%::myconfig, $currency, $order->transdate, $order->is_sales ? 'buy' : 'sell');
  }

  return $exchangerate;
}

sub _num_decimal_places {
  return length( (split(/\./, '' . ($_[0] * 1), 2))[1] || '' );
}

sub _round {
  return $::form->round_amount(@_);
}

sub _sales_order_type {
  'sales_order';
}

sub _purchase_order_type {
  'purchase_order';
}

1;
