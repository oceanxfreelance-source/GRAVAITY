//+------------------------------------------------------------------+
//|                                       XAU_Aggressive_Scalper.mq5 |
//|  MT5 Expert Advisor port of tradingview/xau_scalper.pine         |
//|                                                                  |
//|  Logic (evaluated once per closed bar, default M5):              |
//|  - Trend: close vs EMA200, EMA9 > EMA21, Supertrend(3,10),       |
//|    M15 close vs M15 EMA50 (previous closed M15 bar)              |
//|  - Strength: ADX(14, Wilder) > 26 with matching +DI / -DI        |
//|  - Pullback: low touched EMA21 within the last 5 bars            |
//|  - Trigger: candle closes beyond EMA9 and the previous high/low  |
//|    (or MACD histogram crosses zero)                              |
//|  - RSI 50-72 for buys, 28-50 for sells, tick volume > average    |
//|  - London / New York session only (07:00-17:00 UTC)              |
//|  - Fixed stop / target in price (USD per oz): SL 4.0, TP 2.0     |
//|  - Lot size from % risk of equity, rounded to the broker's step  |
//|  - Optional martingale (x2 after a loss, max 2 steps)            |
//|  - Daily loss limit and max trades per day                       |
//|                                                                  |
//|  Works on standard and cent accounts: lot value is read from the |
//|  broker (tick value / tick size), so no account-type setting.    |
//|                                                                  |
//|  No EA can guarantee a win rate. Backtest in the Strategy Tester |
//|  ("Every tick based on real ticks") and run on demo first.       |
//+------------------------------------------------------------------+
#property copyright   "GRAVAITY"
#property version     "1.00"
#property description "XAUUSD M5 trend-pullback scalper with fixed SL/TP, risk sizing and optional martingale."

#include <Trade\Trade.mqh>

enum ENUM_TRADE_DIR
  {
   DIR_BOTH  = 0, // Both
   DIR_LONG  = 1, // Long only
   DIR_SHORT = 2  // Short only
  };

//--- General
input group "General"
input ENUM_TIMEFRAMES InpTF          = PERIOD_M5;  // Signal timeframe
input ENUM_TRADE_DIR  InpDirection   = DIR_BOTH;   // Trade direction
input long            InpMagic       = 240519;     // Magic number

//--- Trend
input group "Trend"
input int             InpEmaFast     = 9;          // Fast EMA
input int             InpEmaSlow     = 21;         // Slow EMA (pullback)
input int             InpEmaTrend    = 200;        // Trend EMA
input double          InpStFactor    = 3.0;        // Supertrend factor
input int             InpStAtrLen    = 10;         // Supertrend ATR length
input bool            InpUseHtf      = true;       // Use higher-timeframe filter
input ENUM_TIMEFRAMES InpHtfTF       = PERIOD_M15; // HTF timeframe
input int             InpHtfEmaLen   = 50;         // HTF EMA length

//--- Filters
input group "Momentum & Filters"
input int             InpRsiLen      = 14;         // RSI length
input double          InpRsiLongMin  = 50;         // RSI long min
input double          InpRsiLongMax  = 72;         // RSI long max
input double          InpRsiShortMax = 50;         // RSI short max
input double          InpRsiShortMin = 28;         // RSI short min
input int             InpAdxLen      = 14;         // ADX length
input double          InpAdxMin      = 26;         // ADX minimum
input int             InpPullbackBars= 5;          // Pullback lookback (bars)
input bool            InpUseVol      = true;       // Tick-volume filter
input int             InpVolLen      = 20;         // Volume MA length
input double          InpVolMult     = 1.0;        // Volume > MA x
input int             InpCooldown    = 3;          // Cooldown bars after exit

//--- Session
input group "Session (UTC)"
input bool            InpUseSession  = true;       // Trade only inside session
input int             InpSessStart   = 7;          // Session start hour (UTC)
input int             InpSessEnd     = 17;         // Session end hour (UTC)
input int             InpTesterGmtOffset = 2;      // Broker server GMT offset (used in Strategy Tester only)

//--- Exits
input group "Exits (price distance, USD per oz)"
input double          InpSlUsd       = 4.0;        // Stop loss
input double          InpTpUsd       = 2.0;        // Take profit
input bool            InpUseBE       = false;      // Break-even stop
input double          InpBeTrigUsd   = 0.8;        // Break-even trigger
input double          InpBeLockUsd   = 0.4;        // Break-even lock (covers spread)
input bool            InpExitStFlip  = true;       // Close on Supertrend flip

//--- Risk
input group "Risk"
input double          InpRiskPct     = 5.0;        // Risk per trade % of equity
input double          InpMaxRiskPct  = 25.0;       // Skip trade if min lot risks more than %
input double          InpMaxDailyLoss= 20.0;       // Daily loss limit %
input int             InpMaxTradesDay= 8;          // Max trades per day
input int             InpMaxSpreadPts= 0;          // Max spread in points (0 = off)

//--- Martingale
input group "Martingale (high risk)"
input bool            InpUseMart     = true;       // Use martingale
input double          InpMartMult    = 2.0;        // Lot multiplier after a loss
input int             InpMartSteps   = 2;          // Max martingale steps
input double          InpMartMaxRisk = 70.0;       // Max risk % for a martingale trade

//--- Display
input group "Display"
input bool            InpShowPanel   = true;       // Show info panel

//--- globals
CTrade   trade;
int      hEmaF = INVALID_HANDLE, hEmaS = INVALID_HANDLE, hEmaT = INVALID_HANDLE;
int      hEma12 = INVALID_HANDLE, hEma26 = INVALID_HANDLE;
int      hRsi = INVALID_HANDLE, hAdx = INVALID_HANDLE, hHtfEma = INVALID_HANDLE;
datetime lastBarTime   = 0;
datetime lastExitTime  = 0;
ulong    trackedPosId  = 0;
int      martLevel     = 0;
int      dayOfYear     = -1;
double   dayStartEq    = 0;
int      dayTrades     = 0;
string   gvMart;
string   panelTrend = "-", panelSession = "-", panelNote = "";
double   panelAdx = 0;

const int BARS = 600;

//+------------------------------------------------------------------+
int OnInit()
  {
   hEmaF   = iMA(_Symbol, InpTF, InpEmaFast, 0, MODE_EMA, PRICE_CLOSE);
   hEmaS   = iMA(_Symbol, InpTF, InpEmaSlow, 0, MODE_EMA, PRICE_CLOSE);
   hEmaT   = iMA(_Symbol, InpTF, InpEmaTrend, 0, MODE_EMA, PRICE_CLOSE);
   hEma12  = iMA(_Symbol, InpTF, 12, 0, MODE_EMA, PRICE_CLOSE);
   hEma26  = iMA(_Symbol, InpTF, 26, 0, MODE_EMA, PRICE_CLOSE);
   hRsi    = iRSI(_Symbol, InpTF, InpRsiLen, PRICE_CLOSE);
   hAdx    = iADXWilder(_Symbol, InpTF, InpAdxLen);
   hHtfEma = iMA(_Symbol, InpHtfTF, InpHtfEmaLen, 0, MODE_EMA, PRICE_CLOSE);
   if(hEmaF == INVALID_HANDLE || hEmaS == INVALID_HANDLE || hEmaT == INVALID_HANDLE ||
      hEma12 == INVALID_HANDLE || hEma26 == INVALID_HANDLE || hRsi == INVALID_HANDLE ||
      hAdx == INVALID_HANDLE || hHtfEma == INVALID_HANDLE)
     {
      Print("Failed to create indicator handles");
      return INIT_FAILED;
     }
   if(PeriodSeconds(InpHtfTF) < PeriodSeconds(InpTF))
      Print("Warning: HTF timeframe is lower than the signal timeframe");

   trade.SetExpertMagicNumber(InpMagic);
   trade.SetTypeFillingBySymbol(_Symbol);
   trade.SetDeviationInPoints(50);

   // Martingale level survives EA / terminal restarts
   gvMart = "XAUS_" + _Symbol + "_" + IntegerToString(InpMagic) + "_mart";
   if(GlobalVariableCheck(gvMart))
      martLevel = (int)GlobalVariableGet(gvMart);

   ulong ticket;
   if(GetMyPosition(ticket))
      trackedPosId = PositionGetInteger(POSITION_IDENTIFIER);

   ResetDay();
   return INIT_SUCCEEDED;
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   IndicatorRelease(hEmaF);
   IndicatorRelease(hEmaS);
   IndicatorRelease(hEmaT);
   IndicatorRelease(hEma12);
   IndicatorRelease(hEma26);
   IndicatorRelease(hRsi);
   IndicatorRelease(hAdx);
   IndicatorRelease(hHtfEma);
   Comment("");
  }

//+------------------------------------------------------------------+
void OnTick()
  {
   CheckNewDay();
   CheckClosedPosition();

   datetime barTime = iTime(_Symbol, InpTF, 0);
   if(barTime == 0 || barTime == lastBarTime)
     {
      // in the Strategy Tester the panel only refreshes once per bar (speed)
      if(InpShowPanel && !MQLInfoInteger(MQL_TESTER))
         DrawPanel();
      return;
     }
   lastBarTime = barTime;

   OnNewBar();
   if(InpShowPanel)
      DrawPanel();
  }

//+------------------------------------------------------------------+
//| Main logic, runs once when a new bar opens (signal = last closed) |
//+------------------------------------------------------------------+
void OnNewBar()
  {
   MqlRates r[];
   double emaF[], emaS[], emaT[], e12[], e26[], rsi[], adx[], pdi[], mdi[];
   ArraySetAsSeries(r, false);
   if(CopyRates(_Symbol, InpTF, 1, BARS, r) != BARS)
      return;
   if(!CopyClosed(hEmaF, 0, emaF) || !CopyClosed(hEmaS, 0, emaS) || !CopyClosed(hEmaT, 0, emaT) ||
      !CopyClosed(hEma12, 0, e12) || !CopyClosed(hEma26, 0, e26) || !CopyClosed(hRsi, 0, rsi) ||
      !CopyClosed(hAdx, 0, adx) || !CopyClosed(hAdx, 1, pdi) || !CopyClosed(hAdx, 2, mdi))
      return;

   int n = BARS - 1; // index of the last closed bar (the signal bar)

   //--- Supertrend direction (-1 = up, 1 = down, same as Pine)
   int stDir = SupertrendDir(r, InpStFactor, InpStAtrLen);

   //--- MACD histogram with EMA signal line (matches Pine ta.macd)
   double sig = e12[0] - e26[0], histPrev = 0, hist = 0;
   double k = 2.0 / (9 + 1);
   for(int i = 0; i < BARS; i++)
     {
      double m = e12[i] - e26[i];
      sig = (i == 0) ? m : m * k + sig * (1 - k);
      histPrev = hist;
      hist = m - sig;
     }
   bool histUp = hist > 0 && histPrev <= 0;
   bool histDn = hist < 0 && histPrev >= 0;

   //--- higher timeframe: previous closed HTF bar relative to the signal bar
   bool htfUp = true, htfDn = true;
   if(InpUseHtf)
     {
      int hs = iBarShift(_Symbol, InpHtfTF, r[n].time) + 1;
      double hc[], he[];
      if(CopyClose(_Symbol, InpHtfTF, hs, 1, hc) != 1 || CopyBuffer(hHtfEma, 0, hs, 1, he) != 1)
         return;
      htfUp = hc[0] > he[0];
      htfDn = hc[0] < he[0];
     }

   //--- volume
   bool volOk = true;
   if(InpUseVol)
     {
      double sum = 0;
      for(int i = n - InpVolLen + 1; i <= n; i++)
         sum += (double)r[i].tick_volume;
      double avg = sum / InpVolLen;
      volOk = r[n].tick_volume <= 0 || (double)r[n].tick_volume > avg * InpVolMult;
     }

   //--- pullback to slow EMA within the lookback
   bool pbL = false, pbS = false;
   for(int i = n; i >= n - InpPullbackBars && i >= 0; i--)
     {
      if(r[i].low <= emaS[i])
         pbL = true;
      if(r[i].high >= emaS[i])
         pbS = true;
     }

   //--- session
   bool inSession = true;
   if(InpUseSession)
     {
      MqlDateTime t;
      TimeToStruct(r[n].time - ServerGmtOffset(), t);
      inSession = t.hour >= InpSessStart && t.hour < InpSessEnd;
     }

   double c = r[n].close, o = r[n].open;
   bool trendUp  = c > emaT[n] && emaF[n] > emaS[n] && stDir < 0 && htfUp;
   bool trendDn  = c < emaT[n] && emaF[n] < emaS[n] && stDir > 0 && htfDn;
   bool strongUp = adx[n] > InpAdxMin && pdi[n] > mdi[n];
   bool strongDn = adx[n] > InpAdxMin && mdi[n] > pdi[n];
   bool trigL    = c > emaF[n] && c > o && (c > r[n - 1].high || histUp);
   bool trigS    = c < emaF[n] && c < o && (c < r[n - 1].low || histDn);
   bool rsiL     = rsi[n] > InpRsiLongMin && rsi[n] < InpRsiLongMax;
   bool rsiS     = rsi[n] < InpRsiShortMax && rsi[n] > InpRsiShortMin;

   panelTrend   = trendUp ? "BULL" : trendDn ? "BEAR" : "NEUTRAL";
   panelSession = inSession ? "OPEN" : "CLOSED";
   panelAdx     = adx[n];

   //--- manage an open position (break-even, Supertrend flip)
   ulong ticket;
   if(GetMyPosition(ticket))
     {
      ManagePosition(ticket, r[n], stDir);
      return;
     }

   //--- guards
   bool cooldownOk = true;
   if(lastExitTime > 0)
     {
      int exitShift = iBarShift(_Symbol, InpTF, lastExitTime);
      cooldownOk = exitShift - 1 > InpCooldown;
     }
   double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   double dayLoss = dayStartEq > 0 ? (dayStartEq - eq) / dayStartEq * 100.0 : 0;
   bool dayOk = dayLoss < InpMaxDailyLoss && dayTrades < InpMaxTradesDay;
   bool spreadOk = InpMaxSpreadPts <= 0 || SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) <= InpMaxSpreadPts;

   bool longSig  = InpDirection != DIR_SHORT && trendUp && strongUp && pbL && trigL && rsiL;
   bool shortSig = InpDirection != DIR_LONG  && trendDn && strongDn && pbS && trigS && rsiS;
   if(!(longSig || shortSig))
      return;
   if(!(cooldownOk && inSession && dayOk && volOk && spreadOk))
      return;

   //--- position size
   double lots, riskPct;
   if(!CalcLots(lots, riskPct))
      return;

   OpenTrade(longSig, lots, riskPct);
  }

//+------------------------------------------------------------------+
bool CopyClosed(int handle, int buffer, double &arr[])
  {
   ArraySetAsSeries(arr, false);
   return CopyBuffer(handle, buffer, 1, BARS, arr) == BARS;
  }

//+------------------------------------------------------------------+
//| Supertrend as in Pine ta.supertrend (Wilder ATR, hl2 source)      |
//+------------------------------------------------------------------+
int SupertrendDir(const MqlRates &r[], double factor, int len)
  {
   int n = ArraySize(r);
   double atr = 0, upPrev = 0, loPrev = 0, stPrev = 0;
   int dir = 1;
   for(int i = 0; i < n; i++)
     {
      double tr = (i == 0) ? r[i].high - r[i].low
                  : MathMax(r[i].high - r[i].low, MathMax(MathAbs(r[i].high - r[i - 1].close), MathAbs(r[i].low - r[i - 1].close)));
      if(i < len)
        {
         atr += tr / len; // SMA seed
         if(i < len - 1)
            continue;
        }
      else
         atr = (atr * (len - 1) + tr) / len;

      double hl2 = (r[i].high + r[i].low) / 2.0;
      double up = hl2 + factor * atr, lo = hl2 - factor * atr;
      bool first = (i == len - 1);
      if(!first)
        {
         lo = (lo > loPrev || r[i - 1].close < loPrev) ? lo : loPrev;
         up = (up < upPrev || r[i - 1].close > upPrev) ? up : upPrev;
         if(stPrev == upPrev)
            dir = r[i].close > up ? -1 : 1;
         else
            dir = r[i].close < lo ? 1 : -1;
        }
      else
         dir = 1;
      double st = dir == -1 ? lo : up;
      upPrev = up;
      loPrev = lo;
      stPrev = st;
     }
   return dir;
  }

//+------------------------------------------------------------------+
//| Money lost per 1.0 lot for a given price distance                 |
//+------------------------------------------------------------------+
double LossPerLot(double priceDist)
  {
   double tv = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE_LOSS);
   if(tv <= 0)
      tv = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double ts = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(ts <= 0)
      return 0;
   return priceDist / ts * tv;
  }

//+------------------------------------------------------------------+
double NormalizeLots(double lots)
  {
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double vmin = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double vmax = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   if(step <= 0)
      step = 0.01;
   lots = MathFloor(lots / step + 1e-9) * step;
   lots = MathMax(lots, vmin);
   lots = MathMin(lots, vmax);
   return NormalizeDouble(lots, 2);
  }

//+------------------------------------------------------------------+
//| Risk-based lot with martingale; false = skip the trade            |
//+------------------------------------------------------------------+
bool CalcLots(double &lots, double &riskPct)
  {
   double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   double spread = SymbolInfoDouble(_Symbol, SYMBOL_ASK) - SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double lpl = LossPerLot(InpSlUsd + spread);
   if(eq <= 0 || lpl <= 0)
      return false;

   double base = NormalizeLots(eq * InpRiskPct / 100.0 / lpl);
   double baseRisk = base * lpl / eq * 100.0;

   lots = base;
   riskPct = baseRisk;
   bool martSize = false;
   if(InpUseMart && martLevel > 0)
     {
      double m = NormalizeLots(base * MathPow(InpMartMult, martLevel));
      double mRisk = m * lpl / eq * 100.0;
      if(mRisk <= InpMartMaxRisk)
        {
         lots = m;
         riskPct = mRisk;
         martSize = true;
        }
     }
   if(!martSize && baseRisk > InpMaxRiskPct)
     {
      panelNote = StringFormat("Skipped: min lot risks %.1f%% (> %.1f%%)", baseRisk, InpMaxRiskPct);
      Print(panelNote);
      return false;
     }

   //--- margin check
   double price = SymbolInfoDouble(_Symbol, SYMBOL_ASK), margin = 0;
   if(OrderCalcMargin(ORDER_TYPE_BUY, _Symbol, lots, price, margin) &&
      margin > AccountInfoDouble(ACCOUNT_MARGIN_FREE))
     {
      panelNote = StringFormat("Skipped: not enough free margin for %.2f lot", lots);
      Print(panelNote);
      return false;
     }
   return true;
  }

//+------------------------------------------------------------------+
void OpenTrade(bool isLong, double lots, double riskPct)
  {
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double minDist = (SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) + 2) * _Point;
   double slD = MathMax(InpSlUsd, minDist);
   double tpD = MathMax(InpTpUsd, minDist);
   string cmt = StringFormat("XAUS %s M%d", isLong ? "BUY" : "SELL", martLevel);
   bool ok;
   if(isLong)
      ok = trade.Buy(lots, _Symbol, ask, NormalizeDouble(ask - slD, _Digits), NormalizeDouble(ask + tpD, _Digits), cmt);
   else
      ok = trade.Sell(lots, _Symbol, bid, NormalizeDouble(bid + slD, _Digits), NormalizeDouble(bid - tpD, _Digits), cmt);

   ulong ticket;
   if(ok && GetMyPosition(ticket))
     {
      trackedPosId = PositionGetInteger(POSITION_IDENTIFIER);
      dayTrades++;
      panelNote = StringFormat("%s %.2f lot, risk %.1f%%, martingale step %d", isLong ? "BUY" : "SELL", lots, riskPct, martLevel);
      Print(panelNote);
     }
   else
     {
      panelNote = StringFormat("Order failed: %d %s", trade.ResultRetcode(), trade.ResultRetcodeDescription());
      Print(panelNote);
     }
  }

//+------------------------------------------------------------------+
void ManagePosition(ulong ticket, const MqlRates &bar, int stDir)
  {
   if(!PositionSelectByTicket(ticket))
      return;
   long   type  = PositionGetInteger(POSITION_TYPE);
   double open  = PositionGetDouble(POSITION_PRICE_OPEN);
   double sl    = PositionGetDouble(POSITION_SL);
   double tp    = PositionGetDouble(POSITION_TP);

   if(InpExitStFlip && ((type == POSITION_TYPE_BUY && stDir > 0) || (type == POSITION_TYPE_SELL && stDir < 0)))
     {
      trade.PositionClose(ticket);
      return;
     }

   if(InpUseBE)
     {
      if(type == POSITION_TYPE_BUY && bar.high >= open + InpBeTrigUsd)
        {
         double nsl = NormalizeDouble(open + InpBeLockUsd, _Digits);
         if(nsl > sl && nsl < SymbolInfoDouble(_Symbol, SYMBOL_BID))
            trade.PositionModify(ticket, nsl, tp);
        }
      if(type == POSITION_TYPE_SELL && bar.low <= open - InpBeTrigUsd)
        {
         double nsl = NormalizeDouble(open - InpBeLockUsd, _Digits);
         if((sl == 0 || nsl < sl) && nsl > SymbolInfoDouble(_Symbol, SYMBOL_ASK))
            trade.PositionModify(ticket, nsl, tp);
        }
     }
  }

//+------------------------------------------------------------------+
//| Detect our position closing: update martingale level and cooldown |
//+------------------------------------------------------------------+
void CheckClosedPosition()
  {
   if(trackedPosId == 0)
      return;
   ulong ticket;
   if(GetMyPosition(ticket))
      return;

   double result = 0;
   if(HistorySelectByPosition(trackedPosId))
     {
      for(int i = HistoryDealsTotal() - 1; i >= 0; i--)
        {
         ulong d = HistoryDealGetTicket(i);
         result += HistoryDealGetDouble(d, DEAL_PROFIT) + HistoryDealGetDouble(d, DEAL_COMMISSION) +
                   HistoryDealGetDouble(d, DEAL_SWAP) + HistoryDealGetDouble(d, DEAL_FEE);
        }
     }
   martLevel = result > 0 ? 0 : MathMin(martLevel + 1, InpMartSteps);
   GlobalVariableSet(gvMart, martLevel);
   lastExitTime = TimeCurrent();
   trackedPosId = 0;
   panelNote = StringFormat("Closed %s%.2f, next martingale step %d", result >= 0 ? "+" : "", result, martLevel);
   Print(panelNote);
  }

//+------------------------------------------------------------------+
bool GetMyPosition(ulong &ticket)
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong t = PositionGetTicket(i);
      if(t == 0)
         continue;
      if(PositionGetString(POSITION_SYMBOL) == _Symbol && PositionGetInteger(POSITION_MAGIC) == InpMagic)
        {
         ticket = t;
         return true;
        }
     }
   return false;
  }

//+------------------------------------------------------------------+
int ServerGmtOffset()
  {
   if(MQLInfoInteger(MQL_TESTER))
      return InpTesterGmtOffset * 3600;
   // round to the nearest 30 minutes
   long diff = (long)(TimeTradeServer() - TimeGMT());
   return (int)(MathRound(diff / 1800.0) * 1800);
  }

//+------------------------------------------------------------------+
void ResetDay()
  {
   MqlDateTime t;
   TimeToStruct(TimeCurrent(), t);
   dayOfYear  = t.day_of_year;
   dayStartEq = AccountInfoDouble(ACCOUNT_EQUITY);
   dayTrades  = 0;
  }

void CheckNewDay()
  {
   MqlDateTime t;
   TimeToStruct(TimeCurrent(), t);
   if(t.day_of_year != dayOfYear)
      ResetDay();
  }

//+------------------------------------------------------------------+
//| Stats for this EA from account history                            |
//+------------------------------------------------------------------+
void HistoryStats(int &trades, int &wins, double &grossWin, double &grossLoss)
  {
   trades = 0;
   wins = 0;
   grossWin = 0;
   grossLoss = 0;
   if(!HistorySelect(0, TimeCurrent()))
      return;
   for(int i = 0; i < HistoryDealsTotal(); i++)
     {
      ulong d = HistoryDealGetTicket(i);
      if(HistoryDealGetInteger(d, DEAL_MAGIC) != InpMagic || HistoryDealGetString(d, DEAL_SYMBOL) != _Symbol)
         continue;
      long entry = HistoryDealGetInteger(d, DEAL_ENTRY);
      if(entry != DEAL_ENTRY_OUT && entry != DEAL_ENTRY_OUT_BY)
         continue;
      double p = HistoryDealGetDouble(d, DEAL_PROFIT) + HistoryDealGetDouble(d, DEAL_COMMISSION) +
                 HistoryDealGetDouble(d, DEAL_SWAP) + HistoryDealGetDouble(d, DEAL_FEE);
      trades++;
      if(p > 0)
        {
         wins++;
         grossWin += p;
        }
      else
         grossLoss -= p;
     }
  }

//+------------------------------------------------------------------+
void DrawPanel()
  {
   static datetime lastDraw = 0;
   if(TimeCurrent() - lastDraw < 2 && !MQLInfoInteger(MQL_TESTER) && lastDraw > 0)
      return;
   lastDraw = TimeCurrent();

   int trades, wins;
   double gw, gl;
   HistoryStats(trades, wins, gw, gl);
   double eq  = AccountInfoDouble(ACCOUNT_EQUITY);
   double bal = AccountInfoDouble(ACCOUNT_BALANCE);
   string cur = AccountInfoString(ACCOUNT_CURRENCY);
   double dayPl = dayStartEq > 0 ? (eq - dayStartEq) / dayStartEq * 100.0 : 0;

   string s = "XAU Aggressive Scalper  (magic " + IntegerToString(InpMagic) + ")\n";
   s += StringFormat("Balance %.2f %s   Equity %.2f\n", bal, cur, eq);
   s += StringFormat("Closed trades %d   Win rate %.1f%%   Profit factor %.2f\n",
                     trades, trades > 0 ? 100.0 * wins / trades : 0.0, gl > 0 ? gw / gl : 0.0);
   s += StringFormat("Today: %d / %d trades   P/L %+.1f%%\n", dayTrades, InpMaxTradesDay, dayPl);
   s += StringFormat("Martingale: %s\n", InpUseMart ? StringFormat("step %d / %d (x%.2f)", martLevel, InpMartSteps, MathPow(InpMartMult, martLevel)) : "OFF");
   s += StringFormat("Trend %s   Session %s   ADX %.1f\n", panelTrend, panelSession, panelAdx);
   s += StringFormat("SL %.2f / TP %.2f (price)   Risk %.1f%%\n", InpSlUsd, InpTpUsd, InpRiskPct);
   if(panelNote != "")
      s += panelNote + "\n";
   Comment(s);
  }
//+------------------------------------------------------------------+
