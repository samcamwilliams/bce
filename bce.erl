-module(bce).
-compile(export_all).
-export([start/0]).

%% run with: erl -pa /usr/local/lib/yaws/ebin/ -s bce start -s bce margin_over_time
%% Get graph with bce:show_graph()

start() ->
	inets:start(),
	ssl:start().

get_orders() ->
	case httpc:request("https://bitcoin-24.com/api/USD/orderbook.json") of
		{ok, {{_, 200, _}, _, Body}} ->
			{ok, {struct, [{"asks", {array, RawAsks}}, {"bids", {array, RawBids}}]}} = json2:decode_string(Body),
			Asks = lists:reverse(order(make_orders(RawAsks))),
			Bids = order(make_orders(RawBids)),
			{ok, Asks, Bids};
		{ok, {{_, Error, _}, _, _}} -> d({get_error, Error}), error;
		X -> d({get_error, X}), error
	end.

make_orders([]) -> [];
make_orders([{array, [Pri, Qty]}|Rest]) ->
	[{list_to_float(Pri), list_to_float(Qty)}] ++ make_orders(Rest).

order(Orders) ->
	lists:sort(
		fun({A,_}, {B,_}) ->
			A >= B
		end,
		Orders
	).

get_current() ->
	{ok, [{Sell, _}|_], [{Buy, _}|_]} = get_orders(),
	{Buy, Sell}.

margin_over_time() ->
	start(),
	spawn(fun() -> margin_over_time({0, []}) end).

margin_over_time({T, OldS}) ->
	{Buy, Sell} = get_current(),
	S = OldS ++ [{T, Sell, Buy}],
	file:write_file("bce_log.csv",
		lists:flatten(
			lists:map(
				fun({Time, XSell, XBuy}) ->
					io_lib:format("~w ~w ~w~n", [Time, XSell, XBuy])
				end,
				S
			)
		)
	),
	receive
		stop -> ok
	after 1000 * 60 -> margin_over_time({T + 1, S})
	end.

-record(state, {
	usd = 50.0,
	btc = 0.0,
	order = none,
	best,
	buy
}).
-define(CUT, 0.25). %% percent
-define(LMAR, 0.25). %% percent.
-define(DMAR, 6.0). %% percent.
-define(RSET, 5). %% BTC

agent() -> agent(#state{}).

agent(S) ->
	NextS =
		try perform_logic(S) of
			NewS -> NewS
		catch
			_:_ -> S
		end,
	receive
		code_change -> ?MODULE:agent(NextS);
		stop -> ok
	after 1000 * 20 -> agent(NextS)
	end.

perform_logic(S) ->
	{ok, Sales = [Sell = {SellPrice, _SellQty}|_], Buys = [Buy = {BuyPrice, _BuyQty}|_]} = get_orders(),
	{BuyDir, SellDir} =
		case S#state.best of
			undefined -> {stable, stable};
			{{OldBuyPrice, _}, {OldSellPrice, _}} ->
				{
					price_check(OldBuyPrice, BuyPrice),
					price_check(OldSellPrice, SellPrice)
				}
		end,
	OrderS = 
		case S#state.order of
			none ->
				if S#state.btc =/= 0.0 -> 
					S#state { order = {sell, S#state.btc, calculate_sell(S#state.buy, Sales)} };
				true ->
					case calculate_buy(Buys, Sales) of
						pass -> S;
						Price -> S#state { order = {buy, (S#state.usd / Price), Price} }
					end
				end;
			{sell, Qty, Price} when Price < SellPrice, SellDir == rising ->
				S#state {
					order = none,
					usd = S#state.usd + (Qty * Price),
					btc = S#state.btc - Qty,
					buy = undefined
				};
			{sell, _, Price} when Price > SellPrice ->
				S#state {
					order = {sell, S#state.btc, calculate_sell(S#state.buy, Sales) }
				};
			{buy, Qty, Price} when Price > BuyPrice, BuyDir == falling ->
				S#state {
					order = {sell, S#state.btc + Qty, calculate_sell(Price, Sales)},
					usd = S#state.usd - (Qty * Price),
					btc = S#state.btc + Qty,
					buy = Price
				};
			{buy, _, _Price} ->
				case calculate_buy(Buys, Sales) of
					pass -> S#state { order = none };
					NextPrice -> S#state { order = {buy, (S#state.usd / NextPrice), NextPrice} }
				end;
			_ -> S
		end,
	report(OrderS, BuyPrice, SellPrice),
	OrderS#state { best = {Buy, Sell} }.

report(S, BuyPrice, SellPrice) ->
	io:format("     === BTC AGENT REPORT ===     ~n"),
	io:format("     Wallet: $~.2f, ~.2f BTC~n", [S#state.usd, S#state.btc]),
	io:format("     Current est worth $~.2f~n",
		[
			case S#state.order of
				none -> S#state.usd;
				{sell, XQty, XPrice} -> XQty * XPrice;
				{buy, _, _} -> S#state.usd
			end
		]
	),
	io:format("     Current order:~n"),
	case S#state.order of
		{XOp, XXQty, XPri} -> io:format("     ~s ~.2f BTC at $~.2f~n", [format_op(XOp), XXQty, XPri]);
		none -> io:format("     Wait~n")
	end,
	io:format("     Best buy:  $~.2f~n", [BuyPrice]),
	io:format("     Best sell: $~.2f~n", [SellPrice]),
	io:format("     ========================     ~n~n").

format_op(A) ->
	[H|R] = atom_to_list(A),
	[H - 32] ++ R.

calculate_sell(BuyPrice, Sells) ->
	case
		select_sell( Processed = 
			element(1,
				lists:foldl(
					fun({Price, Qty}, {List, AccQty}) ->
						XPrice = adjust_pc(-(?CUT), Price),
						{List ++ [{XPrice, margin(BuyPrice, XPrice), AccQty + Qty}], AccQty + Qty}
					end,
					{[], 0},
					lists:sublist(Sells, 10)
				)
			)
		) of
		reset -> element(1, hd(Processed));
		Price -> Price
	end.

select_sell([]) -> reset;
select_sell([{Price, _, Qty}|_]) when Qty > ?RSET -> Price;
select_sell([{Price, Margin, _}|_]) when Margin > ?LMAR -> Price;
select_sell([_|R]) -> select_sell(R).

calculate_buy([{BuyPrice,_}|_], [{SellPrice,_}|_]) ->
	case margin(Price = adjust_pc(?CUT, BuyPrice), adjust_pc(-(?CUT), SellPrice)) of
		X when X >= ?DMAR -> Price;
		_ -> pass
	end.

margin(X, Y) ->
	(Y / (X / 100)) - 100.

adjust_pc(Amount, Price) ->
	(Price / 100) * (100 + Amount).

price_check(Old, New) when Old < New -> rising;
price_check(Price, Price) -> stable;
price_check(_, _) -> falling.

show_graph() ->
	os:cmd(
		"gnuplot << EOF
set datafile separator ' '
set terminal wxt enhanced font 'Verdana,10' persist
set yrange [0:250]
set xrange [0:180]
plot 'bce_log.csv' using 2 title 'sell' with linespoints, 'bce_log.csv' using 3 title 'buy' with linespoints
EOF"
	).



d(X) ->
	io:format("~p~n", [X]),
	X.
