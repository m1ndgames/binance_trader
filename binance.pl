#!/usr/bin/perl
use strict;
use warnings;
use Binance::API;
use Data::Dumper;
use Log::Log4perl;
my $log4perl = Log::Log4perl->init("log4perl.conf");
my $log = Log::Log4perl::get_logger("Binance");
use WWW::Telegram::BotAPI;
use Config::IniFiles;
my $price;
my $newprice;
my $last_buy_price;
my $sell_price;
my $buy_trigger_counter = 0;
my $sell_trigger_counter = 0;
my $cfg = Config::IniFiles->new( -file => "binance.cfg" );

my $currency = $cfg->val('token', 'currency');
my $timer = $cfg->val('base', 'timer');

my $api = Binance::API->new(
    apiKey     => $cfg->val('binance', 'apikey_public'),
    secretKey  => $cfg->val('binance', 'apikey_private'),
    recvWindow => 5000,
);

sub send_telegram_message {
        my $text = shift;
        my $telegram_api = WWW::Telegram::BotAPI->new (
                token => $cfg->val('telegram', 'apikey'),
                async => 0
        );

        $telegram_api->sendMessage ({
                chat_id => $cfg->val('telegram', 'channel_id'),
                text    => $text
        });
}

sub update_token_price {
        my $check_token = shift;
        my $ticker = $api->ticker( symbol => $check_token );
        my $price = $ticker->{'lastPrice'};
        return $price;
}

sub write_buy_price {
        chomp(my $price = shift);
        open(FH, '>', 'binance.data') or die $!;
        print FH $price;
        close(FH);
}

sub read_buy_price {
        if (open(FH, '<', 'binance.data')) {
                my $saved_price;
                foreach (<FH>) {
                        $saved_price = $_;
                }
                close(FH);
                return $saved_price;
        } else {
                $last_buy_price = undef;
                $sell_price = undef;
        }
}

sub update_currency_balance {
        my $check_currency = shift;
        my $check_token = shift;
        my $wallet = $api->account();
        my $balance = $wallet->{'balances'};
        my ($c_f, $c_l, $t_f, $t_l);
        foreach my $s (0 .. $#$balance) {
                if ($balance->[$s]->{'asset'} eq $check_currency) {
                        $c_f = $balance->[$s]->{'free'};
                        $c_l = $balance->[$s]->{'locked'};
                } elsif ($balance->[$s]->{'asset'} eq $check_token) {
                        $t_f = $balance->[$s]->{'free'};
                        $t_l = $balance->[$s]->{'locked'};
                }
        }
        return ($c_f, $c_l, $t_f ,$t_l);
}

sub validate_open_orders {
        my $orders = $api->open_orders(
                symbol => $cfg->val('token', 'pair')
        );

        if ($orders) {
                foreach my $s (0 .. $#$orders) {
                        if ($orders->[$s]->{'status'} eq 'NEW') {
                                my $order_timestamp = $orders->[$s]->{'time'};
                                if ($order_timestamp < time) {
                                        my $order_id = $orders->[$s]->{'orderId'};

                                        if ($orders->[$s]->{'clientOrderId'} =~ /auto_buy_order/) {
                                                $log->warn("Found old buy order, deleting...");
                                                $api->cancel_order(
                                                        symbol => $cfg->val('token', 'pair'),
                                                        orderId => $order_id,
                                                        recvWindow => 5000
                                                );
                                                $last_buy_price = undef;
                                                $sell_price = undef;
                                                unlink("binance.data");

                                        } elsif ($orders->[$s]->{'clientOrderId'} =~ /auto_sell_order/) {
                                                $log->warn("Found old sell order, deleting...");
                                                $api->cancel_order(
                                                        symbol => $cfg->val('token', 'pair'),
                                                        orderId => $order_id,
                                                        recvWindow => 5000
                                                );
                                        }
                                }
                        }
                }
        }
}

sub buy_order {
        my $currency_amount = shift;
        my $client_orderid = "auto_buy_order_" . int(rand(9999));
        my $api_response = $api->order(
                symbol => $cfg->val('token', 'pair'),
                side   => 'BUY',
                type   => 'MARKET',
                quoteOrderQty => $currency_amount,
                newClientOrderId => $client_orderid,
                newOrderRespType => 'FULL',
                test => $cfg->val('base', 'testmode')
        );
        if ($api_response->{'fills'}) {
                &write_buy_price($api_response->{'fills'}[0]->{'price'});
                $buy_trigger_counter = 0;
                return 1;
        } elsif ($api_response->decoded_content =~ /MIN_NOTIONAL/) {
                $log->warn("Buy order failed: Order too low (10€ minimum)");
        }
}

sub sell_order {
        my $order_price = shift;
        my $order_amount = shift;
        my $client_orderid = "auto_sell_order_" . int(rand(9999));
        $order_price += 0;

        my $api_response = $api->order(
                symbol => $cfg->val('token', 'pair'),
                side   => 'SELL',
                type   => 'LIMIT',
                timeInForce => 'GTC',
                quantity => int($order_amount),
                price => $order_price,
                newOrderRespType => 'FULL',
                newClientOrderId => $client_orderid,
                test => $cfg->val('base', 'testmode')
        );
        #print Dumper $api_response;
        if ($api_response->{'orderId'}) {
                $sell_trigger_counter = 0;
                return 1;
        } else {
                if ($api_response->decoded_content =~ /MIN_NOTIONAL/) {
                        $log->warn("Sell order failed: Order vlaue too low.");
                }
                return 0;
        }
}

sub order_handler {
        my $type = shift;

        # Get tradin pair Balance
        my ($currency_balance_free, $currency_balance_locked, $token_balance_free, $token_balance_locked) = &update_currency_balance($currency, $cfg->val('token', 'token'));
        my $change = abs($price - $newprice);
        if ($type eq 'SELL') {
                $log->info($cfg->val('token', 'token') . " Price:\t$newprice\tChange: +$change");
        } else {
                $log->info($cfg->val('token', 'token') . " Price:\t$newprice\tChange: -$change");
        }

        $last_buy_price = &read_buy_price();
        if ($last_buy_price) {
                chomp($last_buy_price);
                $sell_price = ($last_buy_price + $cfg->val('base', 'minimum_profit'));
        }

        if (($type eq 'SELL') and ($change > $cfg->val('base', 'change_limit'))) {
                $sell_trigger_counter = $sell_trigger_counter + 1;
                $buy_trigger_counter = 0;
        }
        if (($type eq 'BUY') and ($change > $cfg->val('base', 'change_limit')) and ($newprice < $cfg->val('base', 'max_price'))) {
                $buy_trigger_counter = $buy_trigger_counter + 1;
                $sell_trigger_counter = 0;
        }


        if (!$last_buy_price) {
                $log->info("$currency: $currency_balance_free " . $cfg->val('token', 'token') . ": $token_balance_free Buy Trigger: $buy_trigger_counter/" . $cfg->val('base', 'buy_trigger'));
        } else {
                $log->info("$currency: $currency_balance_free " . $cfg->val('token', 'token') . ": $token_balance_free Buy price: $last_buy_price Sell price: $sell_price Sell Trigger: $sell_trigger_counter/" . $cfg->val('base', 'sell_trigger'));
        }

        if ((($type eq 'BUY') or ($type eq 'SELL')) and ($token_balance_free > 1) and ($last_buy_price < ($cfg->val('base', 'take_profit') + $last_buy_price))) {
                my $sell_order_action = &sell_order($newprice, $token_balance_free);
                if ($sell_order_action == 1) {
                        $log->info("Selling " . $token_balance_free . $cfg->val('token', 'token') . " for $newprice");
                        &send_telegram_message("Selling " . $token_balance_free . $cfg->val('token', 'token') . " for $newprice");
                        $last_buy_price = undef;
                        $sell_price = undef;
                        $sell_trigger_counter = 0;
                        unlink("binance.data");
                }
        } elsif (($type eq 'BUY') and ($currency_balance_free > 10) and ($newprice < $cfg->val('base', 'max_price'))) {
                my $buy_change = ($newprice - $price);
                if ($change > $cfg->val('base', 'change_limit')) {
                        if ($buy_trigger_counter >= $cfg->val('base', 'buy_trigger')) {
                                my $buy_order_action = &buy_order($currency_balance_free);
                                if ($buy_order_action == 1) {
                                        $log->info("Buying " . $cfg->val('token', 'token') . " for $price \($currency_balance_free $currency\))");
                                        &send_telegram_message("Buying " . $cfg->val('token', 'token') . " for $price \($currency_balance_free $currency\))");
                                }
                        }
                }
        } elsif (($type eq 'SELL') and ($token_balance_free > 1)) {
                if (!$last_buy_price) {
                        $log->error("Error! I dont know the last buy price... please sort this out!");
                        exit 0;
                }

                my $sell_change = ($price - $newprice);
                if ($newprice > $sell_price) {
                        if ($change > $cfg->val('base', 'change_limit')) {
                                if ($sell_trigger_counter >= $cfg->val('base', 'sell_trigger')) {
                                        my $sell_order_action = &sell_order($newprice, $token_balance_free);
                                        if ($sell_order_action == 1) {
                                                $log->info("Selling " . $token_balance_free . $cfg->val('token', 'token') . " for $newprice");
                                                &send_telegram_message("Selling " . $token_balance_free . $cfg->val('token', 'token') . " for $newprice");
                                                $last_buy_price = undef;
                                                $sell_price = undef;
                                                $sell_trigger_counter = 0;
                                                unlink("binance.data");
                                        }
                                }
                        }
                }

        }
        &validate_open_orders(); # Delete orders which were not triggered in time
}

# Start up info
$log->info("Starting...");
$log->info("Tradingpair is " . $cfg->val('token', 'pair') . ". Minimum change is " . $cfg->val('base', 'change_limit') . ". Minimum profit is " . $cfg->val('base', 'minimum_profit') . ". Take profit at " . $cfg->val('base', 'take_profit') . ". Max price is " . $cfg->val('base', 'max_price') . ". Timer is set to " . $timer . " seconds.");
if ($cfg->val('base', 'testmode') == 1) {
        $log->warn("Testmode is active - orders wont be executed");
}

# Main Loop
while (1) {
        # Get the new price
        if (!$price) {
                $price = &update_token_price($cfg->val('token', 'pair'));
                $newprice = $price;
                next;
        } else {
                $newprice = &update_token_price($cfg->val('token', 'pair'));
        }

        # Start the order handler
        if ($newprice > $price) {
                $buy_trigger_counter = 0;
                &order_handler('SELL');
        } elsif ($price > $newprice) {
                $sell_trigger_counter = 0;
                &order_handler('BUY');
        }

        $price = $newprice; # reset price
        sleep($timer);
}
