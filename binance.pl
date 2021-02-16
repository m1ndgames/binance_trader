#!/usr/bin/perl
use strict;
use warnings;
use Binance::API;
use Data::Dumper;
use Log::Log4perl;
my $log4perl = Log::Log4perl->init("log4perl.conf");
my $log = Log::Log4perl::get_logger("Binance");
use WWW::Telegram::BotAPI;
use Term::ANSIColor;
use POSIX qw/strftime/;
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

sub msg_handler {
        chomp(my $type = shift);
        chomp(my $msg = shift);

        my $state_color;
        if ($type eq 'info') {
                $state_color = 'green';
        } elsif ($type eq 'warn') {
                $state_color = 'yellow';
        } elsif ($type eq 'error') {
                $state_color = 'red';
        }

        color('reset');
        my $timestring = colored([$state_color], strftime('%Y-%m-%d %H:%M:%S',localtime),"" );
        color('reset');

        if ($type eq 'info') {
                $log->info($msg);
        } elsif ($type eq 'warn') {
                $log->warn($msg);
        } elsif ($type eq 'error') {
                $log->error($msg);
        }

        print ("$timestring - " . colored([$state_color], $type) . " - $msg\n");
}

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

sub shorten_number {
        my $number = shift;
        my $precision = shift;
        if ($number =~ /(\d+)\.(\d+)/) {
                my $full = $1;
                my $fraction = $2;
                while (length $fraction > $precision) {
                        chop $fraction;
                }
                return "$full.$fraction";
        }
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
                                                &msg_handler("warn", "Found old buy order, deleting...");
                                                $api->cancel_order(
                                                        symbol => $cfg->val('token', 'pair'),
                                                        orderId => $order_id,
                                                        recvWindow => 5000
                                                );
                                                $last_buy_price = undef;
                                                $sell_price = undef;
                                                unlink("binance.data");

                                        } elsif ($orders->[$s]->{'clientOrderId'} =~ /auto_sell_order/) {
                                                &msg_handler("warn", "Found old sell order, deleting...");
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
                &msg_handler("warn", "Buy order failed: Order too low (10€ minimum)");
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
                quantity => &shorten_number($order_amount, 1),
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
                        &msg_handler("warn", "Sell order failed: Order vlaue too low.");
                }
                return 0;
        }
}

sub order_handler {
        my $type = shift;

        # Get tradin pair Balance
        my ($currency_balance_free, $currency_balance_locked, $token_balance_free, $token_balance_locked) = &update_currency_balance($currency, $cfg->val('token', 'token'));
        my $change = abs($price - $newprice);
        my $round_change = sprintf("%.5f", $change);
        if ($round_change == 0.00000) {
                &msg_handler("info", "Price:   " . $cfg->val('token', 'token') . " = " . &shorten_number($newprice, 5) . " $currency");
        } else {
                if ($type eq 'SELL') {
                        &msg_handler("info", "Price:   " . $cfg->val('token', 'token') . " = " . &shorten_number($newprice, 5) . " $currency - Change: " . colored($round_change,'green'));
                } else {
                        &msg_handler("info", "Price:   " . $cfg->val('token', 'token') . " = " . &shorten_number($newprice, 5) . " $currency - Change: " . colored($round_change,'red'));
                }
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
                if ($buy_trigger_counter != 0) {
                        &msg_handler("info", "Balance: $currency = " . &shorten_number($currency_balance_free, 2) . " " . $cfg->val('token', 'token') . " = " . &shorten_number($token_balance_free, 1) . " Buy Trigger: $buy_trigger_counter/" . $cfg->val('base', 'buy_trigger'));
                } else {
                        &msg_handler("info", "Balance: $currency = " . &shorten_number($currency_balance_free, 2) . " " . $cfg->val('token', 'token') . " = " . &shorten_number($token_balance_free, 1));
                }
        } else {
                if ($sell_trigger_counter != 0) {
                        &msg_handler("info", "Balance: $currency = " . &shorten_number($currency_balance_free, 2) . " " . $cfg->val('token', 'token') . " = " . &shorten_number($token_balance_free, 1) . " Buy price: $last_buy_price Sell price: $sell_price Sell Trigger: $sell_trigger_counter/" . $cfg->val('base', 'sell_trigger'));
                } else {
                        &msg_handler("info", "Balance: $currency = " . &shorten_number($currency_balance_free, 2) . " " . $cfg->val('token', 'token') . " = " . &shorten_number($token_balance_free, 1) . " Buy price: $last_buy_price Sell price: $sell_price");
                }
        }

        if ((($type eq 'BUY') or ($type eq 'SELL')) and (($token_balance_free > 1) and ($last_buy_price >= ($cfg->val('base', 'take_profit') + $last_buy_price)))) {
                my $sell_order_action = &sell_order($newprice, $token_balance_free);

                if ($sell_order_action == 1) {
                        &msg_handler("info", "Selling " . $token_balance_free . " " . $cfg->val('token', 'token') . " for $newprice $currency (" . ($token_balance_free * $newprice) . " $currency)");
                        &send_telegram_message("Selling " . $token_balance_free . " " . $cfg->val('token', 'token') . " for $newprice $currency (" . ($token_balance_free * $newprice) . " $currency)");
                        $last_buy_price = undef;
                        $sell_price = undef;
                        unlink("binance.data");
                }
        } elsif (($type eq 'BUY') and ($currency_balance_free > 10) and ($newprice < $cfg->val('base', 'max_price'))) {
                my $buy_change = ($newprice - $price);
                if ($change > $cfg->val('base', 'change_limit')) {
                        if ($buy_trigger_counter >= $cfg->val('base', 'buy_trigger')) {
                                my $buy_order_action = &buy_order($currency_balance_free);
                                if ($buy_order_action == 1) {
                                        &msg_handler("info", "Buying " . $cfg->val('token', 'token') . " for $price \($currency_balance_free $currency\))");
                                        &send_telegram_message("Buying " . $cfg->val('token', 'token') . " for $price \($currency_balance_free $currency\))");
                                }
                        }
                }
        } elsif (($type eq 'SELL') and ($token_balance_free > 1)) {
                if (!$last_buy_price) {
                        &msg_handler("error", "Error! I dont know the last buy price... please sort this out!");
                        exit 0;
                }

                my $sell_change = ($price - $newprice);
                if ($newprice > $sell_price) {
                        if ($change > $cfg->val('base', 'change_limit')) {
                                if ($sell_trigger_counter >= $cfg->val('base', 'sell_trigger')) {
                                        my $sell_order_action = &sell_order($newprice, $token_balance_free);
                                        if ($sell_order_action == 1) {
                                                &msg_handler("info", "Selling " . $token_balance_free . " " . $cfg->val('token', 'token') . " for $newprice $currency (" . ($token_balance_free * $newprice) . " $currency)");
                                                &send_telegram_message("Selling " . $token_balance_free . " " . $cfg->val('token', 'token') . " for $newprice $currency (" . ($token_balance_free * $newprice) . " $currency)");
                                                $last_buy_price = undef;
                                                $sell_price = undef;
                                                unlink("binance.data");
                                        }
                                }
                        }
                }

        }
        &validate_open_orders(); # Delete orders which were not triggered in time
}

# Start up info
&msg_handler("info", "Tradingpair is " . $cfg->val('token', 'pair') . ". Minimum change is " . $cfg->val('base', 'change_limit') . ". Minimum profit is " . $cfg->val('base', 'minimum_profit') . ". Take profit at " . $cfg->val('base', 'take_profit') . ". Max price is " . $cfg->val('base', 'max_price') . ". Timer is set to " . $timer . " seconds.");
if ($cfg->val('base', 'testmode') == 1) {
        &msg_handler("warn", "Testmode is active - orders wont be executed");
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
