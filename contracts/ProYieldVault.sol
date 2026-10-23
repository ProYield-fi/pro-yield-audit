// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BaseStrategy} from "./BaseStrategy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract ProYieldVault is BaseStrategy {
    using SafeERC20 for IERC20;
    uint256 public performanceFee;
    uint256 public immutable withdrawalFee;
    uint256 public constant RESERVE_BPS = 1000; // 10% of assets kept liquid for withdrawals
    address public immutable feeDistributor;
    mapping(address => bool) public strategies;
    event PerformanceFeeSet(uint256 fee);
    mapping(address => bool) public strategyActive;   // per-strategy circuit breaker
    /// @notice Net profit actually credited to depositors + the fee taken.
    /// Emitted alongside `Harvest` (which is GROSS) so no consumer has to guess
    /// which figure the books moved — audit F-14.
    event HarvestBooked(uint256 netProfit, uint256 feeTaken);
    /// @notice AUDIT F-5: emergencyWithdraw / setStrategyActive / setVault were
    /// silent. These are the highest-consequence owner actions in the contract
    /// and a monitoring system cannot trip on an action that emits nothing.
    event EmergencyWithdraw(uint256 amount, uint256 assetsAfter);
    event StrategyActiveSet(address indexed strategy, bool active);
    event StrategyHarvestFailed(address indexed strategy);
    // ── Beta safety rails (S2 unlock plan): hard limits live in code, not policy.
    // Caps are owner-set; 0 = uncapped. The pause blocks NEW deposits only —
    // withdrawals always stay open so users are never trapped.
    uint256 public tvlCap;         // max totalAssets() in asset units
    uint256 public perUserCap;     // max per-user VALUE in asset units (value, not principal)
    bool public depositsPaused;
    event CapsSet(uint256 tvlCap, uint256 perUserCap);
    event DepositsPausedSet(bool paused);
    uint256 private _totalAssets;
    uint256 private _totalShares;                     // sum of all user shares (ERC-4626 style)
    /// @notice USDC physically held by THIS contract that is already represented
    /// in `_totalAssets`. Any balance ABOVE this figure is an *uncredited
    /// arrival* — real USDC that nobody has claimed yet (a routed fee awaiting
    /// `creditYield`, or a stray donation). It is NOT depositor money and is
    /// never deployable or creditable. See `creditYield` + `allocate`.
    /// Tracking arrivals explicitly is what stops idle float from being credited
    /// a second time (audit F-4): a TOTAL-balance check cannot tell "new money
    /// arrived" from "money was already here".
    uint256 private _accountedBalance;
    address[] public strategyList;
    // Virtual share offset (OpenZeppelin ERC4626 pattern): blunts first-depositor
    // inflation attacks by requiring huge donations to move the share price.
    uint256 private constant SHARE_OFFSET = 1e3;

    constructor(
        address _underlying,
        address initialOwner,
        address _feeDistributor
    ) BaseStrategy(_underlying, initialOwner, "ProYieldVault") {
        require(_feeDistributor != address(0), "ProYieldVault: zero feeDistributor");
        require(_underlying != address(0), "ProYieldVault: zero underlying");
        require(initialOwner != address(0), "ProYieldVault: zero owner");
        feeDistributor = _feeDistributor;
        performanceFee = 1000;
        withdrawalFee = 0; // product promise: NO withdrawal fees (kept for future gating)
    }

    function name() external view override returns (string memory) {
        return "ProYieldVault";
    }

    function totalAssets() public override view returns (uint256) {
        return _totalAssets;
    }

    function totalShares() external view returns (uint256) {
        return _totalShares;
    }

    /// @notice Real USDC held by the vault that is NOT yet represented in
    /// `totalAssets()` — i.e. routed fees awaiting `creditYield`, or a donation.
    /// Creditable yield can never exceed this, which is what makes the
    /// "credit only NEW arrivals, never re-count idle" rule enforceable.
    function uncreditedArrivals() public view returns (uint256) {
        uint256 bal = underlying.balanceOf(address(this));
        return bal > _accountedBalance ? bal - _accountedBalance : 0;
    }

    /// @notice The vault's CASH ledger: USDC held by this contract that is
    /// already represented in `totalAssets()` (deposited principal + booked
    /// profit, minus what left to strategies or depositors). Exposed because
    /// every consumer used to derive it as `balanceOf − uncreditedArrivals()`,
    /// which cannot distinguish "the ledger was debited" from "the ledger is
    /// right" — that is exactly how the F-4 residual write-down stayed
    /// invisible (audit t_b0874348).
    function accountedBalance() external view returns (uint256) {
        return _accountedBalance;
    }

    /// Shares for a given asset amount at the current price (floor).
    function convertToShares(uint256 assets) external view returns (uint256) {
        return _toShares(assets);
    }

    /// Asset value of a share amount at the current price (floor).
    function convertToAssets(uint256 sharesAmt) external view returns (uint256) {
        return _toAssets(sharesAmt); // named sharesAmt — does not shadow BaseStrategy.shares
    }

    /// Max assets `account` can withdraw right now (frontend helper).
    function maxWithdraw(address account) external view returns (uint256) {
        return _toAssets(shares[account]);
    }

    function _toShares(uint256 assets) internal view returns (uint256) {
        if (_totalShares == 0) return assets; // first depositor: 1:1
        return (assets * (_totalShares + SHARE_OFFSET)) / (_totalAssets + SHARE_OFFSET);
    }

    function _toAssets(uint256 sharesAmt) internal view returns (uint256) {
        if (_totalShares == 0) return sharesAmt;
        return (sharesAmt * (_totalAssets + SHARE_OFFSET)) / (_totalShares + SHARE_OFFSET);
    }

    function addStrategy(address strategy) external onlyOwner {
        require(strategy != address(0), "ProYieldVault: zero strategy");
        require(!strategies[strategy], "ProYieldVault: already added");
        // AUDIT F-15: no code check existed, so a typo'd or codeless address
        // was accepted and `allocate()` then burned real USDC into a dead
        // address (a PoC moved 450 USDC to an EOA, no revert). Requiring code
        // turns that class of mistake into a failed Safe transaction.
        require(strategy.code.length > 0, "ProYieldVault: strategy has no code");
        strategies[strategy] = true;
        strategyActive[strategy] = true;   // new strategies start active
        strategyList.push(strategy);
    }

    /// @notice Quarantine one strategy without stopping the whole vault.
    /// Inactive strategies are skipped by allocate() and cannot be harvested into.
    function setStrategyActive(address strategy, bool active) external onlyOwner {
        require(strategies[strategy], "ProYieldVault: not a strategy");
        strategyActive[strategy] = active;
        emit StrategyActiveSet(strategy, active); // audit F-5: was silent
    }

    /// @notice Set the beta safety rails. 0 = uncapped; takes effect immediately.
    function setCaps(uint256 _tvlCap, uint256 _perUserCap) external onlyOwner {
        tvlCap = _tvlCap;
        perUserCap = _perUserCap;
        emit CapsSet(_tvlCap, _perUserCap);
    }

    /// @notice Pause/unpause NEW deposits (withdrawals stay open by design).
    function setDepositsPaused(bool paused) external onlyOwner {
        depositsPaused = paused;
        emit DepositsPausedSet(paused);
    }

    function deposit(uint256 amount) external override nonReentrant {
        _deposit(msg.sender, amount);
    }

    /// @notice Auto-earn / permit sweep deposit: pull `amount` from `user`'s
    /// signed allowance to this vault and mint shares to `user`. Callable only
    /// by `user`, `keeper`, or `owner()`, so a third party cannot grief an open
    /// allowance while the keeper never takes custody of user funds.
    function depositFor(address user, uint256 amount) external nonReentrant {
        require(
            msg.sender == user || msg.sender == keeper || msg.sender == owner(),
            "ProYieldVault: not keeper"
        );
        _deposit(user, amount);
    }

    function _deposit(address user, uint256 amount) internal {
        require(!depositsPaused, "ProYieldVault: deposits paused");
        require(user != address(0), "ProYieldVault: zero user");
        require(amount > 0, "ProYieldVault: zero amount");
        if (tvlCap > 0) {
            require(_totalAssets + amount <= tvlCap, "ProYieldVault: TVL cap reached");
        }
        if (perUserCap > 0) {
            require(_toAssets(shares[user]) + amount <= perUserCap, "ProYieldVault: per-user cap reached");
        }
        uint256 sh = _toShares(amount); // price-aware mint (4626-style)
        require(sh > 0, "ProYieldVault: zero shares"); // dust guard — no free deposits
        shares[user] += sh;
        _totalShares += sh;
        _totalAssets += amount;
        _accountedBalance += amount; // deposited USDC is now represented in the books
        underlying.safeTransferFrom(user, address(this), amount);
        emit Deposit(user, amount);
    }

    function setPerformanceFee(uint256 fee) external onlyOwner {
        require(fee <= 10000, "ProYieldVault: fee too high");
        performanceFee = fee;
        emit PerformanceFeeSet(fee);
    }

    /// @notice Crisis lever: sweep idle USDC to the owner and write the books down
    /// to match. Shares are NOT burned, so every depositor claim falls to ~zero
    /// (the SHARE_OFFSET residue) — this is intentionally a dilutive, last-resort
    /// action, and it stays that way.
    ///
    /// AUDIT F-5 HARDENING:
    ///  1. It now EMITS (`EmergencyWithdraw`) — it was previously silent, so no
    ///     monitor could trip on the single most destructive lever in the vault.
    ///  2. The book reduction is bounded by what is actually BOOKED, not by the
    ///     raw balance. The old `_totalAssets -= balance` underflowed (Panic
    ///     0x11) and reverted whenever a stray 1-wei donation pushed the balance
    ///     one wei above the books — anyone could brick the emergency lever.
    ///  3. It sweeps the FULL idle balance — `underlying.balanceOf(this)`,
    ///     INCLUDING uncredited arrivals. PY-EMERG-01 (yossweh 2026-10-22): this
    ///     bullet used to claim the opposite ("uncredited arrivals are left in
    ///     place"), which the code never did — a routed fee awaiting
    ///     `creditYield` leaves with the rest. That is deliberate: an abandoned
    ///     vault must not keep orphaned cash (there is no other sweep path), and
    ///     `EmergencyWithdraw(balance, totalAssets)` discloses the exact amount
    ///     on-chain. If the owner prefers booked-only (`booked`), that is a
    ///     behavior change, not a doc change — see
    ///     docs/EXTERNAL_FINDINGS_2026-10-22_YOSSWEH.md §PY-EMERG-01.
    function emergencyWithdraw() external onlyOwner nonReentrant {
        uint256 balance = underlying.balanceOf(address(this));
        if (balance == 0) return;
        // Sweep the cash, but write down only the BOOKED part.
        uint256 booked = _totalAssets < balance ? _totalAssets : balance;
        // CEI ORDER (r3 tidy-up): write the books down BEFORE the external
        // transfer. Interactions-first left a window where a reentering
        // msg.sender could observe the cash gone while claims still read the
        // pre-write total. The nonReentrant guard is kept as defense-in-depth,
        // but ordering — not the guard — is the fix.
        _totalAssets -= booked; // Keep liabilities in sync: assets leaving the
        // vault must shrink totalAssets or depositor claims exceed real backing
        // (T-012 follow-up).
        uint256 accounted = _accountedBalance;
        _accountedBalance = accounted > booked ? accounted - booked : 0;
        emit EmergencyWithdraw(balance, _totalAssets); // event precedes the call
        underlying.safeTransfer(msg.sender, balance);
    }

    event LossReported(uint256 amount);
    /// @notice Cash/valuation SPLIT of a write-down (audit F-4 residual,
    /// t_b0874348). `fromIdle` is the part of `amount` that was idle CASH and
    /// physically left the vault; `amount - fromIdle` is a VALUATION loss on
    /// deployed capital, where no USDC moved at all.
    ///
    /// Emitted ALONGSIDE `LossReported(uint256)` rather than replacing it: that
    /// selector's topic0 is what `scripts/loss_report_core.js` and the 6-hourly
    /// DN keeper scan for their cumulative-write-down ledger, and
    /// `test/forge/Fixes.round2.t.sol` asserts it. Changing it would make the
    /// keeper read a fresh build's losses as zero and propose a DOUBLE
    /// write-down — the exact failure the ledger scan exists to prevent.
    event LossValuationSplit(uint256 amount, uint256 fromIdle);

    /// @notice A write-down was CAPPED at the claim total (audit F-4R-2,
    /// t_27c2410c). Emitted only when the cap binds, i.e. when the reported
    /// VALUATION portion of the loss exceeded the booked deployed capital and
    /// the cash ledger would otherwise have been left above `_totalAssets`.
    /// `accountedAfter == _totalAssets` at emission, and the difference
    /// (`accountedBefore - accountedAfter`) stays in the vault as REAL,
    /// unclaimed USDC (`uncreditedArrivals()`) — not as a claim. Absence of this
    /// event means the reported split was internally consistent. Disclosed
    /// rather than silent: silent book corrections are a finding class here
    /// (audit F-5).
    event LossLedgerCappedToClaims(
        uint256 amount, uint256 fromIdle, uint256 accountedBefore, uint256 accountedAfter
    );

    /// @notice Write booked liabilities down to match REAL backing after a
    /// strategy/venue loss (round-2 H1). Owner-only (beta owner = treasury
    /// Safe): the loss is measured from live venue reads off-chain, then
    /// reported here so the remaining depositors socialise it pro-rata
    /// (share price falls for everyone) instead of the books carrying phantom
    /// value while withdrawals revert. Without this call a loss is invisible;
    /// with it, claims always reconcile to what actually backs them.
    ///
    /// AUDIT F-4 RESIDUAL (t_b0874348) — why the split exists. This function
    /// used to debit `_accountedBalance` by the FULL loss, including VALUATION
    /// losses where no USDC ever left the vault. On the boost book the 10-17
    /// write-down zeroed the ledger while `balanceOf(vault)` was untouched, so
    /// `uncreditedArrivals()` then reported 5.000000 of depositor RESERVE as
    /// creditable yield and `creditYield(5_000_000)` succeeded. The cash ledger
    /// now moves only by `fromIdle`, the part of the loss that was physically
    /// idle cash.
    ///
    /// `fromIdle = 0` — the 1-arg selector `scripts/loss_calc_core.js` and the
    /// DN keeper encode, meaning "strategy/valuation loss only" — is
    /// FAIL-CLOSED when cash really vanishes: with `balanceOf <
    /// _accountedBalance`, `uncreditedArrivals()` returns 0, so `creditYield`
    /// can never book a phantom, and `allocate()`'s `deployable <= balance`
    /// check already refuses to ship cash the vault does not hold. An owner who
    /// under-states `fromIdle` therefore loses nothing to crediting; the ledger
    /// simply stays conservative until the split is reported correctly.
    ///
    /// AUDIT F-4R-2 (t_27c2410c): the cash ledger is additionally CAPPED at
    /// `_totalAssets` after the write-down, so it can never describe idle cash
    /// the remaining claims no longer own (see the code comment + the
    /// `LossLedgerCappedToClaims` event).
    function _reportLoss(uint256 amount, uint256 fromIdle) internal {
        require(amount <= _totalAssets, "ProYieldVault: exceeds assets");
        // REVIEW PATCH (F-4R-1): fromIdle must be EVIDENCED, not asserted. The
        // only on-chain proof that booked idle cash actually left the vault is
        // that the balance no longer covers the cash ledger. Bounding it by
        // _accountedBalance alone let a false split re-create the exact F-4
        // phantom (reserve reads as an arrival -> creditYield inflates NAV).
        uint256 bal = underlying.balanceOf(address(this));
        uint256 cashShortfall = _accountedBalance > bal ? _accountedBalance - bal : 0;
        require(fromIdle <= amount && fromIdle <= cashShortfall, "ProYieldVault: bad split");
        _totalAssets -= amount;
        _accountedBalance -= fromIdle;
        // AUDIT F-4R-2 (t_27c2410c): the CASH ledger can never exceed the claim
        // total. `_totalAssets` = booked idle cash (`_accountedBalance`) +
        // deployed book value, so a write-down whose VALUATION part exceeds the
        // deployed book — only reachable when the split is wrong, because a
        // venue cannot lose more than it holds — drove that identity negative
        // and left idle cash booked ABOVE every remaining claim. Reachable
        // state before this cap: deposit 100 (all idle) -> reportLoss(60) gave
        // totalAssets 40 with the ledger still at 100, and `allocate()` then
        // shipped 96 (its reserve is 10% of `_totalAssets`), i.e. the vault
        // deployed cash its own books no longer owned; a claim written down to
        // 40 could exit and leave the remainder stranded in a strategy with no
        // claim against it.
        // Why capping is safe — and NOT a return of the F-4 phantom. The cap
        // only ever moves the ledger DOWN, and after it `_accountedBalance ==
        // _totalAssets`, so there are exactly two cases:
        //  (a) `balanceOf >= _totalAssets` — the vault physically holds more
        //      idle cash than its claims. The residue therefore IS real,
        //      unclaimed USDC: it surfaces as `uncreditedArrivals()` and may be
        //      re-credited (`creditYield`) or swept (`emergencyWithdraw`).
        //      Crediting it cannot break solvency because
        //      `totalAssets + arrivals == balanceOf <= backing`; that is
        //      `invariant_creditable_capacity_is_backed` and echidna's
        //      `echidna_credit_cannot_exceed_backing`. The F-4 defect was the
        //      OPPOSITE direction: it created arrivals out of cash that was
        //      ALREADY counted inside `totalAssets` (live boost book: 5.000000
        //      of depositor reserve creditable with zero new money in).
        //  (b) `balanceOf < _totalAssets` — a cash shortfall the books still
        //      carry (an earlier under-stated split). Then the ledger sits
        //      ABOVE real cash, `uncreditedArrivals()` returns 0, and NOTHING
        //      becomes creditable: the write-down stays fail-closed, exactly as
        //      before this cap. The cap can never manufacture capacity that is
        //      not backed by physical cash.
        uint256 accountedBefore = _accountedBalance;
        if (_accountedBalance > _totalAssets) {
            _accountedBalance = _totalAssets;
            emit LossLedgerCappedToClaims(amount, fromIdle, accountedBefore, _accountedBalance);
        }
        emit LossReported(amount);
        emit LossValuationSplit(amount, fromIdle);
    }

    /// @notice 1-arg form: strategy/venue VALUATION loss (no cash left the
    /// vault). Kept selector-compatible with the existing keepers/scripts.
    function reportLoss(uint256 amount) external onlyOwner {
        _reportLoss(amount, 0);
    }

    /// @notice 2-arg form: state how much of the loss was idle CASH that
    /// actually left the vault (`fromIdle`) and how much was a valuation loss
    /// on deployed capital (the remainder).
    function reportLoss(uint256 amount, uint256 fromIdle) external onlyOwner {
        _reportLoss(amount, fromIdle);
    }

    function allocate() external onlyOwner nonReentrant {
        uint256 balance = underlying.balanceOf(address(this));
        // Keep a liquid reserve so withdrawals never depend on strategy recall.
        uint256 reserve = (_totalAssets * RESERVE_BPS) / 10000;
        // Deploy only REAL, BOOKED assets. An uncredited arrival (a routed fee
        // waiting on creditYield, or a donation) belongs to nobody yet, so
        // shipping it into a strategy would let harvest() book it as profit.
        uint256 accounted = _accountedBalance;
        uint256 deployable = accounted > reserve ? accounted - reserve : 0;
        if (deployable > 0 && deployable <= balance && strategyList.length > 0) {
            // Split only across ACTIVE strategies; inactive ones get nothing.
            uint256 activeCount = 0;
            for (uint i = 0; i < strategyList.length; i++) {
                if (strategies[strategyList[i]] && strategyActive[strategyList[i]]) {
                    activeCount++;
                }
            }
            if (activeCount == 0) return;
            uint256 perStrategy = deployable / activeCount;
            for (uint i = 0; i < strategyList.length; i++) {
                address strategy = strategyList[i];
                if (strategies[strategy] && strategyActive[strategy] && perStrategy > 0) {
                    underlying.safeTransfer(strategy, perStrategy);
                    _accountedBalance -= perStrategy; // left the vault, still on our books
                }
            }
        }
    }

    /// @notice Pull funds back from strategies until `needed` is idle.
    /// Splits the shortfall across active strategies; recall is capped at each
    /// strategy's balance, so a shortfall larger than total recalled reverts
    /// downstream (correct behavior — cannot pay out assets that don't exist).
    function _recallShortfall(uint256 needed) internal {
        uint256 idle = underlying.balanceOf(address(this));
        if (idle >= needed) return;
        uint256 missing = needed - idle;
        uint256 activeCount = 0;
        for (uint i = 0; i < strategyList.length; i++) {
            if (strategies[strategyList[i]] && strategyActive[strategyList[i]]) {
                activeCount++;
            }
        }
        if (activeCount == 0) return; // withdraw will revert on insufficient idle
        uint256 perStrategy = (missing / activeCount) + 1; // round up
        for (uint i = 0; i < strategyList.length && missing > 0; i++) {
            address strategy = strategyList[i];
            if (strategies[strategy] && strategyActive[strategy]) {
                BaseStrategy(strategy).recall(perStrategy);
                uint256 got = underlying.balanceOf(address(this)) - idle;
                idle += got;
                missing = got >= missing ? 0 : missing - got;
            }
        }
    }

    /// @notice User withdrawal by ASSET amount. Shares burned are computed at
    /// the current price (4626-style): when the vault has earned profit, a
    /// user's shares redeem for MORE than they deposited.
    /// Pays from idle; recalls from strategies to cover any shortfall.
    function withdraw(uint256 amount) external nonReentrant {
        require(amount > 0, "ProYieldVault: zero amount");
        require(amount <= totalAssets(), "ProYieldVault: exceeds assets");
        uint256 sh = _toShares(amount);
        require(sh > 0, "ProYieldVault: zero shares");
        require(sh <= shares[msg.sender], "ProYieldVault: exceeds shares");
        // Effects BEFORE interactions (slither reentrancy-no-eth): burn shares
        // and shrink liabilities before any external recall call.
        shares[msg.sender] -= sh;
        _totalShares -= sh;
        _totalAssets -= amount;
        // NOTE (F-4 residual, INFO only): this clamp can leave the cash ledger a
        // rounding residue high (< activeCount × 1 µUSDC per withdrawal, from
        // _recallShortfall's per-strategy round-up). It is NOT the reportLoss
        // defect — no creditable arrival is created, so it stays untouched.
        if (_accountedBalance > amount) {
            _accountedBalance -= amount;
        } else {
            _accountedBalance = 0;
        }
        _recallShortfall(amount);
        underlying.safeTransfer(msg.sender, amount);
        emit Withdraw(msg.sender, amount);
    }

    /// @notice Partial-redemption escape hatch (round-2 H1): withdraw as much
    /// as idle + recallable balance can ACTUALLY pay right now. Never reverts
    /// for illiquidity alone; shares burn only for what is paid, so the rest
    /// of the claim stays on the books. Under a reported loss the price is
    /// already written down and this pays the fair amount; under an
    /// unreported loss it still lets users exit with the real backing that
    /// exists instead of being fully trapped by phantom value.
    function withdrawUpTo(uint256 amount) external nonReentrant returns (uint256 paid) {
        require(amount > 0, "ProYieldVault: zero amount");
        uint256 want = _toAssets(shares[msg.sender]);
        if (amount < want) want = amount;
        require(want > 0, "ProYieldVault: zero shares");
        _recallShortfall(want);
        uint256 bal = underlying.balanceOf(address(this));
        paid = bal < want ? bal : want;
        require(paid > 0, "ProYieldVault: no liquidity");
        uint256 sh = _toShares(paid);
        if (sh > shares[msg.sender]) sh = shares[msg.sender];
        shares[msg.sender] -= sh;
        _totalShares -= sh;
        _totalAssets -= paid;
        if (_accountedBalance > paid) {
            _accountedBalance -= paid;
        } else {
            _accountedBalance = 0;
        }
        underlying.safeTransfer(msg.sender, paid);
        emit Withdraw(msg.sender, paid);
    }

    function harvest() external override nonReentrant {
        // Sweep accrued profit from every active strategy, then take the
        // performance fee on what actually landed (no modeled yield).
        uint256 idleBefore = underlying.balanceOf(address(this));
        uint256 len = strategyList.length;
        for (uint256 i = 0; i < len; i++) {  // calls-loop: vault-authorized strategies only
            address s = strategyList[i];
            if (strategies[s] && strategyActive[s]) {
                // Resilient sweep: ONE broken strategy must never brick the
                // whole vault's harvest (profits of healthy strategies would
                // strand, keeper loops, fee loop stalls). Skip + emit; the
                // strategy stays visible for ops/owner intervention.
                try BaseStrategy(s).harvest() {
                } catch {
                    emit StrategyHarvestFailed(s);
                }
            }
        }
        uint256 totalProfit = underlying.balanceOf(address(this)) - idleBefore;
        if (totalProfit > 0 && performanceFee > 0) {
            uint256 fee = (totalProfit * performanceFee) / 10000;
            if (fee > 0) underlying.safeTransfer(feeDistributor, fee);
        }
        // Profit attribution (4626-style): NET profit (after fee) raises the
        // share price — every depositor earns pro-rata. Fees leave accounting.
        if (totalProfit > _feeOn(totalProfit)) {
            uint256 net = totalProfit - _feeOn(totalProfit);
            _totalAssets += net;
            // The swept USDC is now represented in the books. Only the NET
            // remains in the vault (the fee already left to the FeeDistributor),
            // so that is exactly what becomes accounted — never re-count the fee.
            if (_accountedBalance + net <= underlying.balanceOf(address(this))) {
                _accountedBalance += net;
            } else {
                _accountedBalance = underlying.balanceOf(address(this));
            }
        }
        lastHarvest = block.timestamp;
        // AUDIT F-14 FIX: this used to emit the GROSS profit while only the NET
        // (after the performance fee) was booked, so any consumer reading the
        // event — the dashboard reads exactly this — overstated depositor yield
        // by the fee. Emit both, explicitly.
        emit Harvest(totalProfit);
        emit HarvestBooked(totalProfit - _feeOn(totalProfit), _feeOn(totalProfit));
    }

    /// Fee mirror of harvest's calculation (internal, avoids duplication).
    function _feeOn(uint256 profit) internal view returns (uint256) {
        if (performanceFee == 0) return 0;
        return (profit * performanceFee) / 10000;
    }

    /// @notice Credit EXTERNAL yield (fee recycling, rebates, grants) to
    /// depositors by raising the share price. Flow: the recycler routes X
    /// USDC into this vault (FeeDistributor.route), then calls creditYield(X).
    ///
    /// AUDIT F-4 FIX. The old guard was `balanceOf(this) >= amount` — a TOTAL
    /// balance check, which cannot distinguish "new money arrived" from "money
    /// was already here". That let the owner re-credit the idle float (depositor
    /// principal / the 10% reserve), inflating totalAssets with zero new money:
    /// an early depositor could then redeem at a doubled price and take real
    /// USDC from other depositors, while honest withdrawals reverted.
    ///
    /// The credit is now bounded by `uncreditedArrivals()` — real USDC that has
    /// physically arrived and is not yet represented in the books. Idempotent by
    /// construction: crediting consumes the arrival, so the same funds can never
    /// be credited twice, and the documented invariant "credit only NEW arrivals,
    /// never re-count idle" is now enforced rather than merely asserted.
    event YieldCredited(uint256 amount);

    /// @notice PRINCIPAL returned by a strategy and booked as accounted cash
    /// WITHOUT raising `_totalAssets` (see `onStrategyReturn`). Distinct from
    /// `YieldCredited`, which raises the share price.
    event StrategyReturnBooked(address indexed strategy, uint256 amount);

    function creditYield(uint256 amount) external onlyOwner nonReentrant {
        require(amount > 0, "ProYieldVault: zero amount");
        uint256 arrivals = uncreditedArrivals();
        require(amount <= arrivals, "ProYieldVault: exceeds uncredited arrivals");
        _totalAssets += amount;
        _accountedBalance += amount;
        emit YieldCredited(amount);
    }

    /// @notice AUDIT F-5. Callable ONLY by a registered strategy (the sUSD3
    /// sleeve calls it from `pushIdle` when it returns capital). Books returned
    /// PRINCIPAL so the next `allocate()` can redeploy it, while — unlike
    /// `creditYield` — NEVER raising `_totalAssets`.
    ///
    /// Why: `allocate()` ships `_accountedBalance - reserve` and decrements
    /// `_accountedBalance` when money leaves, but `_totalAssets` stays put (the
    /// capital is still on the vault's books). A strategy returning that
    /// principal arrives as a plain transfer, which used to land as an
    /// `uncreditedArrival`: `allocate()` could not redeploy it and the only
    /// owner lever, `creditYield`, would double-count it (reproduced: vault
    /// 1,900 vs 1,000 real). This hook raises only the accounted balance.
    ///
    /// Bounded by `uncreditedArrivals()` so it is idempotent and can never book
    /// phantom value: a strategy cannot conjure accounted cash the vault does
    /// not physically hold beyond what is already represented.
    function onStrategyReturn(uint256 amount) external nonReentrant {
        require(strategies[msg.sender], "ProYieldVault: not a strategy");
        if (amount == 0) return;
        uint256 arrivals = uncreditedArrivals();
        uint256 add = amount > arrivals ? arrivals : amount;
        if (add == 0) return; // nothing new arrived — never double-book
        _accountedBalance += add;
        emit StrategyReturnBooked(msg.sender, add);
    }

    function harvestStrategy(address strategy) external onlyOwner nonReentrant {
        require(strategies[strategy], "ProYieldVault: not a strategy");
        require(strategyActive[strategy], "ProYieldVault: strategy paused");
        require(strategy != address(0), "ProYieldVault: zero strategy");
        BaseStrategy(strategy).harvest();
    }
}
