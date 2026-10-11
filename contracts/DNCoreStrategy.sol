// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BaseStrategy} from "./BaseStrategy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {DNCoreBase} from "./adapters/DNCoreBase.sol";

/// @title DNCoreStrategy — vault-integrated delta-neutral execution on HyperCore
/// @notice The vault strategy wrapper over DNCoreBase (the shared execution
/// layer). The contract is its own HyperCore actor: it bridges USDC to Core,
/// class-transfers to perp, places the short hedge, and reads its Core equity
/// back through the read precompiles. Execution lives ONCE in DNCoreBase;
/// this contract adds the honest-accounting + vault wiring.
///
/// ⚠️ PENDING RE-AUDIT + OWNER GO — DO NOT DEPLOY (security review t_3a89fe76).
/// The A3 fix below changes `bridgeBackToEvm` on a LIVE, in-scope contract. It
/// is prepared here for the DN lane (card t_8c66d27f): forge regression added,
/// security re-review requested. No deploy until the diff is re-audited AND the
/// owner writes GO on the task thread. The keeper's all-legs profit basis stays
/// INERT (`DN_ALL_LEGS_PROFIT` unset + this getter absent on the deployed build)
/// until the coordinated change lands.
///
/// HONEST ACCOUNTING (repo discipline — see SkyStrategy/MorphoStrategy audits):
/// - `corePrincipal6`  = net USDC we sent to Core (never counted as yield).
/// - `coreEquity6`     = Core account value, refreshed by syncCore() reads.
/// - profit on Core    = equity - principal; only the EXCESS is realizable.
/// - `profitRealized`  = profit actually bridged back to EVM (underlying units).
/// - harvest() by the VAULT sweeps realized profit above the liquidity buffer
///   to the vault; by the keeper it only syncs (settle, no movement).
///
/// ASYNC RECALL (CoreWriter actions are fire-and-forget + delayed seconds):
/// - This contract keeps `bufferBps` of assets idle on EVM for instant vault
///   recalls (BaseStrategy.recall is vault-only, transfers idle balance).
/// - Larger recalls: keeper unwinds first (moveUsdcToSpot -> bridgeBackToEvm),
///   then the vault recalls. Documented in docs/DN_COREWRITER_ADAPTER.md.
contract DNCoreStrategy is BaseStrategy, DNCoreBase {
    using SafeERC20 for IERC20;

    /*//////////////////////// Config ////////////////////////*/
    /// @notice Scale from Core 6dp USDC to underlying token units
    /// (1 for real USDC; 1e12 for an 18-decimals test token).
    uint256 public immutable coreScale;
    uint256 public bufferBps = 1500; // liquidity buffer (bps of assets, <= 5000)
    uint256 internal constant MAX_BUFFER_BPS = 5000; // getter unused; internal for deploy budget

    /*//////////////////////// Core accounting (6dp, Core-native) ////////////////////////*/
    int256 public coreEquity6;      // Core account value (margin summary), last sync
    uint256 public corePrincipal6;  // net USDC sent to Core (principal only)
    int64 public lastPositionSzi;   // last synced perp position size
    uint256 internal lastSync; // getter unused; internal for deploy budget

    /*//////////////////////// Profit (underlying units) ////////////////////////*/
    uint256 public profitRealized;  // profit bridged back to EVM
    uint256 public profitSwept;     // profit already sent to the vault

    /*//////////////////////// Custom errors (EIP-170 size discipline) ////////////////////////*/
    error DNCore__DecimalsTooLow();
    error DNCore__SubDust();
    error DNCore__ExceedsBalance();
    error DNCore__ExceedsEquity();
    error DNCore__ExceedsSpot();
    error DNCore__BufferTooHigh();
    error DNCore__Inactive();
    error DNCore__NotAuthorized();
    error DNCore__BelowSwept();

    /*//////////////////////// Events (strategy-specific) ////////////////////////*/
    event BridgeToCore(uint256 evmAmount, uint64 coreAmount6);
    event BridgeToEvm(uint64 amount6, uint64 principalReduced6, uint64 profitRealized6);
    event CoreSynced(int256 equity6, int64 szi, uint256 timestamp);
    event ProfitSwept(uint256 amount);
    event ProfitReconciled(uint256 oldRealized, uint256 newRealized);
    event BufferSet(uint256 bufferBps);

    constructor(address _underlying, address initialOwner, uint32 _perpAsset, uint256 _maxActionUsd6)
        BaseStrategy(_underlying, initialOwner, "DeltaNeutralCore")
        DNCoreBase(_perpAsset, _maxActionUsd6)
    {
        uint8 dec = IERC20Metadata(_underlying).decimals();
        if (dec < 6) revert DNCore__DecimalsTooLow();
        coreScale = 10 ** (dec - 6);
    }

    /*//////////////////////// BaseStrategy seams ////////////////////////*/
    function _keeper() internal view override returns (address) {
        return keeper; // BaseStrategy.keeper (owner-set)
    }

    /*//////////////////////// Admin ////////////////////////*/
    function setBufferBps(uint256 bufferBps_) external onlyOwner {
        if (bufferBps_ > MAX_BUFFER_BPS) revert DNCore__BufferTooHigh();
        bufferBps = bufferBps_;
        emit BufferSet(bufferBps_);
    }

    /*//////////////////////// Core account lifecycle ////////////////////////*/
    /// @notice Bridge USDC EVM->Core (lands in the contract's SPOT balance).
    /// Initializes the Core account; actions must be sent in a LATER block.
    function bridgeUsdcToCore(uint256 evmAmount) external onlyKeeper notPaused nonReentrant {
        if (evmAmount == 0) revert DNCore__ZeroAmount();
        if (evmAmount % coreScale != 0) revert DNCore__SubDust();
        if (evmAmount > underlying.balanceOf(address(this))) revert DNCore__ExceedsBalance();
        uint64 core6 = uint64(evmAmount / coreScale);
        corePrincipal6 += core6;
        emit BridgeToCore(evmAmount, core6);
        _bridgeUsdcIn(underlying, evmAmount);
    }

    /// @notice Return USDC Core->EVM (sendAsset to the USDC system address).
    /// Requires HYPE on Core for transfer gas. Splits the amount at the
    /// FRESHLY-SYNCED **all-legs** equity: while equity > principal, an outflow
    /// draws from the PROFIT portion FIRST (principal stays invested, keeping
    /// the hedge margin sized), so a profit-sized skim realizes profit instead
    /// of silently consuming principal basis (round-2 HIGH-1).
    ///   profitAvail = max(0, allLegsEquity - principal)
    ///   profitRed   = min(amount, profitAvail);  principalRed = amount - profitRed
    /// Full-amount drains are unchanged (profitAvail is realized, the rest is
    /// principal); in a loss (allLegsEquity < principal) every unit is principal.
    ///
    /// A3 FIX 1 (security re-review t_42954aa0, FINDING 1). The SPLIT stays on
    /// the honest ALL-LEGS equity (perp account value + Core spot USDC cash +
    /// spot hedge at the live mark): while a hedge is held most of the bridged
    /// capital sits in the spot leg, so perp-only `coreEquity6` sits far below
    /// `corePrincipal6` and a perp-only split booked every outflow as PRINCIPAL
    /// (shaving the ledger; AUDIT_SCOPE inv1). The BOUND, however, must be the
    /// SOURCE OF FUNDS: `_sendUsdcToEvm` draws the Core SPOT USDC balance, so
    /// `amount6` is bounded by `coreSpotUsdc6()` — the all-legs equity includes
    /// perp margin + the hedge, which cannot be sent as USDC. This mirrors the
    /// shipped sibling `HLEarnStrategy.bridgeBackToEvm`.
    ///   profitAvail = max(0, allLegsEquity - principal)
    ///   profitRed   = min(amount, profitAvail);  principalRed = amount - profitRed
    function bridgeBackToEvm(uint64 amount6) external onlyKeeper notPaused coreAccountRequired nonReentrant {
        if (amount6 == 0) revert DNCore__ZeroAmount();
        _syncCore();
        // A3 FIX 1: bound the outflow on the balance it is actually sourced from
        // (Core spot USDC), not the all-legs equity. Pre-fix an unsourceable
        // amount was admitted, the sendAsset dropped SILENTLY by HyperCore, and
        // the contract still mutated principal/profitRealized — booking real
        // principal as yield.
        uint64 spot6 = coreSpotUsdc6();
        if (amount6 > spot6) revert DNCore__ExceedsSpot();
        // Split STAYS on the all-legs basis (correct). The trailing check keeps
        // `amount <= all-legs` so `principalRed` can never exceed `corePrincipal6`
        // (amount > all-legs would underflow the ledger decrement below).
        int256 allLegs6 = coreAllLegsEquity6();
        if (int256(uint256(amount6)) > allLegs6) revert DNCore__ExceedsEquity();
        uint64 profitAvail = allLegs6 > int256(corePrincipal6)
            ? uint64(uint256(allLegs6 - int256(corePrincipal6)))
            : 0;
        uint64 profitRed = amount6 < profitAvail ? amount6 : profitAvail;
        uint64 principalRed = amount6 - profitRed;
        corePrincipal6 -= principalRed;
        // A3 FIX 2 (FINDING 2): do NOT debit the perp leg (`coreEquity6`) for a
        // spot-sourced outflow — `coreEquity6` is the PERP account value, which
        // this action does not change. totalAssets() now counts Core spot USDC
        // cash live, so the Core->EVM move is naturally NAV-neutral (spot down,
        // idle EVM up). The removed `coreEquity6 -= amount6` was a fudge that
        // (a) double-decremented on the keeper's staged moveUsdcToSpot ->
        // bridge path (inv3 break), and (b) could drive `coreEquity6` negative,
        // inflating totalAssets via its `> 0` clamp.
        if (profitRed > 0) {
            profitRealized += uint256(profitRed) * coreScale;
        }
        emit BridgeToEvm(amount6, principalRed, profitRed);
        _sendUsdcToEvm(amount6);
    }

    /*//////////////////////// Core sync (read precompiles) ////////////////////////*/
    /// @notice Refresh Core equity + position from HyperCore state. Permissionless:
    /// it only records what the precompiles report.
    function syncCore() external {
        _syncCore();
    }

    function _syncCore() internal {
        AccountMarginSummary memory m = marginSummary();
        coreEquity6 = int256(m.accountValue);
        lastPositionSzi = position().szi;
        lastSync = block.timestamp;
        emit CoreSynced(coreEquity6, lastPositionSzi, lastSync);
    }

    /// @notice Keeper-facing state snapshot.
    function coreState() external view returns (
        int256 equity6, uint256 principal6, int64 szi, uint256 realized, uint256 swept, uint256 syncedAt
    ) {
        return (coreEquity6, corePrincipal6, lastPositionSzi, profitRealized, profitSwept, lastSync);
    }

    /// @notice Strategy assets in underlying units: synced Core equity (perp
    /// margin side) + Core spot USDC CASH (A3 FIX 2) + the SPOT HEDGE at the
    /// live spot mark (HIGH-2 — the long leg is a real asset and must count) +
    /// idle EVM balance. Counting spot cash keeps a Core->EVM bridge NAV-neutral
    /// (spot down, idle EVM up) and matches the all-legs split basis. The hedge
    /// is counted ONCE here (spotValue6) and spot cash is a distinct leg — no
    /// double-count. Every spot read is failure-safe (spotValue6()/coreSpotUsdc6()
    /// → 0), so withdraw math can never revert on a precompile hiccup.
    ///
    /// RESIDUAL FIX (security re-review t_281b833e): the three Core legs are
    /// summed as SIGNED 6dp and the NON-NEGATIVITY clamp is applied to the TOTAL,
    /// not to the perp term alone. A genuine unrealized perp LOSS (`coreEquity6`
    /// < 0) must reduce NAV. The old per-term clamp (`coreEquity6 > 0 ? … : 0`)
    /// dropped the loss while still adding the offsetting spot-hedge GAIN, so a
    /// delta-neutral book whose hedge rallied while its short ran at a loss
    /// reported NAV OVERSTATED by |perp equity|. Sum-then-clamp matches the
    /// all-legs basis `coreAllLegsEquity6()` used by the split, and is identical
    /// to the old result whenever `coreEquity6 >= 0` (the normal case).
    function totalAssets() public view override(BaseStrategy) returns (uint256) {
        int256 legs6 = coreEquity6
            + int256(uint256(coreSpotUsdc6()))
            + int256(uint256(spotValue6()));
        uint256 legsU = legs6 > 0 ? uint256(legs6) * coreScale : 0;
        return legsU + underlying.balanceOf(address(this));
    }

    /// @notice Realized profit still waiting to be swept (underlying units).
    function harvestableProfit() external view returns (uint256) {
        return profitRealized > profitSwept ? profitRealized - profitSwept : 0;
    }

    /*//////////////////////// All-legs Core equity (A3 fix) ////////////////////////*/
    /// @notice Honest ALL-LEGS Core equity (6dp): perp account value + Core spot
    /// USDC cash + the spot hedge at the live mark. This is the SAME basis the
    /// keeper's profit/loss path uses (dn_keeper.js `equityAllLegs6`). While a
    /// hedge is held, the perp-only `coreEquity6` sits far below
    /// `corePrincipal6` (most of the bridged capital becomes the spot hedge),
    /// so a perp-only split books every outflow as principal and never realizes
    /// funding profit (security review t_3a89fe76, A3). The hedge is counted
    /// ONCE here and once, under its own term, in totalAssets(); neither basis
    /// double-counts it. Live-read each call.
    function coreAllLegsEquity6() public view returns (int256) {
        return coreEquity6 + int256(uint256(coreSpotUsdc6())) + int256(uint256(spotValue6()));
    }

    /// @notice Keeper feature marker. Returns true iff this build's
    /// `bridgeBackToEvm` splits on the ALL-LEGS basis, i.e. the keeper may
    /// realize hedged funding profit against it. The pre-fix deployed build has
    /// no such getter, so an all-legs keeper MUST stay inert until this build is
    /// live — firing a hedged BRIDGE_PROFIT against a perp-only contract books
    /// the amount as principal and shaves the principal ledger.
    function coreProfitUsesAllLegs() external pure returns (bool) {
        return true;
    }

    /*//////////////////////// Reconciliation (admin) ////////////////////////*/
    /// @notice Owner-only bookkeeping reconciliation for `profitRealized`.
    ///
    /// AUDIT F-3 FIX. `bridgeBackToEvm` commits `corePrincipal6 -= principalRed`
    /// BEFORE the fire-and-forget `_sendUsdcToEvm`. Hyperliquid's CoreWriter drops
    /// actions for accounts without a Core account, so a silently-dropped send
    /// still decrements the principal basis — and because the send can be retried
    /// without bound, `profitRealized` could be inflated repeatedly with no USDC
    /// ever moving. The next harvest would then transfer REAL idle principal to
    /// the vault as "profit".
    ///
    /// This is the correction hatch (ported from HLEarnStrategy.sol:306, which
    /// shipped it for exactly this failure). It is funds-safe: the counter only
    /// sizes future harvests and can never be set below what has already been
    /// swept to the vault, so a bad reconcile can strand credit but can never
    /// claw back money the vault already holds.
    function reconcileProfit(uint256 newRealized) external onlyOwner {
        if (newRealized < profitSwept) revert DNCore__BelowSwept();
        uint256 old = profitRealized;
        profitRealized = newRealized;
        emit ProfitReconciled(old, newRealized);
    }

    /*//////////////////////// Harvest ////////////////////////*/
    /// @dev Keeper/owner: sync only (settle). Vault: sync + sweep realized
    /// profit above the liquidity buffer as REAL USDC to the vault.
    function _doHarvest() internal override returns (uint256 profit) {
        if (!isActive) revert DNCore__Inactive();
        if (msg.sender != owner() && msg.sender != keeper && msg.sender != vault) revert DNCore__NotAuthorized();
        _syncCore();
        if (msg.sender != vault) return 0; // keeper settles only; vault sweeps
        uint256 available = profitRealized > profitSwept ? profitRealized - profitSwept : 0;
        if (available == 0) return 0;
        // buffer = pct of assets kept idle for async recalls
        uint256 bal = underlying.balanceOf(address(this));
        uint256 buffer = (totalAssets() * bufferBps) / 10000;
        uint256 sweepable = bal > buffer ? bal - buffer : 0;
        uint256 sweep = available < sweepable ? available : sweepable;
        if (sweep == 0) return 0;
        profitSwept += sweep;
        underlying.safeTransfer(vault, sweep);
        emit ProfitSwept(sweep);
        return sweep; // BaseStrategy.harvest books it via totalDebt
    }
}
