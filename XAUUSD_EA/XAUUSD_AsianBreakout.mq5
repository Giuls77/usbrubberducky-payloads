//+------------------------------------------------------------------+
//|                                        XAUUSD_AsianBreakout.mq5  |
//|  EA XAUUSD: breakout del range asiatico all'apertura di Londra,  |
//|  filtrato dal trend (EMA su H1). Max 1-2 trade al giorno.        |
//|  Timeframe di esecuzione consigliato: M15                        |
//|  Tutti gli orari sono in ORARIO SERVER del broker.               |
//+------------------------------------------------------------------+
#property copyright "XAUUSD EA"
#property version   "1.01"
#property strict

#include <Trade\Trade.mqh>

input group "=== Generale ==="
input ulong  InpMagic            = 20260101;      // Magic number
input string InpComment          = "XAU_AsianBO"; // Commento ordini

input group "=== Rischio ==="
input double InpRiskPercent      = 0.5;   // Rischio per trade (% balance)
input double InpFixedLot         = 0.0;   // Lotto fisso (0 = usa % rischio)
input double InpRR               = 1.5;   // Rapporto Reward/Risk (TP = SL * RR)
input int    InpATRPeriod        = 14;    // Periodo ATR (M15)
input double InpSL_ATR           = 1.2;   // Distanza SL in multipli di ATR
input double InpMaxDailyLossPct  = 2.0;   // Stop giornaliero (% balance, 0 = off)
input int    InpMaxTradesDay     = 2;     // Max trade al giorno
input int    InpMaxSpreadPts     = 40;    // Spread massimo (punti)

input group "=== Sessioni (ora server) ==="
input int    InpAsianStartHour   = 0;     // Inizio range asiatico
input int    InpAsianEndHour     = 7;     // Fine range asiatico (escluso)
input int    InpTradeStartHour   = 8;     // Inizio finestra di ingresso
input int    InpTradeEndHour     = 17;    // Fine finestra di ingresso
input int    InpCloseHour        = 21;    // Chiusura forzata posizioni (0-23, -1 = off)

input group "=== Filtri ==="
input int    InpEMAPeriod        = 200;   // EMA trend filter (H1)
input double InpMinRangeATR      = 0.8;   // Range minimo (multipli ATR)
input double InpMaxRangeATR      = 4.0;   // Range massimo (multipli ATR)
input int    InpBreakBufferPts   = 20;    // Buffer oltre il range (punti)
input double InpMaxChaseATR      = 1.5;   // Non inseguire: max distanza dal range (ATR)

input group "=== Gestione posizione ==="
input bool   InpUseBreakeven     = true;  // BREAKEVEN: usa break-even (true/false)
input double InpBEFraction       = 0.5;   // BREAKEVEN: scatta a questa frazione del TP (0.5 = metà TP)
input int    InpBEOffsetPts      = 20;    // BREAKEVEN: punti oltre l'ingresso dove metto lo SL

CTrade   trade;
int      hATR = INVALID_HANDLE;
int      hEMA = INVALID_HANDLE;
datetime lastBarTime = 0;
datetime curDay = 0;
bool     buyDone = false, sellDone = false;
double   rangeHigh = 0, rangeLow = 0;
bool     rangeValid = false;

//+------------------------------------------------------------------+
int OnInit()
{
   hATR = iATR(_Symbol, PERIOD_M15, InpATRPeriod);
   hEMA = iMA(_Symbol, PERIOD_H1, InpEMAPeriod, 0, MODE_EMA, PRICE_CLOSE);
   if(hATR == INVALID_HANDLE || hEMA == INVALID_HANDLE)
   {
      Print("Errore creazione indicatori");
      return INIT_FAILED;
   }
   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(30);
   trade.SetTypeFillingBySymbol(_Symbol);
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   if(hATR != INVALID_HANDLE) IndicatorRelease(hATR);
   if(hEMA != INVALID_HANDLE) IndicatorRelease(hEMA);
}

//+------------------------------------------------------------------+
datetime DayStart(datetime t) { return t - (t % 86400); }

int HourOf(datetime t)
{
   MqlDateTime s;
   TimeToStruct(t, s);
   return s.hour;
}

//--- PnL chiuso di oggi (profit+swap+commission) e numero di entrate
void TodayStats(double &closedPnL, int &entries, bool &hadBuy, bool &hadSell)
{
   closedPnL = 0; entries = 0; hadBuy = false; hadSell = false;
   if(!HistorySelect(DayStart(TimeCurrent()), TimeCurrent() + 60)) return;
   int total = HistoryDealsTotal();
   for(int i = 0; i < total; i++)
   {
      ulong tk = HistoryDealGetTicket(i);
      if(tk == 0) continue;
      if((ulong)HistoryDealGetInteger(tk, DEAL_MAGIC) != InpMagic) continue;
      if(HistoryDealGetString(tk, DEAL_SYMBOL) != _Symbol) continue;
      long entry = HistoryDealGetInteger(tk, DEAL_ENTRY);
      long type  = HistoryDealGetInteger(tk, DEAL_TYPE);
      if(entry == DEAL_ENTRY_IN)
      {
         entries++;
         if(type == DEAL_TYPE_BUY)  hadBuy = true;
         if(type == DEAL_TYPE_SELL) hadSell = true;
      }
      closedPnL += HistoryDealGetDouble(tk, DEAL_PROFIT)
                 + HistoryDealGetDouble(tk, DEAL_SWAP)
                 + HistoryDealGetDouble(tk, DEAL_COMMISSION);
   }
}

int CountOpenPositions()
{
   int n = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong tk = PositionGetTicket(i);
      if(tk == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) == _Symbol &&
         (ulong)PositionGetInteger(POSITION_MAGIC) == InpMagic) n++;
   }
   return n;
}

double FloatingPnL()
{
   double p = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong tk = PositionGetTicket(i);
      if(tk == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) == _Symbol &&
         (ulong)PositionGetInteger(POSITION_MAGIC) == InpMagic)
         p += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
   }
   return p;
}

//--- Calcola il range asiatico di oggi
bool ComputeAsianRange()
{
   MqlRates r[];
   ArraySetAsSeries(r, true);
   int n = CopyRates(_Symbol, PERIOD_M15, 0, 200, r);
   if(n <= 0) return false;
   datetime today = DayStart(TimeCurrent());
   double hi = -DBL_MAX, lo = DBL_MAX;
   int cnt = 0;
   for(int i = 0; i < n; i++)
   {
      if(DayStart(r[i].time) != today) continue;
      int h = HourOf(r[i].time);
      if(h >= InpAsianStartHour && h < InpAsianEndHour)
      {
         hi = MathMax(hi, r[i].high);
         lo = MathMin(lo, r[i].low);
         cnt++;
      }
   }
   if(cnt < 4) return false;
   rangeHigh = hi; rangeLow = lo;
   return true;
}

//--- Lotto in base al rischio
double CalcLot(double slDist)
{
   double minL = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxL = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double lot;
   if(InpFixedLot > 0) lot = InpFixedLot;
   else
   {
      double tv = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE_LOSS);
      if(tv <= 0) tv = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
      double ts = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
      if(tv <= 0 || ts <= 0 || slDist <= 0) return 0;
      double lossPerLot = slDist / ts * tv;
      double risk = AccountInfoDouble(ACCOUNT_BALANCE) * InpRiskPercent / 100.0;
      lot = risk / lossPerLot;
   }
   lot = MathFloor(lot / step) * step;
   lot = MathMax(minL, MathMin(maxL, lot));
   return NormalizeDouble(lot, 2);
}

bool MarginOK(ENUM_ORDER_TYPE type, double lot, double price)
{
   double margin;
   if(!OrderCalcMargin(type, _Symbol, lot, price, margin)) return false;
   return margin < AccountInfoDouble(ACCOUNT_MARGIN_FREE) * 0.9;
}

//--- Apre il trade
void OpenTrade(bool isBuy, double atr)
{
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double slDist = atr * InpSL_ATR;
   double minStop = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * point;
   slDist = MathMax(slDist, minStop + 10 * point);
   double tpDist = slDist * InpRR;

   double price = isBuy ? ask : bid;
   double sl = isBuy ? price - slDist : price + slDist;
   double tp = isBuy ? price + tpDist : price - tpDist;
   sl = NormalizeDouble(sl, _Digits);
   tp = NormalizeDouble(tp, _Digits);

   double lot = CalcLot(slDist);
   if(lot <= 0) return;
   ENUM_ORDER_TYPE ot = isBuy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   if(!MarginOK(ot, lot, price)) { Print("Margine insufficiente"); return; }

   bool ok = isBuy ? trade.Buy(lot, _Symbol, 0, sl, tp, InpComment)
                   : trade.Sell(lot, _Symbol, 0, sl, tp, InpComment);
   if(ok)
   {
      if(isBuy) buyDone = true; else sellDone = true;
      PrintFormat("%s %.2f lot @ %.2f SL %.2f TP %.2f", isBuy ? "BUY" : "SELL", lot, price, sl, tp);
   }
   else
      PrintFormat("Ordine fallito: %d %s", trade.ResultRetcode(), trade.ResultRetcodeDescription());
}

//--- Break-even e chiusura di fine giornata
void ManagePositions()
{
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   int hour = HourOf(TimeCurrent());
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong tk = PositionGetTicket(i);
      if(tk == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol ||
         (ulong)PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;

      if(InpCloseHour >= 0 && hour >= InpCloseHour)
      {
         trade.PositionClose(tk);
         continue;
      }

      if(!InpUseBreakeven || InpBEFraction <= 0) continue;
      long   type = PositionGetInteger(POSITION_TYPE);
      double open = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl   = PositionGetDouble(POSITION_SL);
      double tp   = PositionGetDouble(POSITION_TP);
      if(tp == 0) continue;
      double trigger = MathAbs(tp - open) * InpBEFraction;
      double off = InpBEOffsetPts * point;
      if(type == POSITION_TYPE_BUY)
      {
         double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
         double newSL = NormalizeDouble(open + off, _Digits);
         if(bid - open >= trigger && sl < newSL && bid - newSL > point)
            trade.PositionModify(tk, newSL, tp);
      }
      else
      {
         double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
         double newSL = NormalizeDouble(open - off, _Digits);
         if(open - ask >= trigger && (sl == 0 || sl > newSL) && newSL - ask > point)
            trade.PositionModify(tk, newSL, tp);
      }
   }
}

//+------------------------------------------------------------------+
void OnTick()
{
   ManagePositions();

   // Logica di ingresso solo a nuova barra M15 (valuta la barra appena chiusa)
   datetime bt = iTime(_Symbol, PERIOD_M15, 0);
   if(bt == lastBarTime) return;
   lastBarTime = bt;

   datetime today = DayStart(TimeCurrent());
   if(today != curDay)
   {
      curDay = today;
      rangeValid = false;
      buyDone = sellDone = false;
   }

   int hour = HourOf(TimeCurrent());
   if(hour < InpTradeStartHour || hour >= InpTradeEndHour) return;

   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   if(dt.day_of_week == 0 || dt.day_of_week == 6) return;

   if(!rangeValid) rangeValid = ComputeAsianRange();
   if(!rangeValid) return;

   // Limiti giornalieri
   double closedPnL; int entries; bool hb, hs;
   TodayStats(closedPnL, entries, hb, hs);
   if(hb) buyDone = true;
   if(hs) sellDone = true;
   if(entries >= InpMaxTradesDay) return;
   if(CountOpenPositions() > 0) return;
   if(InpMaxDailyLossPct > 0)
   {
      double dayStartBal = AccountInfoDouble(ACCOUNT_BALANCE) - closedPnL;
      if(closedPnL + FloatingPnL() <= -dayStartBal * InpMaxDailyLossPct / 100.0) return;
   }

   // Spread
   long spread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   if(spread > InpMaxSpreadPts) return;

   // Indicatori
   double atrB[1], emaB[1];
   if(CopyBuffer(hATR, 0, 1, 1, atrB) != 1) return;
   if(CopyBuffer(hEMA, 0, 1, 1, emaB) != 1) return;
   double atr = atrB[0], ema = emaB[0];
   if(atr <= 0) return;

   // Qualità del range
   double range = rangeHigh - rangeLow;
   if(range < atr * InpMinRangeATR || range > atr * InpMaxRangeATR) return;

   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double buf = InpBreakBufferPts * point;
   double close1 = iClose(_Symbol, PERIOD_M15, 1);

   // BUY: chiusura sopra il range + sopra EMA
   if(!buyDone && close1 > rangeHigh + buf && close1 > ema &&
      close1 - rangeHigh <= atr * InpMaxChaseATR)
   {
      OpenTrade(true, atr);
      return;
   }
   // SELL: chiusura sotto il range + sotto EMA
   if(!sellDone && close1 < rangeLow - buf && close1 < ema &&
      rangeLow - close1 <= atr * InpMaxChaseATR)
   {
      OpenTrade(false, atr);
      return;
   }
}
//+------------------------------------------------------------------+
