bce
===

Simulated margin trader for (now defunct) bitcoin exchange, bitcoin-24. Renders graphs with gnuplot.

##Usage##

Start the trader like this (assuming default YAWS instalation directory:
```
erl -pa /usr/local/lib/yaws/ebin/ -s bce start -s bce margin_over_time
```
Generate a graph of wallet worth over time:
```
bce:show_graph()
```

Changing some of the magic values may also be appropriate. Below is a summary table each value and it's function.

|Name|Unit|Function|
--- | --- | ---
CUT|Percent|The exchange fee per transaction
LMAR|Percent|Lowest margin - do not sell if profit margin lower than this
DMAR|Percent|Desired margin - buy when potential profit margin is greater than this
RSET|Bitcoins|Adjust the current sell price if this much BTC is available cheaper

##Future Work##

* Convert to use a functioning exchange.
* Add functionality for running in 'real mode' and performing real trades.
* Add a web interface that allows remote control and management of the trader.
