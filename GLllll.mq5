//+------------------------------------------------------------------+
//|                                         HedgeTrimStrat.mq5       |
//|                                    Hedge Trim Strategy EA - MT5  |
//+------------------------------------------------------------------+
#property copyright "Hedge Trim Strategy"
#property version   "1.00"

#include <Trade\Trade.mqh>

//=== Input Parameters =================================================
input group "--- Entry ---"
input int    InpSwingLookback  = 20;     // Swing lookback (candles)
input double InpStartUSD       = 100.0;  // Starting exposure (USD notional)

input group "--- Distances (pips) ---"
input int    InpHedgePips      = 50;     // Hedge pending distance
input int    InpTrailTPPips    = 30;     // Trailing TP distance
input int    InpSqueezePips    = 30;     // Squeeze trailing pending distance

input group "--- Settings ---"
input double InpMaxUSDPerSide  = 100.0;  // Max USD notional exposure per side (Buy / Sell, each independent)
input int    InpMagic          = 98765;  // Magic number
input bool   InpLog            = true;   // Enable logging

input group "--- Broken Level Memory (chop filter + reversal) ---"
input bool   InpLevelMemoryEnable = true;   // Enable broken-level memory (filter + reversal)
input int    InpLevelCount        = 8;      // Max remembered broken levels (rotating buffer)
input int    InpLevelBufferPips   = 40;     // Proximity buffer around a remembered level
input int    InpLevelExpiryBars   = 300;    // Bars after which a remembered level is forgotten (0 = never)

//=== Trade object =====================================================
CTrade g_trade;

//=== Pip size / contract size =========================================
double g_pip          = 0.0;
double g_contractSize = 0.0;

//=== Cycle state ======================================================
bool     g_inCycle        = false;
double   g_realizedProfit = 0.0;
datetime g_lastBarTime    = 0;

//=== Squeeze pending ==================================================
ulong  g_sqTicket = 0;   // ticket of active squeeze pending
int    g_sqDir    = 0;   // +1 = SELL STOP trails up, -1 = BUY STOP trails down

//=== Broken level memory ==============================================
struct SBrokenLevel
{
   double   price;
   bool     wasBuyBreak;   // true = level was broken UPWARD (old resistance -> now support)
   datetime brokenTime;
   bool     used;          // a reversal/fade entry has already fired off this level
};
SBrokenLevel g_levels[];
int          g_levelIdx = 0;   // rotating write pointer

//=== Comment tags =====================================================
#define TAG_MAIN     "HTS|MAIN"
#define TAG_HEDGE    "HTS|HEDGE"
#define TAG_SQUEEZE  "HTS|SQUEEZE"
#define TAG_HPEND    "HTS|HPEND|"    // append position ID
#define TAG_SPEND    "HTS|SPEND"
#define TAG_TRIM     "HTS|TRIM"
#define TAG_REVERSAL "HTS|REV"

//=== GlobalVariable key helper ========================================
string GK(string s) { return "HTS_" + IntegerToString(InpMagic) + "_" + s; }
string HWMKey(ulong id)  { return GK("HWM_"  + IntegerToString((long)id)); }
string TrimKey(ulong id) { return GK("TRIM_" + IntegerToString((long)id)); }
string LvlPriceKey(int i) { return GK("LVLP_" + IntegerToString(i)); }
string LvlTypeKey(int i)  { return GK("LVLB_" + IntegerToString(i)); }
string LvlTimeKey(int i)  { return GK("LVLT_" + IntegerToString(i)); }
string LvlUsedKey(int i)  { return GK("LVLU_" + IntegerToString(i)); }
string LvlIdxKey()        { return GK("LVLIDX"); }

//+------------------------------------------------------------------+
//| OnInit                                                           |
//+------------------------------------------------------------------+
int OnInit()
{
   g_trade.SetExpertMagicNumber(InpMagic);
   g_trade.SetDeviationInPoints(10);

   // Auto-detect filling mode
   int fillMode = (int)SymbolInfoInteger(_Symbol, SYMBOL_FILLING_MODE);
   if((fillMode & SYMBOL_FILLING_FOK) != 0)
      g_trade.SetTypeFilling(ORDER_FILLING_FOK);
   else if((fillMode & SYMBOL_FILLING_IOC) != 0)
      g_trade.SetTypeFilling(ORDER_FILLING_IOC);
   else
      g_trade.SetTypeFilling(ORDER_FILLING_RETURN);

   // Pip size (handles 3/5 digit brokers)
   int digs = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   g_pip = (digs == 3 || digs == 5) ? _Point * 10.0 : _Point;

   // Contract size (e.g. 100 for XAUUSD) — needed to convert USD <-> lots
   g_contractSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_CONTRACT_SIZE);

   // Diagnostic: show what the broker's minimum lot actually costs in USD,
   // so InpStartUSD / InpMaxUSDPerSide can be sanity-checked against it.
   {
      double minLotNow = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
      double refPrice  = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      Log("Contract=" + DoubleToString(g_contractSize, 2) +
          " | MinLot=" + DoubleToString(minLotNow, 2) +
          " | MinNotional~$" + DoubleToString(minLotNow * refPrice * g_contractSize, 2) +
          " | InpStartUSD=" + DoubleToString(InpStartUSD, 2) +
          " | InpMaxUSDPerSide=" + DoubleToString(InpMaxUSDPerSide, 2));
      if(InpStartUSD < minLotNow * refPrice * g_contractSize)
         Log("WARNING: InpStartUSD is below the broker's minimum lot notional — main entries will be skipped!");
   }

   // Restore persisted state
   if(GlobalVariableCheck(GK("CYCLE"))) g_inCycle        = (GlobalVariableGet(GK("CYCLE")) > 0.5);
   if(GlobalVariableCheck(GK("REAL")))  g_realizedProfit  = GlobalVariableGet(GK("REAL"));
   if(GlobalVariableCheck(GK("SQTKT"))) g_sqTicket        = (ulong)GlobalVariableGet(GK("SQTKT"));
   if(GlobalVariableCheck(GK("SQDIR"))) g_sqDir           = (int)GlobalVariableGet(GK("SQDIR"));

   // Restore broken-level memory (persists across restarts, independent of cycle)
   InitLevelMemory();

   // Auto-detect cycle from live positions/orders
   if(!g_inCycle)
      g_inCycle = (CountPositions() > 0 || CountOrders() > 0);

   Log("Init | Cycle=" + (g_inCycle ? "ACTIVE" : "IDLE") +
       " | Realized=" + DoubleToString(g_realizedProfit, 2) +
       " | SqTicket=" + IntegerToString((long)g_sqTicket));

   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| OnDeinit                                                         |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   SaveState();
}

//+------------------------------------------------------------------+
//| OnTick                                                           |
//+------------------------------------------------------------------+
void OnTick()
{
   // 1. Manage trailing TP on all our positions
   ManageTrailingTP();

   // 2. Trail the squeeze pending if active
   if(g_sqTicket != 0)
      ManageSqueezePending();

   // 3. Check if cycle has ended
   if(g_inCycle && CheckCycleEnd())
   {
      EndCycle();
      return;
   }

   // 4. Look for new entries on every new bar — pyramiding is allowed even
   //    while a cycle is already active (existing positions open). Each
   //    entry still goes through OpenMainEntry's USD-headroom clamp, so the
   //    per-side cap (InpMaxUSDPerSide) is never exceeded regardless of how
   //    many positions accumulate on a side.
   datetime barTime = iTime(_Symbol, PERIOD_CURRENT, 0);
   if(barTime != g_lastBarTime)
   {
      g_lastBarTime = barTime;
      CheckSwingBreakout();
      CheckLevelReversal();
      CheckMinLotClosures();
   }
}

//+------------------------------------------------------------------+
//| OnTradeTransaction                                               |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest     &request,
                        const MqlTradeResult      &result)
{
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD) return;
   if(!HistoryDealSelect(trans.deal)) return;
   if(HistoryDealGetInteger(trans.deal, DEAL_MAGIC)  != InpMagic) return;
   if(HistoryDealGetString(trans.deal, DEAL_SYMBOL)  != _Symbol)  return;

   long   entry    = HistoryDealGetInteger(trans.deal, DEAL_ENTRY);
   string comment  = HistoryDealGetString (trans.deal, DEAL_COMMENT);
   ulong  posId    = (ulong)HistoryDealGetInteger(trans.deal, DEAL_POSITION_ID);
   double profit   = HistoryDealGetDouble (trans.deal, DEAL_PROFIT);
   double price    = HistoryDealGetDouble (trans.deal, DEAL_PRICE);
   long   dealType = HistoryDealGetInteger(trans.deal, DEAL_TYPE);

   //--- Position OPENED
   if(entry == DEAL_ENTRY_IN)
   {
      bool isBuy = (dealType == DEAL_TYPE_BUY);
      InitHWM(posId, price);   // start HWM at open price
      Log("Opened #" + IntegerToString((long)posId) +
          " " + (isBuy ? "BUY" : "SELL") +
          " @ " + DoubleToString(price, _Digits) +
          " [" + comment + "]");

      // Squeeze pending triggered → clear tracking
      if(StringFind(comment, TAG_SPEND) >= 0)
      {
         g_sqTicket = 0;
         g_sqDir    = 0;
         SaveState();
      }
   }

   //--- Position CLOSED (full or partial)
   if(entry == DEAL_ENTRY_OUT || entry == DEAL_ENTRY_INOUT)
   {
      // Skip our own trim partial-closes (they have negative profit anyway,
      // but checking comment is an extra safety guard)
      if(StringFind(comment, TAG_TRIM) >= 0) return;

      Log("Closed #" + IntegerToString((long)posId) +
          " profit=" + DoubleToString(profit, 2) +
          " [" + comment + "]");

      GlobalVariableDel(HWMKey(posId));   // clean up HWM
      GlobalVariableDel(TrimKey(posId));  // clean up trim carry-over

      if(profit > 0)
      {
         // Delete the hedge pending that was associated with this position
         DeleteHedgePending(posId);
         // Apply trim + place squeeze
         OnProfitableClose(profit);
      }
   }
}

//+------------------------------------------------------------------+
//| Swing breakout detection (on bar close)                          |
//+------------------------------------------------------------------+
void CheckSwingBreakout()
{
   int n = InpSwingLookback;
   if(iBars(_Symbol, PERIOD_CURRENT) < n + 3) return;  // need bars [1..n+1] + current

   // Swing high/low over bars [2 .. n+1] — the N bars BEFORE the last closed bar.
   // Bar 1 is the signal bar; its close is checked against the prior swing range.
   // (Using bars [1..N] was the bug: bar 1's high is in the swing, and close <= high
   //  always, so the breakout condition could never fire.)
   double swingHigh = 0.0, swingLow = DBL_MAX;
   for(int i = 2; i <= n + 1; i++)
   {
      double h = iHigh(_Symbol, PERIOD_CURRENT, i);
      double l = iLow (_Symbol, PERIOD_CURRENT, i);
      if(h > swingHigh) swingHigh = h;
      if(l < swingLow)  swingLow  = l;
   }

   // Signal: last closed bar (bar 1) breaks above/below the prior swing range
   double lastClose = iClose(_Symbol, PERIOD_CURRENT, 1);

   if(lastClose > swingHigh)
   {
      // Chop filter: if this breakout level sits right on top of a level that
      // was broken DOWNWARD before (old support, now potential resistance),
      // this is likely a retest/fakeout rather than a fresh breakout — skip
      // the main entry but still remember the level for the reversal/fade logic.
      double nearLvl = 0;
      if(NearOppositeLevel(lastClose, true, nearLvl))
      {
         Log("BUY breakout SUPPRESSED (chop near broken level @ " + DoubleToString(nearLvl, _Digits) +
             ") | close=" + DoubleToString(lastClose, _Digits));
      }
      else
      {
         Log("BUY breakout | close=" + DoubleToString(lastClose, _Digits) +
             " > high=" + DoubleToString(swingHigh, _Digits));
         OpenMainEntry(true);
      }
      if(!HasNearbyLevel(swingHigh, InpLevelBufferPips))
         RememberBrokenLevel(swingHigh, true);
   }
   else if(lastClose < swingLow)
   {
      double nearLvl = 0;
      if(NearOppositeLevel(lastClose, false, nearLvl))
      {
         Log("SELL breakout SUPPRESSED (chop near broken level @ " + DoubleToString(nearLvl, _Digits) +
             ") | close=" + DoubleToString(lastClose, _Digits));
      }
      else
      {
         Log("SELL breakout | close=" + DoubleToString(lastClose, _Digits) +
             " < low=" + DoubleToString(swingLow, _Digits));
         OpenMainEntry(false);
      }
      if(!HasNearbyLevel(swingLow, InpLevelBufferPips))
         RememberBrokenLevel(swingLow, false);
   }
}

//+------------------------------------------------------------------+
//| Open main position and place hedge pending                       |
//+------------------------------------------------------------------+
void OpenMainEntry(bool isBuy)
{
   OpenPosition(isBuy, InpStartUSD, TAG_MAIN);
}

//+------------------------------------------------------------------+
//| Open reversal/fade entry (retest-and-rejection of a broken level)|
//+------------------------------------------------------------------+
void OpenReversalEntry(bool isBuy, double levelPrice)
{
   Log("Reversal/fade entry | level @ " + DoubleToString(levelPrice, _Digits) +
       " | target=" + DoubleToString(InpStartUSD, 2) + "$ (clamped to available headroom)");
   OpenPosition(isBuy, InpStartUSD, TAG_REVERSAL);
}

//+------------------------------------------------------------------+
//| Shared position-open logic: market entry + opposite hedge pending|
//| Used by both the main breakout entry and the reversal/fade entry |
//+------------------------------------------------------------------+
void OpenPosition(bool isBuy, double usdSize, string tag)
{
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double price = isBuy ? ask : bid;

   // Size from USD notional, then clamp to whatever headroom remains
   // under InpMaxUSDPerSide for this side (Buy and Sell tracked separately)
   double lots = UsdToLots(usdSize, price);
   lots = ClampLotsToHeadroom(isBuy, lots, price);
   if(lots <= 0)
   {
      Log(tag + " entry skipped | no USD headroom on " + (isBuy ? "BUY" : "SELL") +
          " side (cap=" + DoubleToString(InpMaxUSDPerSide, 2) + ")");
      return;
   }

   bool ok = isBuy
      ? g_trade.Buy (lots, _Symbol, ask, 0, 0, tag)
      : g_trade.Sell(lots, _Symbol, bid, 0, 0, tag);

   if(!ok)
   {
      Log(tag + " entry failed: " + IntegerToString(g_trade.ResultRetcode()));
      return;
   }

   // In MT5 hedging mode the position ticket == the order ticket for market orders
   ulong posId = g_trade.ResultOrder();
   g_inCycle = true;
   Log(tag + " " + (isBuy ? "BUY" : "SELL") +
       " | lots=" + DoubleToString(lots, 2) +
       " | usd~" + DoubleToString(lots * price * g_contractSize, 2) +
       " | pos=" + IntegerToString((long)posId));

   // Place hedge pending on the opposite side
   double hedgePrice;
   ENUM_ORDER_TYPE hedgeType;
   bool hedgeIsBuy = !isBuy;
   if(isBuy)
   {
      hedgePrice = NormalizeDouble(bid - InpHedgePips * g_pip, _Digits);
      hedgeType  = ORDER_TYPE_SELL_STOP;
   }
   else
   {
      hedgePrice = NormalizeDouble(ask + InpHedgePips * g_pip, _Digits);
      hedgeType  = ORDER_TYPE_BUY_STOP;
   }

   // Hedge mirrors the main lot size (1:1 hedge ratio) unless that would
   // breach the USD cap on the hedge's side — then it's clamped down.
   double hedgeLots = ClampLotsToHeadroom(hedgeIsBuy, lots, hedgePrice);
   double minLot     = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   if(hedgeLots < minLot)
   {
      Log("Hedge pending skipped | no USD headroom on " + (hedgeIsBuy ? "BUY" : "SELL") + " side");
   }
   else
   {
      if(hedgeLots < lots)
         Log("Hedge size reduced for USD cap | " + DoubleToString(lots, 2) +
             " -> " + DoubleToString(hedgeLots, 2));
      PlacePending(hedgeType, hedgeLots, hedgePrice, TAG_HPEND + IntegerToString((long)posId));
   }
   SaveState();
}

//+------------------------------------------------------------------+
//| Manage trailing TP for all our positions                         |
//+------------------------------------------------------------------+
void ManageTrailingTP()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)  continue;

      bool   isBuy     = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY;
      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      double curPrice  = isBuy
                        ? SymbolInfoDouble(_Symbol, SYMBOL_BID)
                        : SymbolInfoDouble(_Symbol, SYMBOL_ASK);

      // Update HWM
      double hwm = GetHWM(ticket);
      if(isBuy)
      {
         if(curPrice > hwm) { hwm = curPrice; SetHWM(ticket, hwm); }
      }
      else
      {
         // For SELL: HWM is a low-water-mark (lowest price seen)
         if(hwm == 0 || curPrice < hwm) { hwm = curPrice; SetHWM(ticket, hwm); }
      }

      if(hwm == 0) continue;

      // Compute trail level and check if hit
      bool tpHit = false;
      if(isBuy)
      {
         double trailLevel = hwm - InpTrailTPPips * g_pip;
         // Only fire if trail level is above open price (genuinely in profit)
         if(trailLevel > openPrice && curPrice <= trailLevel)
            tpHit = true;
      }
      else
      {
         double trailLevel = hwm + InpTrailTPPips * g_pip;
         // Only fire if trail level is below open price (genuinely in profit)
         if(trailLevel < openPrice && curPrice >= trailLevel)
            tpHit = true;
      }

      if(tpHit && PositionGetDouble(POSITION_PROFIT) > 0)
      {
         Log("Trail TP hit | #" + IntegerToString((long)ticket) +
             " | hwm=" + DoubleToString(hwm, _Digits) +
             " | profit=" + DoubleToString(PositionGetDouble(POSITION_PROFIT), 2));
         g_trade.PositionClose(ticket, 10);
      }
   }
}

//+------------------------------------------------------------------+
//| Handle a profitable full close: trim + squeeze                   |
//+------------------------------------------------------------------+
void OnProfitableClose(double profit)
{
   double realize = profit * 0.10;
   double trimAmt = profit * 0.90;
   g_realizedProfit += realize;

   Log("Profit | Realize=" + DoubleToString(realize, 2) +
       " | Trim=" + DoubleToString(trimAmt, 2) +
       " | TotalRealized=" + DoubleToString(g_realizedProfit, 2));

   // Find the oldest (earliest-opened) currently-losing position.
   // Oldest first ensures positions are trimmed to closure in the order
   // they were opened, rather than always chasing whichever is deepest
   // in the red at the moment of the profitable close.
   ulong    losingTicket = 0;
   double   losingProfit = 0;    // actual P&L of the chosen position (for lossPerLot)
   double   losingLots   = 0;
   bool     losingIsBuy  = false;
   datetime losingTime   = (datetime)0x7FFFFFFF;   // sentinel: far future

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong t = PositionGetTicket(i);
      if(!PositionSelectByTicket(t)) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)  continue;

      double   p     = PositionGetDouble(POSITION_PROFIT);
      datetime pTime = (datetime)PositionGetInteger(POSITION_TIME);

      // Only consider positions currently at a loss, pick the earliest-opened
      if(p < 0 && pTime < losingTime)
      {
         losingProfit = p;
         losingTime   = pTime;
         losingTicket = t;
         losingLots   = PositionGetDouble(POSITION_VOLUME);
         losingIsBuy  = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY;
      }
   }

   if(losingTicket == 0)
   {
      Log("No losing leg — nothing to trim.");
      SaveState();
      return;
   }

   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);

   // --- Stuck at minimum lot: close from the realized-profit reserve ---
   // Once a position has been trimmed down to the broker minimum, no
   // further partial-close is possible. Re-route this close's 90% trim
   // budget into the reserve as well (there is nothing else to trim), then
   // close the stuck position the moment the accumulated reserve covers its
   // floating loss. This prevents min-lot positions from sitting open
   // indefinitely while profits cycle through other positions.
   if(losingLots <= minLot)
   {
      g_realizedProfit += trimAmt;   // 90% also goes to reserve — nothing to trim
      double absLoss = MathAbs(losingProfit);
      Log("Min-lot hold | #" + IntegerToString((long)losingTicket) +
          " floating=-$" + DoubleToString(absLoss, 2) +
          " | realized=$" + DoubleToString(g_realizedProfit, 2) +
          (g_realizedProfit >= absLoss
              ? " → closing now"
              : " (short $" + DoubleToString(absLoss - g_realizedProfit, 2) + ")"));
      if(g_realizedProfit >= absLoss)
      {
         g_realizedProfit -= absLoss;   // absorb the loss from the reserve
         g_trade.PositionClose(losingTicket, 10);
         GlobalVariableDel(TrimKey(losingTicket));
      }
      SaveState();
      return;
   }

   // Trim carry-over: a single profitable close is often far too small to
   // buy even one minimum lot-step of the losing position (Gold's contract
   // size means one 0.01 lot step can represent thousands of USD of
   // floating loss). Instead of discarding the unusable remainder every
   // time, bank it against this specific losing ticket until enough has
   // built up across multiple closes to actually move the position.
   double carry      = GetTrimCarry(losingTicket);
   double trimBudget = trimAmt + carry;

   // Lots to partial-close = trimBudget / abs(loss per lot)
   double lossPerLot  = (losingLots > 0) ? MathAbs(losingProfit) / losingLots : 0;
   double lotsToClose = (lossPerLot  > 0) ? trimBudget / lossPerLot : 0;
   lotsToClose = MathMin(NormLot(lotsToClose), losingLots);

   double remainingLots = NormLot(losingLots - lotsToClose);

   Log("Trim | budget=" + DoubleToString(trimBudget, 2) +
       " (this=" + DoubleToString(trimAmt, 2) + " + carry=" + DoubleToString(carry, 2) + ")" +
       " | close=" + DoubleToString(lotsToClose, 2) +
       " of #" + IntegerToString((long)losingTicket) +
       " | remaining=" + DoubleToString(remainingLots, 2));

   if(lotsToClose >= minLot)
   {
      PartialClose(losingTicket, lotsToClose);
      // Only the budget actually spent on this close is consumed; any
      // leftover (still below one lot step) keeps carrying forward.
      double used = lotsToClose * lossPerLot;
      SetTrimCarry(losingTicket, MathMax(0.0, trimBudget - used));
   }
   else
   {
      // Not enough yet to move even the minimum lot — bank the whole
      // budget against this ticket and wait for the next profitable close.
      SetTrimCarry(losingTicket, trimBudget);
      Log("Trim carry-over | #" + IntegerToString((long)losingTicket) +
          " now holds $" + DoubleToString(trimBudget, 2) +
          " (needs ~$" + DoubleToString(lossPerLot * minLot, 2) + " to close one lot step)");
   }

   if(remainingLots < minLot)
   {
      // Either the full volume was already sent to PartialClose, or a tiny
      // sub-minLot remainder is left that cannot be closed with a partial
      // order — force a full close to make sure nothing stays open.
      if(PositionSelectByTicket(losingTicket))
      {
         Log("Losing leg fully absorbed | force-closing remainder of #" +
             IntegerToString((long)losingTicket));
         g_trade.PositionClose(losingTicket, 10);
      }
      GlobalVariableDel(TrimKey(losingTicket));
      SaveState();
      return;
   }

   // Cancel any existing squeeze pending
   if(g_sqTicket != 0 && OrderSelect(g_sqTicket))
   {
      g_trade.OrderDelete(g_sqTicket);
      g_sqTicket = 0;
      g_sqDir    = 0;
   }

   // Place new squeeze trailing pending
   PlaceSqueeze(losingIsBuy, remainingLots);
   SaveState();
}

//+------------------------------------------------------------------+
//| Place squeeze trailing pending                                   |
//+------------------------------------------------------------------+
void PlaceSqueeze(bool losingIsBuy, double lots)
{
   lots = NormLot(lots);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   ENUM_ORDER_TYPE orderType;
   double price;
   bool squeezeIsBuy = !losingIsBuy;  // side the squeeze WILL open a position on

   if(losingIsBuy)
   {
      // Losing is BUY → place SELL STOP below market, trails upward
      price     = NormalizeDouble(bid - InpSqueezePips * g_pip, _Digits);
      orderType = ORDER_TYPE_SELL_STOP;
      g_sqDir   = 1;   // trails up (follows bid upward)
   }
   else
   {
      // Losing is SELL → place BUY STOP above market, trails downward
      price     = NormalizeDouble(ask + InpSqueezePips * g_pip, _Digits);
      orderType = ORDER_TYPE_BUY_STOP;
      g_sqDir   = -1;  // trails down (follows ask downward)
   }

   // Clamp to whatever USD headroom remains on the side the squeeze would land on
   double cappedLots = ClampLotsToHeadroom(squeezeIsBuy, lots, price);
   double minLot      = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   if(cappedLots < minLot)
   {
      Log("Squeeze pending skipped | no USD headroom on " + (squeezeIsBuy ? "BUY" : "SELL") + " side");
      return;
   }
   if(cappedLots < lots)
      Log("Squeeze size reduced for USD cap | " + DoubleToString(lots, 2) +
          " -> " + DoubleToString(cappedLots, 2));

   ulong ticket = PlacePending(orderType, cappedLots, price, TAG_SPEND);
   if(ticket > 0)
   {
      g_sqTicket = ticket;
      Log("Squeeze pending | " + EnumToString(orderType) +
          " @ " + DoubleToString(price, _Digits) +
          " | lots=" + DoubleToString(cappedLots, 2));
   }
}

//+------------------------------------------------------------------+
//| Trail the squeeze pending each tick                              |
//+------------------------------------------------------------------+
void ManageSqueezePending()
{
   if(!OrderSelect(g_sqTicket))
   {
      // Pending no longer exists (triggered or externally deleted)
      Log("Squeeze pending #" + IntegerToString((long)g_sqTicket) + " gone.");
      g_sqTicket = 0;
      g_sqDir    = 0;
      SaveState();
      return;
   }

   ENUM_ORDER_TYPE orderType    = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
   double          currentPrice = OrderGetDouble(ORDER_PRICE_OPEN);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double newPrice = currentPrice;

   if(orderType == ORDER_TYPE_SELL_STOP)
   {
      // Move only upward (never down), keep 30 pips below bid
      double desired = NormalizeDouble(bid - InpSqueezePips * g_pip, _Digits);
      if(desired > currentPrice + _Point)
         newPrice = desired;
   }
   else if(orderType == ORDER_TYPE_BUY_STOP)
   {
      // Move only downward (never up), keep 30 pips above ask
      double desired = NormalizeDouble(ask + InpSqueezePips * g_pip, _Digits);
      if(desired < currentPrice - _Point)
         newPrice = desired;
   }
   else return;

   if(newPrice == currentPrice) return;

   MqlTradeRequest req = {};
   MqlTradeResult  res = {};
   req.action    = TRADE_ACTION_MODIFY;
   req.order     = g_sqTicket;
   req.price     = newPrice;
   req.type_time = ORDER_TIME_GTC;

   if(!OrderSend(req, res))
      Log("Squeeze trail modify failed: " + IntegerToString(res.retcode));
}

//+------------------------------------------------------------------+
//| Delete hedge pending for a given position ID                     |
//+------------------------------------------------------------------+
void DeleteHedgePending(ulong posId)
{
   string search = TAG_HPEND + IntegerToString((long)posId);
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong t = OrderGetTicket(i);
      if(!OrderSelect(t)) continue;
      if(OrderGetInteger(ORDER_MAGIC) != InpMagic) continue;
      if(OrderGetString(ORDER_SYMBOL) != _Symbol)  continue;
      if(StringFind(OrderGetString(ORDER_COMMENT), search) >= 0)
      {
         g_trade.OrderDelete(t);
         Log("Hedge pending deleted: #" + IntegerToString((long)t));
         return;
      }
   }
}

//+------------------------------------------------------------------+
//| Partial close (trim) of a losing position                        |
//+------------------------------------------------------------------+
void PartialClose(ulong ticket, double lots)
{
   if(!PositionSelectByTicket(ticket)) return;

   bool   isBuy = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY;
   double price = isBuy
                 ? SymbolInfoDouble(_Symbol, SYMBOL_BID)
                 : SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   MqlTradeRequest req = {};
   MqlTradeResult  res = {};
   req.action       = TRADE_ACTION_DEAL;
   req.symbol       = _Symbol;
   req.volume       = NormLot(lots);
   req.position     = ticket;
   req.price        = price;
   req.deviation    = 10;
   req.magic        = InpMagic;
   req.comment      = TAG_TRIM;
   req.type         = isBuy ? ORDER_TYPE_SELL : ORDER_TYPE_BUY;
   req.type_filling = ORDER_FILLING_IOC;

   if(!OrderSend(req, res))
      Log("Partial close failed: " + IntegerToString(res.retcode) +
          " | lots=" + DoubleToString(lots, 2));
   else
      Log("Partial close ok | #" + IntegerToString((long)ticket) +
          " | lots=" + DoubleToString(lots, 2));
}

//+------------------------------------------------------------------+
//| Place a pending order, return ticket (0 on failure)              |
//+------------------------------------------------------------------+
ulong PlacePending(ENUM_ORDER_TYPE type, double lots, double price, string comment)
{
   MqlTradeRequest req = {};
   MqlTradeResult  res = {};
   req.action    = TRADE_ACTION_PENDING;
   req.symbol    = _Symbol;
   req.volume    = NormLot(lots);
   req.price     = price;
   req.type      = type;
   req.magic     = InpMagic;
   req.comment   = comment;
   req.type_time = ORDER_TIME_GTC;

   if(OrderSend(req, res))
   {
      Log("Pending placed | " + EnumToString(type) +
          " @ " + DoubleToString(price, _Digits) +
          " lots=" + DoubleToString(lots, 2) +
          " [" + comment + "]");
      return res.order;
   }
   Log("Pending failed: " + IntegerToString(res.retcode) + " [" + comment + "]");
   return 0;
}

//+------------------------------------------------------------------+
//| Per-bar check: close min-lot losing positions from the realized  |
//| profit reserve (g_realizedProfit) when the reserve is sufficient.|
//| Runs every new bar so it reacts to price movement — the floating |
//| loss of a min-lot position may shrink naturally as price recovers|
//| making the reserve adequate without a new profitable close.      |
//| Processes positions oldest-first, consistent with the trim logic.|
//+------------------------------------------------------------------+
void CheckMinLotClosures()
{
   if(g_realizedProfit <= 0) return;   // nothing in reserve yet

   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   bool   closed = false;

   // Loop: find and close the oldest eligible position, repeat until
   // reserve is exhausted or no more min-lot losers can be covered.
   while(true)
   {
      ulong    target     = 0;
      double   targetLoss = 0;
      datetime targetTime = (datetime)0x7FFFFFFF;   // sentinel: far future

      for(int i = PositionsTotal() - 1; i >= 0; i--)
      {
         ulong t = PositionGetTicket(i);
         if(!PositionSelectByTicket(t)) continue;
         if(PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
         if(PositionGetString(POSITION_SYMBOL) != _Symbol)  continue;

         double   lots  = PositionGetDouble(POSITION_VOLUME);
         double   pnl   = PositionGetDouble(POSITION_PROFIT);
         datetime pTime = (datetime)PositionGetInteger(POSITION_TIME);

         if(lots > minLot)             continue;   // still has room for partial trim
         if(pnl  >= 0)                 continue;   // not in loss
         if(MathAbs(pnl) > g_realizedProfit) continue;   // reserve not enough yet

         if(pTime < targetTime)
         {
            target     = t;
            targetLoss = MathAbs(pnl);
            targetTime = pTime;
         }
      }

      if(target == 0) break;   // nothing eligible — exit loop

      Log("Min-lot close (bar) | #" + IntegerToString((long)target) +
          " floating=-$" + DoubleToString(targetLoss, 2) +
          " | realized=$" + DoubleToString(g_realizedProfit, 2) +
          " → reserve after=$" + DoubleToString(g_realizedProfit - targetLoss, 2));

      g_realizedProfit -= targetLoss;
      g_trade.PositionClose(target, 10);
      GlobalVariableDel(TrimKey(target));
      closed = true;
   }

   if(closed) SaveState();
}

//+------------------------------------------------------------------+
//| Cycle end: no positions and no orders remain                     |
//+------------------------------------------------------------------+
bool CheckCycleEnd()
{
   return (CountPositions() == 0 && CountOrders() == 0);
}

void EndCycle()
{
   Log("=== CYCLE END === TotalRealized=" + DoubleToString(g_realizedProfit, 2));
   g_inCycle        = false;
   g_realizedProfit = 0.0;
   g_sqTicket       = 0;
   g_sqDir          = 0;
   GlobalVariableDel(GK("CYCLE"));
   GlobalVariableDel(GK("REAL"));
   GlobalVariableDel(GK("SQTKT"));
   GlobalVariableDel(GK("SQDIR"));
}

//+------------------------------------------------------------------+
//| HWM (High-Water-Mark / Low-Water-Mark) helpers                  |
//+------------------------------------------------------------------+
void   InitHWM(ulong id, double price)  { GlobalVariableSet(HWMKey(id), price); }
double GetHWM (ulong id)                { string k = HWMKey(id); return GlobalVariableCheck(k) ? GlobalVariableGet(k) : 0.0; }
void   SetHWM (ulong id, double val)    { GlobalVariableSet(HWMKey(id), val); }

//+------------------------------------------------------------------+
//| Trim carry-over helpers                                          |
//| A single profitable close's 90% share is often far too small to  |
//| buy even one minimum lot-step of the losing position (Gold's     |
//| contract size means one 0.01 lot step can represent thousands of |
//| USD of floating loss). These persist an unused trim budget (USD) |
//| per losing-ticket so it accumulates across multiple profitable   |
//| closes instead of being silently discarded every time.           |
//+------------------------------------------------------------------+
double GetTrimCarry(ulong id)             { string k = TrimKey(id); return GlobalVariableCheck(k) ? GlobalVariableGet(k) : 0.0; }
void   SetTrimCarry(ulong id, double val) { GlobalVariableSet(TrimKey(id), val); }

//+------------------------------------------------------------------+
//| Broken level memory                                              |
//| Every genuine swing breakout (price closing beyond the prior     |
//| swing range) is remembered as a "broken level": the price plus   |
//| which direction broke it. This rotating buffer (size             |
//| InpLevelCount) is used for two things:                           |
//|  1) Chop filter: suppress a NEW breakout entry that fires right  |
//|     back at a level broken in the OPPOSITE direction (classic    |
//|     retest/fakeout instead of a fresh move).                     |
//|  2) Reversal/fade entry: when price later retests a remembered   |
//|     level and shows a rejection candle that confirms the level   |
//|     is holding (support/resistance flip), open a continuation    |
//|     trade in the ORIGINAL break direction — i.e. fade the local  |
//|     bounce/dip back into the level.                              |
//+------------------------------------------------------------------+
void InitLevelMemory()
{
   ArrayResize(g_levels, InpLevelCount);
   for(int i = 0; i < InpLevelCount; i++)
   {
      g_levels[i].price       = 0;
      g_levels[i].wasBuyBreak = false;
      g_levels[i].brokenTime  = 0;
      g_levels[i].used        = false;
      if(GlobalVariableCheck(LvlPriceKey(i)))
      {
         g_levels[i].price       = GlobalVariableGet(LvlPriceKey(i));
         g_levels[i].wasBuyBreak = GlobalVariableGet(LvlTypeKey(i)) > 0.5;
         g_levels[i].brokenTime  = (datetime)GlobalVariableGet(LvlTimeKey(i));
         g_levels[i].used        = GlobalVariableGet(LvlUsedKey(i)) > 0.5;
      }
   }
   g_levelIdx = GlobalVariableCheck(LvlIdxKey()) ? (int)GlobalVariableGet(LvlIdxKey()) : 0;
}

void SaveLevel(int i)
{
   GlobalVariableSet(LvlPriceKey(i), g_levels[i].price);
   GlobalVariableSet(LvlTypeKey(i),  g_levels[i].wasBuyBreak ? 1.0 : 0.0);
   GlobalVariableSet(LvlTimeKey(i),  (double)g_levels[i].brokenTime);
   GlobalVariableSet(LvlUsedKey(i),  g_levels[i].used ? 1.0 : 0.0);
}

void RememberBrokenLevel(double price, bool wasBuyBreak)
{
   if(!InpLevelMemoryEnable || InpLevelCount <= 0) return;
   int i = g_levelIdx;
   g_levels[i].price       = price;
   g_levels[i].wasBuyBreak = wasBuyBreak;
   g_levels[i].brokenTime  = TimeCurrent();
   g_levels[i].used        = false;
   SaveLevel(i);
   g_levelIdx = (g_levelIdx + 1) % InpLevelCount;
   GlobalVariableSet(LvlIdxKey(), (double)g_levelIdx);
   Log("Level remembered | " + (wasBuyBreak ? "BUY-break(now support)" : "SELL-break(now resistance)") +
       " @ " + DoubleToString(price, _Digits) + " | slot=" + IntegerToString(i));
}

bool LevelExpired(int i)
{
   if(g_levels[i].price <= 0) return true;   // empty slot
   if(InpLevelExpiryBars <= 0) return false;  // expiry disabled
   int bars = iBars(_Symbol, PERIOD_CURRENT);
   int shift = MathMin(InpLevelExpiryBars, bars - 1);
   if(shift <= 0) return false;
   datetime cutoff = iTime(_Symbol, PERIOD_CURRENT, shift);
   return (g_levels[i].brokenTime < cutoff);
}

// Is there already an active remembered level within buffer pips of price?
// Used to dedupe — avoids spamming the rotating buffer with near-identical
// levels every bar during a strong trending move.
bool HasNearbyLevel(double price, int bufferPips)
{
   double buffer = bufferPips * g_pip;
   for(int i = 0; i < InpLevelCount; i++)
   {
      if(g_levels[i].price <= 0 || LevelExpired(i)) continue;
      if(MathAbs(price - g_levels[i].price) <= buffer) return true;
   }
   return false;
}

// Is `price` within buffer pips of an active remembered level that was
// broken in the OPPOSITE direction of `isBuySignal`? That's the chop/fakeout
// case the filter is meant to catch.
bool NearOppositeLevel(double price, bool isBuySignal, double &outLevelPrice)
{
   if(!InpLevelMemoryEnable) return false;
   double buffer = InpLevelBufferPips * g_pip;
   for(int i = 0; i < InpLevelCount; i++)
   {
      if(g_levels[i].price <= 0 || LevelExpired(i)) continue;
      if(g_levels[i].wasBuyBreak == isBuySignal) continue;   // same-direction level, not relevant
      if(MathAbs(price - g_levels[i].price) <= buffer)
      {
         outLevelPrice = g_levels[i].price;
         return true;
      }
   }
   return false;
}

//+------------------------------------------------------------------+
//| Reversal/fade entry: retest-and-rejection of a remembered level  |
//| Runs once per new bar. For each active, unused level checks      |
//| whether the just-closed bar poked into the level's buffer zone   |
//| and rejected back out with a confirming candle — i.e. the old    |
//| support/resistance is holding on the retest.                     |
//+------------------------------------------------------------------+
void CheckLevelReversal()
{
   if(!InpLevelMemoryEnable) return;
   if(iBars(_Symbol, PERIOD_CURRENT) < 2) return;

   double buffer = InpLevelBufferPips * g_pip;
   double open1  = iOpen (_Symbol, PERIOD_CURRENT, 1);
   double close1 = iClose(_Symbol, PERIOD_CURRENT, 1);
   double high1  = iHigh (_Symbol, PERIOD_CURRENT, 1);
   double low1   = iLow  (_Symbol, PERIOD_CURRENT, 1);

   for(int i = 0; i < InpLevelCount; i++)
   {
      if(g_levels[i].price <= 0 || g_levels[i].used) continue;
      if(LevelExpired(i)) continue;

      double lvl = g_levels[i].price;

      if(g_levels[i].wasBuyBreak)
      {
         // Old resistance, now support. Rejection = bar dips into the zone
         // (low touches level+buffer or below) but closes back above the
         // level on a bullish candle -> continuation BUY (fade the dip).
         bool touched  = (low1 <= lvl + buffer);
         bool rejected = touched && close1 > lvl && close1 > open1;
         if(rejected)
         {
            Log("Reversal/fade BUY | retest of broken level @ " + DoubleToString(lvl, _Digits) +
                " | bar low=" + DoubleToString(low1, _Digits) + " close=" + DoubleToString(close1, _Digits));
            OpenReversalEntry(true, lvl);
            g_levels[i].used = true;
            SaveLevel(i);
         }
      }
      else
      {
         // Old support, now resistance. Rejection = bar rallies into the
         // zone (high touches level-buffer or above) but closes back below
         // the level on a bearish candle -> continuation SELL (fade the bounce).
         bool touched  = (high1 >= lvl - buffer);
         bool rejected = touched && close1 < lvl && close1 < open1;
         if(rejected)
         {
            Log("Reversal/fade SELL | retest of broken level @ " + DoubleToString(lvl, _Digits) +
                " | bar high=" + DoubleToString(high1, _Digits) + " close=" + DoubleToString(close1, _Digits));
            OpenReversalEntry(false, lvl);
            g_levels[i].used = true;
            SaveLevel(i);
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Count our positions / orders                                     |
//+------------------------------------------------------------------+
int CountPositions()
{
   int n = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong t = PositionGetTicket(i);
      if(!PositionSelectByTicket(t)) continue;
      if(PositionGetInteger(POSITION_MAGIC) == InpMagic &&
         PositionGetString(POSITION_SYMBOL) == _Symbol) n++;
   }
   return n;
}

int CountOrders()
{
   int n = 0;
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong t = OrderGetTicket(i);
      if(!OrderSelect(t)) continue;
      if(OrderGetInteger(ORDER_MAGIC) == InpMagic &&
         OrderGetString(ORDER_SYMBOL) == _Symbol) n++;
   }
   return n;
}

//+------------------------------------------------------------------+
//| USD notional exposure helpers                                    |
//+------------------------------------------------------------------+

// Reference valuation price for a side: what you'd realize if you closed
// it right now (mirrors ManageTrailingTP's curPrice convention).
double SidePrice(bool isBuy)
{
   return isBuy ? SymbolInfoDouble(_Symbol, SYMBOL_BID)
                : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
}

// Convert a desired USD notional into a normalized lot size at a given price
double UsdToLots(double usd, double price)
{
   if(usd <= 0 || price <= 0 || g_contractSize <= 0) return 0;
   return NormLot(usd / (price * g_contractSize));
}

// Total USD notional of our currently OPEN positions on one side (Buy/Sell)
double SideExposureUSD(bool isBuy)
{
   double total = 0.0;
   double price = SidePrice(isBuy);

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong t = PositionGetTicket(i);
      if(!PositionSelectByTicket(t)) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)  continue;

      bool posIsBuy = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY;
      if(posIsBuy != isBuy) continue;

      total += PositionGetDouble(POSITION_VOLUME) * price * g_contractSize;
   }
   return total;
}

// Total USD notional reserved by our PENDING orders that would open a
// position on one side once triggered (hedge / squeeze pendings)
double SidePendingUSD(bool isBuy)
{
   double total = 0.0;

   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong t = OrderGetTicket(i);
      if(!OrderSelect(t)) continue;
      if(OrderGetInteger(ORDER_MAGIC) != InpMagic) continue;
      if(OrderGetString(ORDER_SYMBOL) != _Symbol)  continue;

      ENUM_ORDER_TYPE ot = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
      bool orderIsBuy;
      if(ot == ORDER_TYPE_BUY_STOP || ot == ORDER_TYPE_BUY_LIMIT)
         orderIsBuy = true;
      else if(ot == ORDER_TYPE_SELL_STOP || ot == ORDER_TYPE_SELL_LIMIT)
         orderIsBuy = false;
      else
         continue;   // not an entry-type pending order

      if(orderIsBuy != isBuy) continue;

      double price = OrderGetDouble(ORDER_PRICE_OPEN);
      total += OrderGetDouble(ORDER_VOLUME_CURRENT) * price * g_contractSize;
   }
   return total;
}

// USD headroom left on one side before InpMaxUSDPerSide would be breached
// (counts both live positions AND pending orders reserved on that side)
double SideHeadroomUSD(bool isBuy)
{
   double used = SideExposureUSD(isBuy) + SidePendingUSD(isBuy);
   double room = InpMaxUSDPerSide - used;
   return (room > 0) ? room : 0.0;
}

// Clamp a lot size so the resulting side exposure never exceeds
// InpMaxUSDPerSide. Returns 0 (via NormLot) if no headroom remains.
double ClampLotsToHeadroom(bool isBuy, double lots, double price)
{
   double headroomLots = UsdToLots(SideHeadroomUSD(isBuy), price);
   return MathMin(NormLot(lots), headroomLots);
}

//+------------------------------------------------------------------+
//| Normalize lot size to broker constraints                         |
//+------------------------------------------------------------------+
double NormLot(double lots)
{
   double minL  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxL  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double step  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   lots = MathFloor(lots / step) * step;
   if(lots < minL) return 0;   // signal: too small, skip
   if(lots > maxL) lots = maxL;
   return NormalizeDouble(lots, 2);
}

//+------------------------------------------------------------------+
//| State persistence across restarts                                |
//+------------------------------------------------------------------+
void SaveState()
{
   GlobalVariableSet(GK("CYCLE"), g_inCycle ? 1.0 : 0.0);
   GlobalVariableSet(GK("REAL"),  g_realizedProfit);
   GlobalVariableSet(GK("SQTKT"), (double)g_sqTicket);
   GlobalVariableSet(GK("SQDIR"), (double)g_sqDir);
}

//+------------------------------------------------------------------+
//| Logging                                                          |
//+------------------------------------------------------------------+
void Log(string msg)
{
   if(InpLog) Print("[HTS] ", msg);
}
//+------------------------------------------------------------------+
