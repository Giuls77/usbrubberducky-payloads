# XAUUSD Asian Breakout EA (MQL5)

EA per MetaTrader 5 che lavora 24/5 in autonomia su XAUUSD.

## Strategia
1. **Range asiatico**: massimo/minimo tra `AsianStartHour` e `AsianEndHour` (ora server).
2. **Ingresso** (finestra 08:00–17:00 server, a chiusura di candela M15):
   - BUY se la candela chiude sopra il massimo del range (+ buffer) **e** sopra EMA200 H1.
   - SELL se chiude sotto il minimo (− buffer) **e** sotto EMA200 H1.
3. **SL** = ATR(14, M15) × 1.2, **TP** = SL × 1.5. Break-even a metà TP (attivabile con `Usa break-even` true/false).
4. Filtri: range né troppo piccolo né troppo grande (in ATR), spread massimo, non inseguire un breakout già esteso, niente weekend.
5. Max 2 trade/giorno (uno per direzione), stop giornaliero 2% del balance, chiusura forzata alle 21:00 server.
6. Lotto calcolato sul rischio (0.5% per trade di default) o lotto fisso.

## Installazione
1. In MT5: `File > Apri cartella dati > MQL5/Experts`, copia `XAUUSD_AsianBreakout.mq5`.
2. Apri MetaEditor (F4), compila (F7).
3. Apri un grafico **XAUUSD M15**, trascina l'EA, abilita *Algo Trading*.
4. Per 24/7 reale usa un VPS (MT5: `Visualizza > Terminale > VPS`).

## Importante
- Gli orari sono in **ora server del broker**: verifica il tuo GMT offset e adatta `AsianStartHour/EndHour`, `TradeStartHour/EndHour` (es. server GMT+2/+3: Londra apre intorno alle 10:00 server).
- Non l'ho potuto compilare né backtestare qui: **compila e fai Strategy Tester** (tick reali, almeno 2-3 anni) e ottimizza solo parametri robusti, poi demo prima del conto reale.
- Nessuna strategia vince "quasi sempre": questa punta a un win rate ~45-55% con RR 1.5. Il rischio per trade è contenuto, ma le perdite sono possibili.
- L'EA gira dentro MT5 e non richiede MCP a runtime; MCP serve solo se vuoi che Claude Code lanci backtest/legga i report.
