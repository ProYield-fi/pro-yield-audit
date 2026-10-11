// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * KinkWrapper — senior/junior fixed/floating tranches over an HL Earn engine.
 *
 * AUDIT-BUNDLE BUILD v2 (2026-10-04) — Option B, docs/KINK_WRAPPER_DESIGN.md.
 * NOT DEPLOYED. One contract, two share classes, epoch settlement.
 *
 * Architecture (uses the engine's REAL vault-facing API — verified 2026-10-04):
 *   - The engine is a standalone HLEarnStrategy instance whose `vault` IS this
 *     contract (Safe executes engine.setVault(wrapper) once at wiring). That
 *     grants the wrapper exactly two authorities:
 *       * engine.harvest() called BY the vault → syncs earn AND sweeps realized
 *         profit above the engine's liquidity buffer as REAL USDC to the wrapper;
 *       * engine.recall(amount) → pays EVM idle USDC to the wrapper (vault-only,
 *         capped at balance), used by the keeper to top up the withdrawal float.
 *   - The wrapper keeps a liquid float (reserveBps, default 10% of net principal,
 *     mirroring the house liquid-reserve policy) for withdrawals; deposits push
 *     the excess to the engine, whose keeper supplies it to HyperCore borrow/lend
 *     under the always-on policy (standard keeper mode — no kink gate).
 *
 * Accounting model (single invariant, all USDC 6dp):
 *   systemValue()  = wrapper USDC float + engine.totalAssets()
 *   principalNet   = totalDeposited − totalWithdrawn
 *   bookValue      = principalNet + cumYieldSettled
 *   At settlement: yieldEpoch = systemValue − bookValue.
 *     yieldEpoch ≥ seniorOwed → seniors get seniorOwed, juniors the residual;
 *     0 ≤ yieldEpoch < seniorOwed → seniors get yieldEpoch, juniors zero;
 *     yieldEpoch < 0 → LOSS: junior share value absorbs first, then senior
 *     (explicit LossSocialized event, never silent); cumYieldSettled re-anchors.
 *
 * Invariants the audit must confirm:
 *  1. USDC conservation: every user inflow/outflow is accounted; systemValue −
 *     bookValue changes ONLY through engine profit/loss between settlements.
 *  2. Senior payout is capped at the epoch fixed rate; junior takes the residual.
 *  3. No oracle: fixedRateBps is an owner parameter set at epoch open from the
 *     off-chain dwell table (ratchet schedule); timelock in production.
 *  4. settleEpoch() is permissionless after epoch end; float pulls are
 *     keeper/owner-gated (engine.recall is vault-gated inside the engine).
 *  5. Senior fixed rate accrues PER SECOND on senior value (Compound-style
 *     accumulator: seniorAssetSeconds) at the epoch's locked rate — mid-epoch
 *     entries earn from their entry moment, no epoch-0 hole.
 *  6. Withdrawals never touch unsettled yield — float-served only.
 */

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface IHLEarnEngine {
    /// @notice Engine mark: idle USDC + Core lending position value (6dp).
    function totalAssets() external view returns (uint256);
    /// @notice Vault-only: sync earn; as vault, sweeps realized profit to caller.
    function harvest() external returns (uint256 swept);
    /// @notice Vault-only: pay EVM idle USDC to the vault (capped at balance).
    function recall(uint256 amount) external;
}

contract KinkWrapper is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    IERC20 public immutable usdc;
    IHLEarnEngine public immutable engine;
    uint64  public immutable epochDays;

    uint256 public constant BPS_DENOM = 10_000;
    uint256 public constant VIRTUAL_OFFSET = 1_000;   // anti-inflation offset in conversions (audit F1, OZ-v5 style)
    uint256 public constant MIN_DEPOSIT = 1e6;        // $1 — kills 1-wei share games (audit F1)
    uint256 public constant MAX_RATE_BPS = 10_000;    // sanity cap on the fixed rate

    // ── Tranche ledgers (6dp value units; 1 share ≈ $1 at genesis price) ──────
    uint256 public totalSeniorShares;
    uint256 public totalJuniorShares;
    uint256 public seniorAssets;   // principal + settled senior payouts
    uint256 public juniorAssets;   // principal + settled junior payouts
    mapping(address => uint256) public seniorShares;
    mapping(address => uint256) public juniorShares;

    // ── System accounting ──────────────────────────────────────────────────────
    uint256 public totalDeposited;    // gross USDC in (both tranches)
    uint256 public totalWithdrawn;    // gross USDC out (both tranches)
    uint256 public cumYieldSettled;   // anchor: cumulative yield distributed so far
    uint256 public cumLoss;           // cumulative loss absorbed by tranches (junior first)
    uint256 public immutable reserveBps; // withdrawal float target, % of net principal (ctor-only)
    uint32  public nextFixedRateBps;  // owner-queued rate for the NEXT epoch (audit F2: never caller-chosen)
    uint256 public seniorAssetSeconds;// per-second senior-value accumulator (fixed-rate basis)
    uint256 public lastTouch;         // last accumulator touch (unix)

    address public keeper;            // ops EOA allowed to pull engine liquidity

    // ── Epochs ─────────────────────────────────────────────────────────────────
    struct Epoch {
        uint64 start;
        uint64 end;
        uint32 fixedRateBps;          // annual, set at open
        bool settled;
        uint256 seniorAssetsAtOpen;   // obligation basis
        uint256 seniorOwed;
        uint256 yieldEpoch;
        uint256 seniorPaid;
        uint256 juniorPaid;
    }
    Epoch[] public epochs;

    event Deposited(address indexed user, bool indexed senior, uint256 amount, uint256 shares, uint256 epochId);
    event Withdrawn(address indexed user, bool indexed senior, uint256 shares, uint256 value);
    event EpochOpened(uint256 indexed epochId, uint64 start, uint64 end, uint32 fixedRateBps);
    event EpochSettled(uint256 indexed epochId, uint256 yieldEpoch, uint256 seniorPaid, uint256 juniorPaid);
    event EngineHarvest(uint256 swept);
    event EngineLiquidityPulled(uint256 amount);
    event LossSocialized(uint256 indexed epochId, uint256 juniorLoss, uint256 seniorLoss);
    event KeeperSet(address indexed keeper);
    event NextRateQueued(uint32 rate);

    error EpochNotEnded();
    error EpochAlreadySettled();
    error ZeroAmount();
    error InsufficientFloat();
    error NotKeeper();
    error InsufficientShares();
    error BadRate();
    error BelowMinDeposit();

    constructor(
        address _usdc,
        address _engine,
        uint32 _firstFixedRateBps,
        uint64 _epochDays,
        uint256 _reserveBps
    ) Ownable2Step() Ownable(msg.sender) {
        usdc = IERC20(_usdc);
        engine = IHLEarnEngine(_engine);
        epochDays = _epochDays;
        reserveBps = _reserveBps;
        nextFixedRateBps = _firstFixedRateBps;
        lastTouch = block.timestamp;
        _openEpoch(_firstFixedRateBps);
    }

    /// @notice Bank per-second senior value since the last touch (fixed-rate basis).
    function _touch() internal {
        seniorAssetSeconds += seniorAssets * (block.timestamp - lastTouch);
        lastTouch = block.timestamp;
    }

    // ── Views ──────────────────────────────────────────────────────────────────
    function epochsLength() external view returns (uint256) { return epochs.length; }
    function currentEpoch() external view returns (Epoch memory) { return epochs[epochs.length - 1]; }

    /// @notice Total system USDC: wrapper float + engine mark.
    function systemValue() public view returns (uint256) {
        return usdc.balanceOf(address(this)) + engine.totalAssets();
    }

    /// @notice Net principal owed to users if everything settled at par.
    function principalNet() public view returns (uint256) {
        return totalDeposited - totalWithdrawn;
    }

    /// @notice Cumulative floating (unsettled) yield.
    function floatingYield() external view returns (uint256) {
        uint256 bv = principalNet() - cumLoss + cumYieldSettled;
        return systemValue() > bv ? systemValue() - bv : 0;
    }

    /// @notice Senior obligation accrued so far this epoch (view for UI/keeper).
    function seniorOwedPreview() external view returns (uint256 owed) {
        Epoch storage e = epochs[epochs.length - 1];
        uint256 seconds_ = seniorAssetSeconds + seniorAssets * (block.timestamp - lastTouch);
        owed = seconds_ * e.fixedRateBps / (BPS_DENOM * 365 days);
    }

    function seniorValueOf(address user) external view returns (uint256) {
        if (totalSeniorShares == 0) return 0;
        return _seniorValueFor(seniorShares[user]);
    }

    function juniorValueOf(address user) external view returns (uint256) {
        if (totalJuniorShares == 0) return 0;
        return _juniorValueFor(juniorShares[user]);
    }

    // ── Admin ──────────────────────────────────────────────────────────────────
    function setKeeper(address k) external onlyOwner {
        if (k == address(0)) revert ZeroAmount();
        keeper = k;
        emit KeeperSet(k);
    }

    /// @notice Queue the NEXT epoch's fixed rate. Owner-only (audit F2: a
    /// permissionless settle must not let anyone set the rate), monotonic
    /// non-decreasing (ratchet rule: never down), sanity-capped.
    function setNextFixedRateBps(uint32 rate) external onlyOwner {
        if (rate < nextFixedRateBps || rate > MAX_RATE_BPS) revert BadRate(); // monotonic vs the QUEUED rate
        nextFixedRateBps = rate;
        emit NextRateQueued(rate);
    }

    // ── Deposits ───────────────────────────────────────────────────────────────
    function depositSenior(uint256 amount) external nonReentrant {
        if (amount < MIN_DEPOSIT) revert BelowMinDeposit();
        _touch();
        usdc.safeTransferFrom(msg.sender, address(this), amount);
        totalDeposited += amount;
        uint256 shares = _toSeniorShares(amount);
        seniorShares[msg.sender] += shares;
        totalSeniorShares += shares;
        seniorAssets += amount;
        _pushToEngine(amount);
        emit Deposited(msg.sender, true, amount, shares, epochs.length - 1);
    }

    function depositJunior(uint256 amount) external nonReentrant {
        if (amount < MIN_DEPOSIT) revert BelowMinDeposit();
        _touch();
        usdc.safeTransferFrom(msg.sender, address(this), amount);
        totalDeposited += amount;
        uint256 shares = _toJuniorShares(amount);
        juniorShares[msg.sender] += shares;
        totalJuniorShares += shares;
        juniorAssets += amount;
        _pushToEngine(amount);
        emit Deposited(msg.sender, false, amount, shares, epochs.length - 1);
    }

    /// @notice Push the deposit's excess above the float target to the engine.
    /// float already INCLUDES the freshly received amount.
    function _pushToEngine(uint256 amount) internal {
        uint256 float = usdc.balanceOf(address(this));
        uint256 target = principalNet() * reserveBps / BPS_DENOM;
        uint256 pushed = float > target ? float - target : 0;
        if (pushed > amount) pushed = amount; // never push more than received
        if (pushed > 0) usdc.safeTransfer(address(engine), pushed);
    }

    /// @notice Deposit-side conversion: virtual offset (audit F1) makes the
    /// first deposit value-neutral and donation inflation unprofitable.
    function _toSeniorShares(uint256 amount) internal view returns (uint256) {
        return amount * (totalSeniorShares + VIRTUAL_OFFSET) / (seniorAssets + VIRTUAL_OFFSET);
    }

    function _toJuniorShares(uint256 amount) internal view returns (uint256) {
        return amount * (totalJuniorShares + VIRTUAL_OFFSET) / (juniorAssets + VIRTUAL_OFFSET);
    }

    /// @notice Withdraw-side conversion (inverse, offset-consistent).
    function _seniorValueFor(uint256 shares) internal view returns (uint256) {
        return shares * (seniorAssets + VIRTUAL_OFFSET) / (totalSeniorShares + VIRTUAL_OFFSET);
    }

    function _juniorValueFor(uint256 shares) internal view returns (uint256) {
        return shares * (juniorAssets + VIRTUAL_OFFSET) / (totalJuniorShares + VIRTUAL_OFFSET);
    }

    // ── Withdrawals (settled-value; float-served only) ──────────────────────────
    function withdrawSenior(uint256 shares) external nonReentrant {
        if (shares == 0) revert ZeroAmount();
        if (shares > seniorShares[msg.sender]) revert InsufficientShares();
        _touch();
        uint256 value = _seniorValueFor(shares);
        seniorShares[msg.sender] -= shares;
        totalSeniorShares -= shares;
        seniorAssets -= value;
        uint256 bal = usdc.balanceOf(address(this));
        if (value > bal) revert InsufficientFloat();
        usdc.safeTransfer(msg.sender, value);
        totalWithdrawn += value;
        emit Withdrawn(msg.sender, true, shares, value);
    }

    function withdrawJunior(uint256 shares) external nonReentrant {
        if (shares == 0) revert ZeroAmount();
        if (shares > juniorShares[msg.sender]) revert InsufficientShares();
        uint256 value = _juniorValueFor(shares);
        juniorShares[msg.sender] -= shares;
        totalJuniorShares -= shares;
        juniorAssets -= value;
        uint256 bal = usdc.balanceOf(address(this));
        if (value > bal) revert InsufficientFloat();
        usdc.safeTransfer(msg.sender, value);
        totalWithdrawn += value;
        emit Withdrawn(msg.sender, false, shares, value);
    }

    // ── Engine liquidity (keeper/owner) ────────────────────────────────────────
    /// @notice Pull EVM idle USDC from the engine into the withdrawal float.
    function pullLiquidity(uint256 amount) external {
        if (msg.sender != owner() && msg.sender != keeper) revert NotKeeper();
        engine.recall(amount);
        emit EngineLiquidityPulled(amount);
    }

    /// @notice Sync + sweep realized engine profit into the float (vault path).
    /// Permissionless — the engine itself gates the sweep to its vault (us).
    function harvestEngine() external nonReentrant returns (uint256 swept) {
        swept = engine.harvest();
        if (swept > 0) emit EngineHarvest(swept);
    }

    // ── Epoch lifecycle ────────────────────────────────────────────────────────
    function _openEpoch(uint32 fixedRateBps) internal {
        uint64 start = uint64(block.timestamp);
        Epoch storage e = epochs.push();
        e.start = start;
        e.end = uint64(start + epochDays * 1 days);
        e.fixedRateBps = fixedRateBps;
        e.seniorAssetsAtOpen = seniorAssets;
        emit EpochOpened(epochs.length - 1, start, e.end, fixedRateBps);
    }

    /// @notice Permissionless settlement after epoch end; opens the next epoch
    /// at the owner-queued rate (audit F2/F3: caller cannot set the rate, and a
    /// reverting engine harvest no longer blocks settlement).
    function settleEpoch() external nonReentrant {
        Epoch storage e = epochs[epochs.length - 1];
        if (block.timestamp < e.end) revert EpochNotEnded();
        if (e.settled) revert EpochAlreadySettled();
        e.settled = true;

        // Harvest whatever is sweepable first so settled yield is REAL USDC.
        // Non-fatal: if the engine reverts (e.g. deactivated), settle proceeds
        // on the current mark; the sweep is retried at the next settlement.
        try engine.harvest() returns (uint256 swept) {
            if (swept > 0) emit EngineHarvest(swept);
        } catch { /* sync retry at next settlement */ }

        uint256 sv = systemValue();
        uint256 book = principalNet() - cumLoss + cumYieldSettled;

        if (sv >= book) {
            // Normal waterfall: fixed-first, junior residual. Obligation is the
            // per-second accrual on senior value (Compound-style accumulator).
            _touch();
            uint256 owed = seniorAssetSeconds * e.fixedRateBps / (BPS_DENOM * 365 days);
            uint256 yieldEpoch = sv - book;
            uint256 seniorPool = yieldEpoch > owed ? owed : yieldEpoch;
            uint256 juniorPool = yieldEpoch - seniorPool;
            e.seniorOwed = owed;
            e.yieldEpoch = yieldEpoch;
            e.seniorPaid = seniorPool;
            e.juniorPaid = juniorPool;
            seniorAssets += seniorPool;
            juniorAssets += juniorPool;
            cumYieldSettled += yieldEpoch;
            seniorAssetSeconds = 0; // fresh epoch accrual
            emit EpochSettled(epochs.length - 1, yieldEpoch, seniorPool, juniorPool);
        } else {
            // LOSS: junior value absorbs first, then senior; the cumLoss anchor
            // keeps future settlements incremental (a later profit recovery
            // flows through share prices, never double-credits the loss).
            uint256 shortfall = book - sv;
            uint256 juniorLoss = juniorAssets < shortfall ? juniorAssets : shortfall;
            juniorAssets -= juniorLoss;
            uint256 seniorHit = shortfall - juniorLoss;
            uint256 seniorLoss = seniorAssets < seniorHit ? seniorAssets : seniorHit;
            seniorAssets -= seniorLoss;
            cumLoss += shortfall; // full shortfall anchors the book down
            e.yieldEpoch = shortfall; // signed-loss recorded as the shortfall size
            seniorAssetSeconds = 0; // fresh epoch accrual
            emit LossSocialized(epochs.length - 1, juniorLoss, seniorLoss);
            emit EpochSettled(epochs.length - 1, 0, 0, 0);
        }

        _openEpoch(nextFixedRateBps);
        // queue persists after open: rate stays flat epoch-to-epoch unless the
        // owner ratchets via setNextFixedRateBps (monotonic vs the new epoch).
    }
}